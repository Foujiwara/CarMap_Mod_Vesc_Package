; package.lisp - CarMap Thermal Throttle entry point.
;
; `import` only loads a file as a read-only byte array (see the "Import
; Files" chapter of the LispBM reference) - it does not evaluate it. To
; actually run the code in each sibling file we import it as bytes, then
; `read-eval-program` it. Order matters: util -> map (needs clamp
; helpers) -> throttle (needs clamp01) -> storage (needs both) -> protocol.
(import "util.lisp" 'bin-util)
(import "map.lisp" 'bin-map)
(import "throttle.lisp" 'bin-throttle)
(import "storage.lisp" 'bin-storage)
(import "protocol.lisp" 'bin-protocol)

(read-eval-program bin-util)
(read-eval-program bin-map)
(read-eval-program bin-throttle)
(read-eval-program bin-storage)
(read-eval-program bin-protocol)

; ---------------------------------------------------------------------
; Boot: load persisted map/config, or generate the Thermal Street default
; if this is the first run (no valid eeprom magic yet).
(if (storage-load)
    nil
    (storage-reset))

; Cache the last live values so the LIVE packet and the LiveView in QML
; always have something sane to show even before the first loop tick.
; live-throttle/live-cur-rel/live-brake are fp-scale integers (see
; util.lisp) - they match the wire format exactly, so telemetry sends
; them straight through with no fx-enc conversion. live-duty/live-erpm
; stay real floats: get-duty/get-rpm are native extensions that always
; return one, so there is nothing to gain converting them any earlier
; than telemetry-loop already has to (fx-enc).
(define live-throttle 0)
(define live-duty 0.0)
(define live-erpm 0.0)
(define live-cur-rel 0)
(define live-brake 0)

; ---------------------------------------------------------------------
; Control loop: read inputs, look up the map, apply the current-rel
; command. Runs as fast as practical; timeout-reset keeps the motor
; timeout from tripping since we drive the motor from lisp instead of
; the ADC/PPM/UART app directly.
;
; The independent brake channel (see thr-brake-read in throttle.lisp)
; bypasses the map entirely when active: it's a direct, proportional
; -1..0 current-rel from a real brake pedal/lever, not a duty-dependent
; curve. The map's own throttle-released engine braking still applies
; whenever the brake channel reads 0 (at rest, or disabled).
;
; This is deliberately the fixed, non-adjustable version: v0.1.34-0.1.37
; tried to make this shaped/adjustable (first via the native
; throttle-curve extension, then via a pure-lisp reimplementation of the
; same math using pow/exp) and BOTH caused an out_of_memory crash on
; real hardware (LispBM heap cells exhausted, surviving a full cold
; power-cycle) - so the actual root cause is still unidentified and
; isn't specific to either implementation. Reverted to this known-good
; v0.1.32 behavior per explicit request rather than keep debugging on
; hardware. Re-investigate from scratch before trying again: check
; whether an unrelated change in the same 0.1.34+ range (protocol/
; storage layout growth, EEPROM field additions) is the real cause
; before touching the brake math again.
;
; live-throttle/live-brake/live-cur-rel are fp-scale integers (see
; util.lisp) all the way through this loop - thr-read, thr-brake-read
; and map-lookup all stay in LispBM's zero-heap-cost integer type now.
; get-duty is a native extension and always returns a real float; it is
; converted to fp-scale (to-fp) right where it's used and nowhere else.
; set-current-rel is a native extension that requires a real float
; argument, so live-cur-rel is converted back with fp-to-f - the one
; unavoidable float (one heap cell) per tick, instead of the ~15-20 a
; fully float control-loop was creating and immediately having to
; garbage-collect every single tick (confirmed via lispBM's heap.c:
; every float allocates a heap cons cell, plain integers do not).
(defun control-loop ()
    (loopwhile t
        (progn
            (setq live-throttle (thr-read))
            (setq live-brake (thr-brake-read))
            (setq live-duty (get-duty))
            (setq live-erpm (get-rpm))
            (setq live-cur-rel
                (if (> live-brake 0)
                    (- live-brake)
                    (map-lookup live-throttle (clamp-f (to-fp (abs live-duty)) 0 fp-scale))))
            ; storage-pause-ticks (storage.lisp) - see storage-save.
            ; Every eeprom-store-f/i call waits up to 3s for the FOC
            ; state machine to reach MC_STATE_OFF before it will write
            ; anything (confirmed in mc_interface.c) - impossible while
            ; this loop keeps calling set-current-rel every tick, even
            ; with 0 current, since that's still "controlling", not
            ; "released". This was the actual reason Save never
            ; persisted anything on real hardware, 100% reproducibly -
            ; it has nothing to do with the vehicle moving, it's this
            ; script's own control loop holding the motor. Skipping
            ; set-current-rel/timeout-reset here lets the firmware's own
            ; configured motor timeout elapse and release control
            ; cleanly (the same mechanism a lost RC signal relies on)
            ; for the whole duration of storage-save. The counter
            ; decrements unconditionally every tick regardless of what
            ; storage-save does, so this can't get stuck - even a
            ; hypothetical error inside storage-save can only pause
            ; driving for its initial value, never longer.
            (if (> storage-pause-ticks 0)
                (setq storage-pause-ticks (- storage-pause-ticks 1))
                (progn
                    (set-current-rel (fp-to-f live-cur-rel))
                    (timeout-reset)))
            ; 200 Hz instead of the original 100 Hz: halves the loop's own
            ; contribution to input-to-current latency. Safe to tighten
            ; now that map-lookup/thr-normalize/thr-read (throttle.lisp,
            ; map.lisp) were flattened from nested lets to single lets
            ; each, and now run in fixed-point integers instead of
            ; floats - far less heap pressure per tick than the 100 Hz,
            ; all-float version had.
            (sleep 0.005) ; ~200 Hz control loop
        )))

; ---------------------------------------------------------------------
; Telemetry: send a compact LIVE packet at a much lower, UI-friendly
; rate so we don't flood the comm link. Full map/config are only sent
; on request (REQUEST_MAP / REQUEST_CFG), never proactively.
(defun telemetry-loop ()
    (loopwhile t
        (progn
            (let ((b (array-create 15)))
            (progn
                (bufset-u8 b 0 pkt-live)
                ; live-throttle/live-cur-rel/live-brake are already
                ; fp-scale integers (see util.lisp) - identical to the
                ; wire's own x1000 fixed point, so no fx-enc needed.
                ; live-duty is still a real float (get-duty), so it's
                ; the only one that needs it.
                (bufset-i16 b 1 live-throttle)
                (bufset-i16 b 3 (fx-enc live-duty))
                (bufset-i32 b 5 (to-i live-erpm))
                (bufset-i16 b 9 live-cur-rel)
                (bufset-i16 b 11 (to-i (* (get-current) 100.0)))
                (bufset-i16 b 13 live-brake)
                (proto-send b)))
            (sleep 0.05) ; 20 Hz, plenty for a smooth UI dot/needle
        )))

; ---------------------------------------------------------------------
; Command handling: everything that arrives from QML.
(defun send-map-row (row-i)
    (let ((b (array-create (+ 2 (* map-duty-n 2)))))
    (progn
        (bufset-u8 b 0 pkt-map-row)
        (bufset-u8 b 1 row-i)
        ; map-get-cell is already fp-scale (map.lisp) - matches the wire
        ; format exactly, no fx-enc needed.
        (looprange d 0 map-duty-n
            (bufset-i16 b (+ 2 (* d 2)) (map-get-cell row-i d)))
        (proto-send b)
    )))

(defun send-full-map ()
    (looprange r 0 map-thr-n (send-map-row r)))

(defun send-cfg-echo ()
    (let ((b (array-create 27)))
    (progn
        (bufset-u8  b 0  pkt-cfg-echo)
        (bufset-u8  b 1  cfg-preset)
        (bufset-i16 b 2  (fx-enc cfg-torque-resp))
        (bufset-i16 b 4  (fx-enc cfg-speed-coupling))
        (bufset-i16 b 6  (fx-enc cfg-trans-width))
        (bufset-u8  b 8  cfg-trans-shape)
        (bufset-i16 b 9  (fx-enc cfg-high-hold))
        (bufset-i16 b 11 (fx-enc cfg-engine-brake))
        (bufset-i16 b 13 (fx-enc cfg-overrun-regen))
        (bufset-u8  b 15 cfg-regen-curve)
        (bufset-u8  b 16 thr-cfg-source)
        (bufset-u8  b 17 thr-cfg-invert)
        ; thr-cfg-min/max/deadband/filter are already fp-scale integers
        ; (throttle.lisp) - matches the wire format exactly, no fx-enc
        ; needed (unlike cfg-torque-resp etc. above, which stay float
        ; since only gen-thermal-map's pow()-based math uses them).
        (bufset-i16 b 18 thr-cfg-min)
        (bufset-i16 b 20 thr-cfg-max)
        (bufset-i16 b 22 thr-cfg-deadband)
        (bufset-i16 b 24 thr-cfg-filter)
        (bufset-u8  b 26 thr-cfg-brake-mode)
        (proto-send b)
    )))

(defun handle-packet (data)
    (let ((cmd (bufget-u8 data 0)))
    (cond
        ; map-set-cell expects fp-scale (map.lisp) - identical to the
        ; wire's own x1000 fixed point, so the raw i16 is used directly.
        ((= cmd pkt-set-cell)
            (progn
                (map-set-cell (bufget-u8 data 1) (bufget-u8 data 2)
                               (bufget-i16 data 3))
                (proto-send-status 0)))

        ((= cmd pkt-set-map-row)
            (let ((row (bufget-u8 data 1)))
            (progn
                (looprange d 0 map-duty-n
                    (map-set-cell row d (bufget-i16 data (+ 2 (* d 2)))))
                (proto-send-status 0))))

        ((= cmd pkt-set-config)
            (progn
                (setq cfg-preset (bufget-u8 data 1))
                (setq cfg-torque-resp (fx-dec (bufget-i16 data 2)))
                (setq cfg-speed-coupling (fx-dec (bufget-i16 data 4)))
                (setq cfg-trans-width (fx-dec (bufget-i16 data 6)))
                (setq cfg-trans-shape (bufget-u8 data 8))
                (setq cfg-high-hold (fx-dec (bufget-i16 data 9)))
                (setq cfg-engine-brake (fx-dec (bufget-i16 data 11)))
                (setq cfg-overrun-regen (fx-dec (bufget-i16 data 13)))
                (setq cfg-regen-curve (bufget-u8 data 15))
                ; preset > 0 regenerates the whole map; preset 0 (Custom)
                ; leaves manually-edited cells alone.
                (if (> cfg-preset 0)
                    (gen-thermal-map cfg-torque-resp cfg-speed-coupling
                        cfg-trans-width cfg-trans-shape cfg-high-hold
                        cfg-engine-brake cfg-overrun-regen cfg-regen-curve)
                    nil)
                (proto-send-status 0)))

        ; thr-cfg-min/max/deadband/filter and thr-test-value are all
        ; fp-scale integers now (throttle.lisp) - identical to the
        ; wire's own x1000 fixed point, so the raw i16 is used directly.
        ((= cmd pkt-set-thr)
            (progn
                (setq thr-cfg-source (bufget-u8 data 1))
                (setq thr-cfg-invert (bufget-u8 data 2))
                (setq thr-cfg-min (bufget-i16 data 3))
                (setq thr-cfg-max (bufget-i16 data 5))
                (setq thr-cfg-deadband (bufget-i16 data 7))
                (setq thr-cfg-filter (bufget-i16 data 9))
                (setq thr-cfg-brake-mode (bufget-u8 data 11))
                (proto-send-status 0)))

        ((= cmd pkt-set-test-thr)
            (progn
                (setq thr-test-value (bufget-i16 data 1))
                (proto-send-status 0)))

        ((= cmd pkt-cmd-save) (progn (storage-save) (proto-send-status 1)))
        ((= cmd pkt-cmd-load) (progn (storage-load) (proto-send-status 2)))
        ((= cmd pkt-cmd-reset) (progn (storage-reset) (proto-send-status 3)))
        ((= cmd pkt-req-map) (send-full-map))
        ((= cmd pkt-req-cfg) (send-cfg-echo))
        (t nil)
    )))

(defun event-handler ()
    (loopwhile t
        (recv
            ((event-data-rx . (? data)) (handle-packet data))
            (_ nil)
        )))

; ---------------------------------------------------------------------
; Spawn everything. Order: event handler first so it's ready to receive
; before we start announcing ourselves, then the two periodic loops.
(event-register-handler (spawn event-handler))
(event-enable 'event-data-rx)

(spawn "carmap-ctl" 150 control-loop)
(spawn "carmap-tel" 80 telemetry-loop)
