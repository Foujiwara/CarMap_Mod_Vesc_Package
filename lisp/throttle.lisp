; throttle.lisp - normalize whatever throttle source is configured into a
; single 0.0 .. 1.0 value, independent of the source-specific raw range.
;
; Sources map to the app-adc / app-ppm / app-uart control-type "Off"
; convention documented for get-adc-decoded / get-ppm: leave the
; corresponding VESC app control type set to Off in App Settings so the
; app itself never drives the motor, and read the raw/decoded value from
; here instead. This package never changes App Settings itself - see
; docs/architecture.md for the one-time manual setup step.

(define thr-src-adc  0)
(define thr-src-ppm  1)
(define thr-src-uart 2)
(define thr-src-test 3) ; bench-test value sent directly from the QML UI,
                         ; no wiring needed - see SET_TEST_THROTTLE in
                         ; docs/protocol.md. Bypasses min/max/deadband/
                         ; invert since the UI already sends a clean 0..1
                         ; value; still goes through the low-pass filter.

; Mutable config, updated by protocol.lisp on SET_THROTTLE and loaded from
; storage.lisp at boot. Defaults are conservative (ADC, no invert).
(define thr-cfg-source   thr-src-adc)
(define thr-cfg-invert   0)
(define thr-cfg-min      0.02)   ; normalized raw value treated as 0%
(define thr-cfg-max      0.98)   ; normalized raw value treated as 100%
(define thr-cfg-deadband 0.02)   ; ignored band around 0 after mapping
(define thr-cfg-filter   1.0)    ; low-pass alpha, 0 = frozen, 1 = no
                                  ; filtering/instant. Real-hardware
                                  ; testing found any filtering here felt
                                  ; like noticeable input latency, so the
                                  ; default is now "off" (1.0); lower it
                                  ; from the Configurator tab only if your
                                  ; particular input is actually noisy.

(define thr-filtered 0.0)

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
; braking still applies whenever the brake reads 0 (at rest, or off).
(define thr-brake-none  0)
(define thr-brake-dual  1)
(define thr-brake-bidir 2)
(define thr-cfg-brake-mode thr-brake-none)

; UART throttle: a tiny 3-byte frame so noise on the line can't be mistaken
; for a valid reading. Frame: <0xA5> <percent 0..200, meaning 0..100.0%>
; <checksum = 0xA5 xor percent>. Anything that doesn't check out keeps the
; last good value instead of jumping to garbage.
(define uart-buf (array-create 8))
(define uart-last-raw 0.0)
(define uart-started 0)

; Bench-test value, set by handle-packet on SET_TEST_THROTTLE. Only used
; when thr-cfg-source == thr-src-test. No automatic timeout here - the
; QML side has an explicit Stop button (like VESC Tool's own bench-test
; panel) that sends 0 directly; use it before disconnecting or changing
; source.
(define thr-test-value 0.0)

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
            (progn (setq uart-last-raw (/ (to-float b1) 200.0)) uart-last-raw)
            uart-last-raw))
        uart-last-raw))
    ))

