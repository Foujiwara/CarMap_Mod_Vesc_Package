; util.lisp - tiny shared helpers, loaded first by package.lisp.

(defun clamp-f (v lo hi)
    (if (< v lo) lo (if (> v hi) hi v)))

(defun clamp01 (v) (clamp-f v 0.0 1.0))

(defun max-f (a b) (if (> a b) a b))
(defun min-f (a b) (if (< a b) a b))
