; Arithmetic values in the control path are 28-bit fixnums (scale 1000).
; Function code is immutable; buffers and mutable globals stay outside blocks.
@const-start
(define fp-scale 1000)
(defun clamp-f (v lo hi) (if (< v lo) lo (if (> v hi) hi v)))
(defun clamp01 (v) (clamp-f v 0.0 1.0))
(defun max-f (a b) (if (> a b) a b))
(defun min-f (a b) (if (< a b) a b))
(defun in-range (v lo hi) (and (number? v) (>= v lo) (<= v hi)))
(defun to-fp (raw) (to-i (* raw 1000.0)))
(defun fp-to-f (v) (/ v 1000.0))
(defun cell-to-i8 (v) (clamp-f (/ v 10) -100 100))
(defun i8-to-cell (v) (* v 10))
@const-end
