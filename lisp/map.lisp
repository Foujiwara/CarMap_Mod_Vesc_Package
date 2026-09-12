; map.lisp - the Throttle x Duty -> Current Relative map.
;
; The map lives in RAM as one flat byte array of signed bytes (one per
; cell, -100..100 = -1.00..1.00 in 1% steps via cell-to-i8/i8-to-cell in
; util.lisp) so the real-time loop never allocates: reading/writing a
; cell is one bufget/bufset call, no lists, no GC pressure. This used to
; be 32-bit floats (4 bytes/cell, no quantization in RAM); switched to
; match the 1% resolution the eeprom persistence (storage.lisp) already
; quantizes down to on every save/load, so a freshly-generated map now
; has the exact same precision as one just reloaded after a reboot
; instead of being briefly more precise until the next save - and the
; buffer is 1/4 the size (441 bytes instead of 1764 for 21x21), plus
; every map-get-cell/map-set-cell call moves 1 byte instead of 4,
; called from map-lookup up to 200 Hz/4 cells per control-loop tick.
;
; Grid: THR-N x DUTY-N points, axes 0%..100% inclusive, step = 100/(N-1).
; Default 21 x 21 (5% steps). Change THR-N/DUTY-N here to change resolution;
; everything else (index math, storage packing, protocol row size) derives
; from these two constants except the wire packet size in protocol.lisp
; (21 values/row), which should be updated to match DUTY-N if you resize.

(define map-thr-n 21)
(define map-duty-n 21)
(define map-cells (* map-thr-n map-duty-n))

(define map-buf (array-create map-cells))

(defun map-idx (thr-i duty-i) (+ (* thr-i map-duty-n) duty-i))

(defun map-get-cell (thr-i duty-i)
    (i8-to-cell (bufget-i8 map-buf (map-idx thr-i duty-i))))

(defun map-set-cell (thr-i duty-i val)
    (bufset-i8 map-buf (map-idx thr-i duty-i) (cell-to-i8 val)))

; ---- bilinear interpolation ----------------------------------------------
; thr01, duty01 in fp-scale (0..1000, see util.lisp) - integer, not
; float. duty is expected to already be abs(get-duty), converted to
; fp-scale by the caller (control-loop). Every operation here
; (add/sub/mul/div/compare between two plain integers) stays in
; LispBM's zero-cost inline integer type instead of boxing a float on
; the heap for every intermediate result, which is what this did before
; and was the confirmed cause of high heap usage on real hardware at
; 200 Hz (see util.lisp's fp-scale comment for the lispBM heap.c
; evidence). Returns fp-scale too (-1000..1000): the caller converts to
; a real float only once, right before set-current-rel, the one place a
; float genuinely can't be avoided.
;
; A single `let` in LispBM allows mutually-referencing bindings (see the
; "let" chapter of the LispBM reference), so this is one environment
; frame instead of five nested ones.
(defun map-lookup (thr01 duty01)
    (let ((tf (* (clamp-f thr01 0 fp-scale) (- map-thr-n 1)))
          (df (* (clamp-f duty01 0 fp-scale) (- map-duty-n 1)))
          (t0 (/ tf fp-scale))
          (d0 (/ df fp-scale))
          (t1 (if (< t0 (- map-thr-n 1)) (+ t0 1) t0))
          (d1 (if (< d0 (- map-duty-n 1)) (+ d0 1) d0))
          (tw (- tf (* t0 fp-scale)))
          (dw (- df (* d0 fp-scale)))
          (v00 (map-get-cell t0 d0))
          (v01 (map-get-cell t0 d1))
          (v10 (map-get-cell t1 d0))
          (v11 (map-get-cell t1 d1))
          (v0 (+ v00 (/ (* (- v01 v00) dw) fp-scale)))
          (v1 (+ v10 (/ (* (- v11 v10) dw) fp-scale))))
    (+ v0 (/ (* (- v1 v0) tw) fp-scale))
    ))

; ---- default map generator (Thermal Street) -------------------------------
; Mirrors the QML configurator formulas (see docs/map_format.md) so the
; package behaves sanely even before VESC Tool has ever connected.
;
; Deliberately still float internally (thermal-peak/thermal-cell below
; use `pow`, which has no cheap fixed-point equivalent worth the risk
; of changing the map's actual shape) - unlike map-lookup, this only
; runs once at boot or when a preset/parameter changes, not every
; control-loop tick, so its float cost is a one-time transient burst,
; not a continuous per-tick tax. map-set-cell is the only place the
; float result crosses into the integer/fp-scale domain the rest of
; the map (and the hot path) now lives in - to-fp does that conversion.
(defun gen-thermal-map (torque-resp speed-coupling trans-width trans-shape
                         high-hold engine-brake overrun-regen regen-curve)
    (looprange ti 0 map-thr-n
        (let ((thr (/ (to-float ti) (to-float (- map-thr-n 1))))
              (peak (thermal-peak thr torque-resp high-hold))
              (balance-duty (thermal-balance-duty thr speed-coupling)))
        (looprange di 0 map-duty-n
            (let ((duty (/ (to-float di) (to-float (- map-duty-n 1)))))
            (map-set-cell ti di
                (to-fp (thermal-cell thr duty peak balance-duty trans-width
                                      trans-shape engine-brake overrun-regen regen-curve)))
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
