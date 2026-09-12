; util.lisp - tiny shared helpers, loaded first by package.lisp.

(defun clamp-f (v lo hi)
    (if (< v lo) lo (if (> v hi) hi v)))

(defun clamp01 (v) (clamp-f v 0.0 1.0))

(defun max-f (a b) (if (> a b) a b))
(defun min-f (a b) (if (< a b) a b))

; Shared -1.0..1.0 <-> signed-byte quantization (1% resolution), used by
; both map.lisp (the live RAM buffer, see the note there) and
; storage.lisp (the eeprom packing) - defined here, loaded first, so
; both can use it regardless of which one runs first.
(defun cell-to-i8 (v) (to-i (* (clamp-f v -1.0 1.0) 100.0)))
(defun i8-to-cell (v) (/ (to-float v) 100.0))
