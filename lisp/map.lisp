; map.lisp - the Throttle x Duty -> Current Relative map.
;
; The map lives in RAM as one flat byte array of 32-bit floats so the
; real-time loop never allocates: reading/writing a cell is two bufget/
; bufset calls, no lists, no GC pressure.
;
; Grid: THR-N x DUTY-N points, axes 0%..100% inclusive, step = 100/(N-1).
; Default 21 x 21 (5% steps). Change THR-N/DUTY-N here to change resolution;
; everything else (index math, storage packing, protocol row size) derives
; from these two constants except the wire packet size in protocol.lisp
; (21 values/row), which should be updated to match DUTY-N if you resize.

(define map-thr-n 21)
(define map-duty-n 21)
(define map-cells (* map-thr-n map-duty-n))

(define map-buf (array-create (* map-cells 4)))

(defun map-idx (thr-i duty-i) (+ (* thr-i map-duty-n) duty-i))

(defun map-get-cell (thr-i duty-i)
    (bufget-f32 map-buf (* (map-idx thr-i duty-i) 4)))

(defun map-set-cell (thr-i duty-i val)
    (bufset-f32 map-buf (* (map-idx thr-i duty-i) 4)
                (clamp-f val -1.0 1.0)))

; ---- bilinear interpolation ----------------------------------------------
; thr01, duty01 in [0, 1]. duty is expected to already be abs(get-duty).
;
; A single `let` in LispBM allows mutually-referencing bindings (see the
; "let" chapter of the LispBM reference), so this is one environment
; frame instead of five nested ones - called at up to 100+ Hz from
; control-loop, so cutting the per-call allocation matters more here
; than readability alone would justify.
(defun map-lookup (thr01 duty01)
    (let ((tf (* (clamp01 thr01) (- map-thr-n 1)))
          (df (* (clamp01 duty01) (- map-duty-n 1)))
          (t0 (to-i tf))
          (d0 (to-i df))
          (t1 (if (< t0 (- map-thr-n 1)) (+ t0 1) t0))
          (d1 (if (< d0 (- map-duty-n 1)) (+ d0 1) d0))
          (tw (- tf (to-float t0)))
          (dw (- df (to-float d0)))
          (v00 (map-get-cell t0 d0))
          (v01 (map-get-cell t0 d1))
          (v10 (map-get-cell t1 d0))
          (v11 (map-get-cell t1 d1))
          (v0 (+ (* v00 (- 1.0 dw)) (* v01 dw)))
          (v1 (+ (* v10 (- 1.0 dw)) (* v11 dw))))
    (+ (* v0 (- 1.0 tw)) (* v1 tw))
    ))

; ---- default map generator (Thermal Street) -------------------------------
; Mirrors the QML configurator formulas (see docs/map_format.md) so the
; package behaves sanely even before VESC Tool has ever connected.
(defun gen-thermal-map (torque-resp speed-coupling trans-width trans-shape
                         high-hold engine-brake overrun-regen regen-curve)
    (looprange ti 0 map-thr-n
        (let ((thr (/ (to-float ti) (to-float (- map-thr-n 1))))
              (peak (thermal-peak thr torque-resp high-hold))
              (balance-duty (thermal-balance-duty thr speed-coupling)))
        (looprange di 0 map-duty-n
            (let ((duty (/ (to-float di) (to-float (- map-duty-n 1)))))
            (map-set-cell ti di
                (thermal-cell thr duty peak balance-duty trans-width
                              trans-shape engine-brake overrun-regen regen-curve))
            ))
        )))

; Peak current-rel requested at this throttle, before duty shaping.
; torque-resp < 1.0 = progressive (concave), 1.0 = linear, > 1.0 = aggressive.
(defun thermal-peak (thr torque-resp high-hold)
    (let ((base (pow thr torque-resp)))
    ; high-hold (0..1) keeps top-end throttle closer to full peak: blend
    ; base toward `thr` itself as thr approaches 1.0.
    (+ base (* (- thr base) high-hold (thermal-smooth thr)))
    ))

; smoothstep-ish weighting that only kicks in above ~60% throttle so
; high-hold shapes the top of the curve, not the low/mid range.
(defun thermal-smooth (thr)
    (clamp01 (/ (- thr 0.6) 0.4)))

; Duty at which this throttle level is considered "at equilibrium"
; (current-rel crosses zero). speed-coupling 1.0 => balance-duty == thr.
(defun thermal-balance-duty (thr speed-coupling)
    (clamp01 (* thr speed-coupling)))

(defun thermal-cell (thr duty peak balance-duty trans-width trans-shape
                      engine-brake overrun-regen regen-curve)
    (if (< thr 0.02)
        ; throttle released: engine braking that grows with duty
        (- (* engine-brake (pow duty (+ 1.0 regen-curve))))
    (let ((start (clamp01 (- balance-duty trans-width))))
    (cond
        ((<= duty start) peak)
        ((<= duty balance-duty)
            (let ((p (/ (- duty start) (max-f 0.001 (- balance-duty start)))))
            (* peak (- 1.0 (shape-curve p trans-shape)))))
        (t
            (let ((over (/ (- duty balance-duty) (max-f 0.001 (- 1.0 balance-duty)))))
            (- (* overrun-regen (pow (clamp01 over) (+ 1.0 regen-curve))))))
    ))))

; trans-shape: 0 linear, 1 progressive (ease-in), 2 exponential, 3 late/abrupt
(defun shape-curve (p shape)
    (cond
        ((= shape 0) p)
        ((= shape 1) (* p p))
        ((= shape 2) (- 1.0 (pow (- 1.0 p) 3)))
        (t (pow p 4))
    ))
