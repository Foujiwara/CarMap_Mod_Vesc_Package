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
(define live-throttle 0.0)
(define live-duty 0.0)
(define live-erpm 0.0)
(define live-cur-rel 0.0)
(define live-brake 0.0)

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
(defun control-loop ()
    (loopwhile t
        (progn
            (setq live-throttle (thr-read))
            (setq live-brake (thr-brake-read))
            (setq live-duty (get-duty))
            (setq live-erpm (get-rpm))
            ; The direct brake channel was a straight 1:1 lever-position
            ; -> current-rel mapping (no curve at all), which is what
            ; made it feel abrupt/violent on real hardware. Reuse the
            ; same "Regen curve" shaping already applied to the map's
            ; own overrun/engine-braking (see thermal-cell in map.lisp)
            ; so the brake lever ramps in progressively instead of
            ; jumping straight to a proportional current the instant it
            ; leaves the deadband.
            (setq live-cur-rel
                (if (> live-brake 0.0)
                    (- (pow live-brake (+ 1.0 cfg-regen-curve)))
                    (map-lookup live-throttle (clamp01 (abs live-duty)))))
            (set-current-rel live-cur-rel)
            (timeout-reset)
            (sleep 0.01) ; ~100 Hz control loop
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
                (bufset-i16 b 1 (fx-enc live-throttle))
                (bufset-i16 b 3 (fx-enc live-duty))
                (bufset-i32 b 5 (to-i live-erpm))
                (bufset-i16 b 9 (fx-enc live-cur-rel))
                (bufset-i16 b 11 (to-i (* (get-current) 100.0)))
                (bufset-i16 b 13 (fx-enc live-brake))
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
        (looprange d 0 map-duty-n
            (bufset-i16 b (+ 2 (* d 2)) (fx-enc (map-get-cell row-i d))))
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
        (bufset-i16 b 18 (fx-enc thr-cfg-min))
        (bufset-i16 b 20 (fx-enc thr-cfg-max))
        (bufset-i16 b 22 (fx-enc thr-cfg-deadband))
        (bufset-i16 b 24 (fx-enc thr-cfg-filter))
        (bufset-u8  b 26 thr-cfg-brake-mode)
        (proto-send b)
    )))

(defun handle-packet (data)
    (let ((cmd (bufget-u8 data 0)))
    (cond
        ((= cmd pkt-set-cell)
            (progn
                (map-set-cell (bufget-u8 data 1) (bufget-u8 data 2)
                               (fx-dec (bufget-i16 data 3)))
                (proto-send-status 0)))

        ((= cmd pkt-set-map-row)
            (let ((row (bufget-u8 data 1)))
            (progn
                (looprange d 0 map-duty-n
                    (map-set-cell row d (fx-dec (bufget-i16 data (+ 2 (* d 2))))))
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

        ((= cmd pkt-set-thr)
            (progn
                (setq thr-cfg-source (bufget-u8 data 1))
                (setq thr-cfg-invert (bufget-u8 data 2))
                (setq thr-cfg-min (fx-dec (bufget-i16 data 3)))
                (setq thr-cfg-max (fx-dec (bufget-i16 data 5)))
                (setq thr-cfg-deadband (fx-dec (bufget-i16 data 7)))
                (setq thr-cfg-filter (fx-dec (bufget-i16 data 9)))
                (setq thr-cfg-brake-mode (bufget-u8 data 11))
                (proto-send-status 0)))

        ((= cmd pkt-set-test-thr)
            (progn
                (setq thr-test-value (fx-dec (bufget-i16 data 1)))
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
