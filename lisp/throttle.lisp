; Input values and filters use inline 28-bit fixed-point integers.
(define thr-cfg-source 0)
(define thr-cfg-invert 0)
(define thr-cfg-min 20)
(define thr-cfg-max 980)
(define thr-cfg-deadband 20)
(define thr-cfg-filter 1000)
(define thr-cfg-brake-mode 0)
; Filter accumulator has an extra x1000 precision to avoid sticking above
; zero when the integer EMA delta rounds down.
(define thr-filtered 0)
(define thr-expired nil)
(define thr-filter-acc 0)
(define thr-adc-cal-start 0)
(define thr-adc-cal-end 0)
(define thr-adc-cal-loaded nil)
(define thr-signed-sample 0)
(define uart-buf (array-create 3))
(define uart-started nil)
(define uart-pos 0)
(define uart-percent 0)
(define uart-last-raw 0)
(define uart-last-time 0)
(define thr-test-value 0)
(define thr-test-time 0)

@const-start
(define thr-src-adc 0)
(define thr-src-ppm 1)
(define thr-src-uart 2)
(define thr-src-test 3)
(define thr-brake-none 0)
(define thr-brake-dual 1)
(define thr-brake-bidir 2)

(defun thr-reset-state ()
    (progn
        (setq thr-filtered 0)
        (setq thr-filter-acc 0)
        (setq thr-test-value 0)
        (setq uart-last-raw 0)
        (setq uart-pos 0)
        (setq thr-adc-cal-loaded nil)))

(defun thr-adc-cal-ensure ()
    (if (not thr-adc-cal-loaded)
        (progn
            (setq thr-adc-cal-start (to-fp (conf-get 'adc-v1-start)))
            (setq thr-adc-cal-end (to-fp (conf-get 'adc-v1-end)))
            (setq thr-adc-cal-loaded t))))

; One voltage sample per control tick, shared with the brake path.
; A reversed ADC calibration works too; equal endpoints produce zero.
(defun thr-adc-signed ()
    (progn
        (thr-adc-cal-ensure)
        (let ((span (- thr-adc-cal-end thr-adc-cal-start))
              (raw (to-fp (get-adc 0))))
            (if (= span 0) 0
                (let ((v (clamp-f (- (/ (* (- raw thr-adc-cal-start) 2000) span) 1000) -1000 1000))
                      (mag (abs v)))
                    (if (<= mag thr-cfg-deadband) 0
                        (* (if (< v 0) -1 1)
                           (/ (* (- mag thr-cfg-deadband) 1000)
                              (- 1000 thr-cfg-deadband)))))))))

; Incremental parser preserves partial frames and resynchronizes after noise.
(defun uart-throttle-byte (v)
    (cond
        ((= uart-pos 0) (if (= v 0xA5) (setq uart-pos 1)))
        ((= uart-pos 1)
            (if (<= v 200)
                (progn (setq uart-percent v) (setq uart-pos 2))
                (setq uart-pos 0)))
        (t
            (if (= v (bitwise-xor 0xA5 uart-percent))
                (progn
                    (setq uart-last-raw (* uart-percent 5))
                    (setq uart-last-time (systime))
                    (setq uart-pos 0))
                (setq uart-pos (if (= v 0xA5) 1 0))))))

(defun uart-throttle-raw ()
    (progn
        (if (not uart-started)
            (progn (uart-start 115200) (setq uart-started t)))
        (let ((n (uart-read uart-buf 3 0 nil 0.0)))
            (looprange i 0 n (uart-throttle-byte (bufget-u8 uart-buf i))))
        uart-last-raw))

(defun thr-read-raw ()
    (cond
        ((= thr-cfg-source thr-src-adc)
            (if (= thr-cfg-brake-mode thr-brake-bidir)
                (progn (setq thr-signed-sample (thr-adc-signed))
                       (max-f 0 thr-signed-sample))
                (to-fp (get-adc-decoded 0))))
        ((= thr-cfg-source thr-src-ppm) (max-f 0 (to-fp (get-ppm))))
        ((= thr-cfg-source thr-src-uart) (uart-throttle-raw))
        ((= thr-cfg-source thr-src-test) thr-test-value)
        (t 0)))

(defun thr-deadband (v)
    (if (<= v thr-cfg-deadband) 0
        (/ (* (- v thr-cfg-deadband) 1000) (- 1000 thr-cfg-deadband))))

(defun thr-normalize (raw)
    (let ((v (clamp-f (/ (* (- raw thr-cfg-min) 1000)
                            (max-f 1 (- thr-cfg-max thr-cfg-min))) 0 1000)))
        ; Inversion must precede deadband, or inverted rest commands torque.
        (thr-deadband (if (= thr-cfg-invert 1) (- 1000 v) v))))

(defun thr-input-expired ()
    (or (and (= thr-cfg-source thr-src-test) (> (secs-since thr-test-time) 0.5))
        (and (= thr-cfg-source thr-src-ppm) (> (get-ppm-age) 0.5))
        (and (= thr-cfg-source thr-src-uart) (> (secs-since uart-last-time) 0.5))))

(defun thr-read ()
    (let ((raw (thr-read-raw))
          (n (if (or (= thr-cfg-source thr-src-test)
                     (and (= thr-cfg-source thr-src-adc) (= thr-cfg-brake-mode thr-brake-bidir)))
                 (clamp-f raw 0 1000) (thr-normalize raw))))
        (progn (setq thr-expired (thr-input-expired))
        (if thr-expired
            (progn (setq thr-filter-acc 0) (setq thr-filtered 0))
            (progn
                ; Split product to stay below the 28-bit signed limit.
                (setq thr-filter-acc
                    (+ thr-filter-acc
                       (* thr-cfg-filter (- n (/ thr-filter-acc 1000)))
                       (- (/ (* thr-cfg-filter (mod thr-filter-acc 1000)) 1000))))
                (setq thr-filtered (/ thr-filter-acc 1000))))
        thr-filtered)))

(defun thr-brake-read ()
    (cond
        ((not (= thr-cfg-source thr-src-adc)) 0)
        ((= thr-cfg-brake-mode thr-brake-dual)
            (thr-deadband (clamp-f
                (/ (* (- (to-fp (get-adc-decoded 1)) thr-cfg-min) 1000)
                   (max-f 1 (- thr-cfg-max thr-cfg-min))) 0 1000)))
        ((= thr-cfg-brake-mode thr-brake-bidir) (max-f 0 (- thr-signed-sample)))
        (t 0)))
@const-end
