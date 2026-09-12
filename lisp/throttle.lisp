; throttle.lisp - normalize whatever throttle source is configured into a
; single fp-scale (0..1000, see util.lisp) value, independent of the
; source-specific raw range.
;
; Sources map to the app-adc / app-ppm / app-uart control-type "Off"
; convention documented for get-adc-decoded / get-ppm: leave the
; corresponding VESC app control type set to Off in App Settings so the
; app itself never drives the motor, and read the raw/decoded value from
; here instead. This package never changes App Settings itself - see
; docs/architecture.md for the one-time manual setup step.
;
; Everything below fp-scale is a plain integer (fixnum, zero heap cost -
; see util.lisp) rather than a float. get-adc-decoded/get-ppm/get-adc/
; conf-get are native extensions that always return a real float - that
; can't be avoided - but each one is converted to fp-scale immediately
; at the point of reading, instead of staying a float through every
; subsequent calculation the way this file worked before.
;
; @const-start/@const-end blocks below (see util.lisp's comment) move
; truly-constant definitions and every defun to flash instead of the
; RAM heap. This file mixes those with mutable config/state (thr-cfg-*,
; thr-filtered, thr-adc-cal-*, uart-last-raw/started, thr-test-value -
; all reassigned with `setq` elsewhere), so several separate blocks are
; used instead of one big one, always skipping over whatever is mutable
; in between - constant blocks cannot be nested, but can be sequential.

@const-start
(define thr-src-adc  0)
(define thr-src-ppm  1)
(define thr-src-uart 2)
(define thr-src-test 3) ; bench-test value sent directly from the QML UI,
                         ; no wiring needed - see SET_TEST_THROTTLE in
                         ; docs/protocol.md. Bypasses min/max/deadband/
                         ; invert since the UI already sends a clean
                         ; fp-scale value; still goes through the
                         ; low-pass filter.
@const-end

; Mutable config, updated by protocol.lisp on SET_THROTTLE and loaded from
; storage.lisp at boot. Defaults are conservative (ADC, no invert). All
; fp-scale integers (0..1000 = 0.0..1.0) - this is also exactly the wire
; format's own x1000 fixed point, so no conversion is needed when a
; SET_THROTTLE/CFG_ECHO packet crosses the wire (see package.lisp).
(define thr-cfg-source   thr-src-adc)
(define thr-cfg-invert   0)
(define thr-cfg-min      20)     ; 0.02
(define thr-cfg-max      980)    ; 0.98
(define thr-cfg-deadband 20)     ; 0.02
(define thr-cfg-filter   1000)   ; low-pass alpha, 0 = frozen, 1000 = no
                                  ; filtering/instant. Real-hardware
                                  ; testing found any filtering here felt
                                  ; like noticeable input latency, so the
                                  ; default is now "off" (1000); lower it
                                  ; from the Configurator tab only if your
                                  ; particular input is actually noisy.

(define thr-filtered 0)

; Braking beyond the map's own throttle-released engine braking (ADC
; only, for now). Two different physical setups, both ADC-only:
;   0 = off (only the map's own engine braking applies)
;   1 = dual channel: a separate brake pedal/lever on ADC2 (channel 1),
;       its own independent 0..1 signal, calibrated the same way as the
;       main channel (accelerator and brake are two physical inputs)
;   2 = bidirectional: ONE center-zero ADC1 input covers both - above
;       center is accelerator, below center is brake. get-adc-decoded is
;       always 0..1 regardless of the app's own reverse capability, so
;       this mode reads the raw voltage (get-adc) and the ADC app's own
;       calibration (conf-get 'adc-v1-start/-center/-end, set in App
;       Settings -> ADC) instead of decoding it a second time.
; Either way, when the brake side is above its deadband it overrides the
; map entirely with a direct, proportional negative current-rel (see
; control-loop in package.lisp); the map's own throttle-released
; braking still applies whenever the brake channel reads 0 (at rest, or
; disabled).
@const-start
(define thr-brake-none  0)
(define thr-brake-dual  1)
(define thr-brake-bidir 2)
@const-end
(define thr-cfg-brake-mode thr-brake-none)

; ADC bidirectional calibration cache (adc-v1-start/-center/-end from
; App Settings -> ADC). These almost never change while this package is
; running, so they're read once via conf-get instead of on every single
; control-loop tick: fewer native calls (real CPU cost, not just heap -
; conf-get looks up a named field in the app config struct) and fewer
; fresh float boxes (a cached global still boxes the value once at
; cache time, not again on every read).
;
; Lazily populated on first actual use inside the control loop
; (thr-adc-cal-ensure, called from thr-adc-signed) rather than eagerly
; at script boot: calling conf-get from the top-level boot sequence
; (before any process has even been spawned) is untested timing that
; caused a total script failure on real hardware - every previous
; conf-get call in this file only ever happened from inside the
; already-running control-loop process, never at boot, so this keeps
; that same safe timing while still only paying the conf-get cost once
; instead of every tick. If you change the ADC calibration in App
; Settings while this package is already running, reboot the VESC (or
; reinstall the package) to pick up the new values.
(define thr-adc-cal-start 0.0)
(define thr-adc-cal-center 0.0)
(define thr-adc-cal-end 0.0)
(define thr-adc-cal-loaded 0)

; UART throttle: a tiny 3-byte frame so noise on the line can't be mistaken
; for a valid reading. Frame: <0xA5> <percent 0..200, meaning 0..100.0%>
; <checksum = 0xA5 xor percent>. Anything that doesn't check out keeps the
; last good value instead of jumping to garbage. b1 (0..200) converts to
; fp-scale (0..1000) with a plain integer multiply (*5) - no float ever
; appears in this path at all, unlike every other source (which all read
; a native float at some point).
(define uart-buf (array-create 8))
(define uart-last-raw 0)
(define uart-started 0)

; Bench-test value, set by handle-packet on SET_TEST_THROTTLE. Only used
; when thr-cfg-source == thr-src-test. fp-scale, matching the wire value
; directly (no conversion needed in either direction - see
; package.lisp). No automatic timeout here - the QML side has an
; explicit Stop button (like VESC Tool's own bench-test panel) that
; sends 0 directly; use it before disconnecting or changing source.
(define thr-test-value 0)

; Every defun below is fixed code - none of them are ever reassigned -
; so they all go in one final flash block.
@const-start

(defun thr-adc-cal-ensure ()
    (if (= thr-adc-cal-loaded 0)
        (progn
            (setq thr-adc-cal-start (conf-get 'adc-v1-start))
            (setq thr-adc-cal-center (conf-get 'adc-v1-center))
            (setq thr-adc-cal-end (conf-get 'adc-v1-end))
            (setq thr-adc-cal-loaded 1))
        nil))

(defun uart-throttle-init ()
    (if (= uart-started 0)
        (progn (uart-start 115200) (setq uart-started 1))
        nil))

(defun uart-throttle-raw ()
    (progn
    (uart-throttle-init)
    (let ((n (uart-read uart-buf 3 0 nil 0.0)))
    (if (= n 3)
        (let ((b0 (bufget-u8 uart-buf 0))
              (b1 (bufget-u8 uart-buf 1))
              (b2 (bufget-u8 uart-buf 2)))
        (if (and (= b0 0xA5) (< b1 201) (= b2 (bitwise-xor 0xA5 b1)))
            (progn (setq uart-last-raw (* b1 5)) uart-last-raw)
            uart-last-raw))
        uart-last-raw))
    ))

; Bidirectional single-channel ADC1 read, using the ADC app's OWN
; start/center/end calibration (App Settings -> ADC, cached above)
; rather than this package's own min/max, since those three values
; already fully describe a center-zero throttle. Returns a signed
; fp-scale value: >0 is the accelerator side, <0 is the brake side,
; both already fractions of their own half of the range (no separate
; normalize step needed). The calibration values themselves are floats
; (cached, not re-read every tick - see thr-adc-cal-ensure) and the
; raw ADC voltage (get-adc) is always a float too, so this function
; still does float math internally - unavoidable, this is literally
; reading and comparing voltages - but its final result is converted to
; fp-scale once, right at the end, same as every other source.
(defun thr-adc-signed ()
    (progn
    (thr-adc-cal-ensure)
    (let ((raw (get-adc 0)))
    (to-fp
        (if (>= raw thr-adc-cal-center)
            (clamp01 (/ (- raw thr-adc-cal-center) (max-f 0.001 (- thr-adc-cal-end thr-adc-cal-center))))
            (- (clamp01 (/ (- thr-adc-cal-center raw) (max-f 0.001 (- thr-adc-cal-center thr-adc-cal-start)))))
        )))))

; Raw, source-specific, fp-scale (0..1000).
(defun thr-read-raw ()
    (cond
        ((= thr-cfg-source thr-src-adc)
            (if (= thr-cfg-brake-mode thr-brake-bidir)
                (max-f 0 (thr-adc-signed))
                (to-fp (get-adc-decoded 0))))
        ((= thr-cfg-source thr-src-ppm) (max-f 0 (to-fp (get-ppm))))
        ((= thr-cfg-source thr-src-uart) (uart-throttle-raw))
        ((= thr-cfg-source thr-src-test) thr-test-value)
        (t 0) ; unknown source: fail safe to zero throttle
    ))

; Apply min/max calibration, deadband and inversion; fp-scale in, fp-scale
; out. One flat `let` (LispBM allows later bindings to reference earlier
; ones in the same let - see map-lookup) instead of four nested ones:
; same result, one environment frame instead of four, called every
; control loop tick. Pure integer math throughout - no floats, no heap
; allocation at all in this function.
(defun thr-normalize (raw)
    (let ((v (/ (* (- raw thr-cfg-min) fp-scale) (max-f 1 (- thr-cfg-max thr-cfg-min))))
          (vc (clamp-f v 0 fp-scale))
          (vd (if (< vc thr-cfg-deadband) 0
                  (/ (* (- vc thr-cfg-deadband) fp-scale) (max-f 1 (- fp-scale thr-cfg-deadband)))))
          (vf (clamp-f vd 0 fp-scale)))
    (if (= thr-cfg-invert 1) (- fp-scale vf) vf)
    ))

; Public entry point: read + normalize + low-pass filter. Call once per
; control loop iteration. Returns fp-scale. The Test source and
; bidirectional-ADC mode both skip this package's own min/max/deadband/
; invert calibration (Test because the UI already sends a clean fp-scale
; value; bidirectional because thr-adc-signed already normalized against
; the ADC app's own start/center/end calibration) but still go through
; the low-pass filter so behavior matches every other source. The filter
; itself is now a pure integer EMA (thr-filtered is fp-scale, updated by
; an integer multiply-then-divide instead of a float multiply) - no
; heap allocation here either.
(defun thr-read ()
    (let ((skip-normalize (or (= thr-cfg-source thr-src-test)
                               (and (= thr-cfg-source thr-src-adc) (= thr-cfg-brake-mode thr-brake-bidir))))
          (n (if skip-normalize (clamp-f (thr-read-raw) 0 fp-scale) (thr-normalize (thr-read-raw)))))
    (progn
        (setq thr-filtered (+ thr-filtered (/ (* thr-cfg-filter (- n thr-filtered)) fp-scale)))
        thr-filtered)
    ))

; Brake side, fp-scale (0..1000). Dual mode reads ADC2 (channel 1) with
; the same min/max/deadband calibration as the main channel (never
; inverted - that setting is about the accelerator's own direction, not
; this separate lever); bidirectional mode reads the negative half of
; thr-adc-signed (already calibrated against the ADC app's own
; start/center/end). No filtering either way - a brake benefits from
; being immediate, not smoothed. Returns 0 when off or on any non-ADC
; source, since these are ADC-specific setups.
(defun thr-brake-read ()
    (cond
        ((not (= thr-cfg-source thr-src-adc)) 0)
        ((= thr-cfg-brake-mode thr-brake-dual)
            (let ((v (/ (* (- (to-fp (get-adc-decoded 1)) thr-cfg-min) fp-scale) (max-f 1 (- thr-cfg-max thr-cfg-min))))
                  (vc (clamp-f v 0 fp-scale)))
            (if (< vc thr-cfg-deadband) 0
                (clamp-f (/ (* (- vc thr-cfg-deadband) fp-scale) (max-f 1 (- fp-scale thr-cfg-deadband))) 0 fp-scale))
            ))
        ((= thr-cfg-brake-mode thr-brake-bidir)
            (max-f 0 (- (thr-adc-signed))))
        (t 0)
    ))

@const-end
