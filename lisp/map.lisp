; Signed-byte cells stay in RAM; code and immutable constants live in flash.
@const-start
(define map-thr-n 21)
(define map-duty-n 21)
(define map-cells 441)
@const-end
(define map-buf (array-create map-cells))
@const-start
(defun map-idx (t-i d-i) (+ (* t-i 21) d-i))
(defun map-get-cell (t-i d-i) (* (bufget-i8 map-buf (map-idx t-i d-i)) 10))
(defun map-set-cell (t-i d-i val)
    (bufset-i8 map-buf (map-idx t-i d-i) (cell-to-i8 val)))

; All intermediates fit the VESC's signed 28-bit inline integer.
(defun map-lookup (thr duty)
    (let ((tf (* (clamp-f thr 0 1000) 20))
          (df (* (clamp-f duty 0 1000) 20))
          (t0 (/ tf 1000)) (d0 (/ df 1000))
          (t1 (min-f (+ t0 1) 20)) (d1 (min-f (+ d0 1) 20))
          (tw (mod tf 1000)) (dw (mod df 1000))
          (v00 (map-get-cell t0 d0)) (v01 (map-get-cell t0 d1))
          (v10 (map-get-cell t1 d0)) (v11 (map-get-cell t1 d1))
          (v0 (+ v00 (/ (* (- v01 v00) dw) 1000)))
          (v1 (+ v10 (/ (* (- v11 v10) dw) 1000))))
        (+ v0 (/ (* (- v1 v0) tw) 1000))))

(defun thermal-peak (thr response hold)
    (let ((base (pow thr response)))
        (+ base (* (- thr base) hold (clamp01 (/ (- thr 0.6) 0.4))))))

(defun shape-curve (p shape)
    (cond ((= shape 0) p)
          ((= shape 1) (* p p))
          ((= shape 2) (- 1.0 (pow (- 1.0 p) 3)))
          (t (pow p 4))))

(defun thermal-cell (thr duty peak balance coupling width shape brake overrun curve)
    (cond
        ((< thr 0.02) (- (* brake (pow duty (+ 1.0 curve)))))
        ; Zero speed coupling selects duty-independent electric torque.
        ((= coupling 0.0) peak)
        (t
            (let ((start (clamp01 (- balance width))))
                (cond
                    ((<= duty start) peak)
                    ((<= duty balance)
                        (* peak (- 1.0 (shape-curve
                            (/ (- duty start) (max-f 0.001 (- balance start))) shape))))
                    (t (- (* overrun (pow
                        (clamp01 (/ (- duty balance) (max-f 0.001 (- 1.0 balance))))
                        (+ 1.0 curve))))))))))

(defun gen-thermal-map (response coupling width shape hold brake overrun curve)
    (looprange ti 0 21
        (let ((thr (/ ti 20.0))
              (peak (thermal-peak thr response hold))
              (balance (clamp01 (* thr coupling))))
            (looprange di 0 21
                (map-set-cell ti di
                    (to-fp (thermal-cell thr (/ di 20.0) peak balance coupling
                                        width shape brake overrun curve)))))))
@const-end
