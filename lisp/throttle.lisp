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

; Mutable config, updated by protocol.lisp on SET_THROTTLE and loaded from
; storage.lisp at boot. Defaults are conservative (ADC, no invert).
(define thr-cfg-source   thr-src-adc)
(define thr-cfg-invert   0)
(define thr-cfg-min      0.02)   ; normalized raw value treated as 0%
(define thr-cfg-max      0.98)   ; normalized raw value treated as 100%
(define thr-cfg-deadband 0.02)   ; ignored band around 0 after mapping
(define thr-cfg-filter   0.15)   ; low-pass alpha, 0 = no filtering, 1 = instant

(define thr-filtered 0.0)

; UART throttle: a tiny 3-byte frame so noise on the line can't be mistaken
; for a valid reading. Frame: <0xA5> <percent 0..200, meaning 0..100.0%>
; <checksum = 0xA5 xor percent>. Anything that doesn't check out keeps the
; last good value instead of jumping to garbage.
(define uart-buf (array-create 8))
(define uart-last-raw 0.0)
(define uart-started 0)

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

; Raw, source-specific, still 0..1.
(defun thr-read-raw ()
    (cond
        ((= thr-cfg-source thr-src-adc) (get-adc-decoded 0))
        ((= thr-cfg-source thr-src-ppm) (max-f 0.0 (get-ppm)))
        (t (uart-throttle-raw))
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
; control loop iteration.
(defun thr-read ()
    (let ((n (thr-normalize (thr-read-raw))))
    (progn
        (setq thr-filtered (+ thr-filtered (* thr-cfg-filter (- n thr-filtered))))
        thr-filtered)
    ))