; Bidirectional single-channel ADC1 read, using the ADC app's OWN
; start/center/end calibration (App Settings -> ADC) rather than this
; package's own min/max, since those three values already fully
; describe a center-zero throttle. Returns a signed -1..1 value: >0 is
; the accelerator side, <0 is the brake side, both already fractions of
; their own half of the range (no separate normalize step needed).
(defun thr-adc-signed ()
    (let ((raw (get-adc 0))
          (v-start (conf-get 'adc-v1-start))
          (v-center (conf-get 'adc-v1-center))
          (v-end (conf-get 'adc-v1-end)))
    (if (>= raw v-center)
        (clamp01 (/ (- raw v-center) (max-f 0.001 (- v-end v-center))))
        (- (clamp01 (/ (- v-center raw) (max-f 0.001 (- v-center v-start)))))
    )))

; Raw, source-specific, still 0..1.
(defun thr-read-raw ()
    (cond
        ((= thr-cfg-source thr-src-adc)
            (if (= thr-cfg-brake-mode thr-brake-bidir)
                (max-f 0.0 (thr-adc-signed))
                (get-adc-decoded 0)))
        ((= thr-cfg-source thr-src-ppm) (max-f 0.0 (get-ppm)))
        ((= thr-cfg-source thr-src-uart) (uart-throttle-raw))
        ((= thr-cfg-source thr-src-test) thr-test-value)
        (t 0.0) ; unknown source: fail safe to zero throttle
    ))

; Apply min/max calibration, deadband and inversion; returns 0..1.
(defun thr-normalize (raw)
    (let ((v (/ (- raw thr-cfg-min) (max-f 0.001 (- thr-cfg-max thr-cfg-min)))))
    (let ((vc (clamp01 v)))
    (let ((vd (if (< vc thr-cfg-deadband) 0.0
                  (/ (- vc thr-cfg-deadband) (max-f 0.001 (- 1.0 thr-cfg-deadband))))))
    (let ((vf (clamp01 vd)))
    (if (= thr-cfg-invert 1) (- 1.0 vf) vf)
    )))))

; Public entry point: read + normalize + low-pass filter. Call once per
; control loop iteration. The Test source and bidirectional-ADC mode
; both skip this package's own min/max/deadband/invert calibration
; (Test because the UI already sends a clean 0..1 value; bidirectional
; because thr-adc-signed already normalized against the ADC app's own
; start/center/end calibration) but still go through the low-pass
; filter so behavior matches every other source.
(defun thr-read ()
    (let ((skip-normalize (or (= thr-cfg-source thr-src-test)
                               (and (= thr-cfg-source thr-src-adc) (= thr-cfg-brake-mode thr-brake-bidir)))))
    (let ((n (if skip-normalize (clamp01 (thr-read-raw)) (thr-normalize (thr-read-raw)))))
    (progn
        (setq thr-filtered (+ thr-filtered (* thr-cfg-filter (- n thr-filtered))))
        thr-filtered)
    )))

; Brake side, 0..1. Dual mode reads ADC2 (channel 1) with the same
; min/max/deadband calibration as the main channel (never inverted -
; that setting is about the accelerator's own direction, not this
; separate lever); bidirectional mode reads the negative half of
; thr-adc-signed (already calibrated against the ADC app's own
; start/center/end). No filtering either way - a brake benefits from
; being immediate, not smoothed. Returns 0.0 when off or on any
; non-ADC source, since these are ADC-specific setups.
(defun thr-brake-read ()
    (cond
        ((not (= thr-cfg-source thr-src-adc)) 0.0)
        ((= thr-cfg-brake-mode thr-brake-dual)
            (let ((v (/ (- (get-adc-decoded 1) thr-cfg-min) (max-f 0.001 (- thr-cfg-max thr-cfg-min)))))
            (let ((vc (clamp01 v)))
            (if (< vc thr-cfg-deadband) 0.0
                (clamp01 (/ (- vc thr-cfg-deadband) (max-f 0.001 (- 1.0 thr-cfg-deadband)))))
            )))
        ((= thr-cfg-brake-mode thr-brake-bidir)
            (max-f 0.0 (- (thr-adc-signed))))
        (t 0.0)
    ))

; Brake curve shaping - same math as the native throttle-curve extension
; (utils_throttle_curve in bldc's firmware, the one the stock ADC/PPM/
; VESC Remote apps use for their own "throttle curve" setting), but
; reimplemented here in pure LispBM instead of calling that extension
; directly. Reason: calling it from the 100 Hz control loop caused an
; out_of_memory error on real hardware (heap cells exhausted even right
; after a cold power-cycle) - root cause not fully isolated, but this
; removes the dependency entirely using only pow/exp, which map.lisp's
; own gen-thermal-map already calls the same way at boot without issue.
; val01 is 0..1 (already the absolute brake value), curve is -5..5 (see
; docs/protocol.md), mode is 0=Exponential 1=Natural 2=Polynomial,
; matching VESC Tool's own enum order for this parameter. Returns 0..1;
; the caller re-applies the sign (control-loop always calls this for
; the brake side, which is always <= 0).
(defun brake-curve-apply (val01 curve mode)
    (cond
        ((= mode 0) ; Exponential: y = 1-(1-x)^(1+c), or x^(1-c) when c<0
            (if (>= curve 0.0)
                (- 1.0 (pow (- 1.0 val01) (+ 1.0 curve)))
                (pow val01 (- 1.0 curve))))
        ((= mode 1) ; Natural: y = (e^(cx)-1)/(e^c-1) family
            (if (< (abs curve) 1.0e-10)
                val01
                (if (>= curve 0.0)
                    (- 1.0 (/ (- (exp (* curve (- 1.0 val01))) 1.0) (- (exp curve) 1.0)))
                    (/ (- (exp (* (- curve) val01)) 1.0) (- (exp (- curve)) 1.0)))))
        ((= mode 2) ; Polynomial: y = x/(1+c(1-x)), or x/(1-c(1-x)) when c<0
            (if (>= curve 0.0)
                (- 1.0 (/ (- 1.0 val01) (+ 1.0 (* curve val01))))
                (/ val01 (- 1.0 (* curve (- 1.0 val01))))))
        (t val01) ; Linear
    ))
