; util.lisp - tiny shared helpers, loaded first by package.lisp.
;
; @const-start/@const-end (see the LispBM reference's "Flash memory"
; chapter) moves every global definition inside the block to constant
; memory (flash) instead of the normal RAM heap - real hardware showed
; heap sitting at ~97% used even at idle, before any of this package's
; own runtime data existed, because every defun's code is itself a tree
; of cons cells that otherwise lives on the tiny RAM heap permanently,
; just for the program to exist.
;
; A first attempt (v0.1.46) wrapped every file this way, each in its
; own separate block, and crashed on real hardware with a type_error in
; bufset-i8 ("v UNDEFINED") - almost certainly from cell-to-i8 (this
; file's flash block) being called from map.lisp's OWN separate flash
; block, i.e. a cross-file call between two different @const-start
; blocks. Reverted (v0.1.47), and this file is deliberately the first,
; narrowest retry: every function here only ever calls another function
; in this SAME file, or a native extension - never anything from
; another file's own block - so wrapping only this file tests whether
; @const-start works at all on this firmware without the cross-file
; interaction that broke the last attempt. map.lisp/throttle.lisp/
; storage.lisp/package.lisp are deliberately left unwrapped this time,
; since they all call into this file and each other across file
; boundaries - do not wrap them until this narrower change is confirmed
; working on real hardware.
@const-start

(defun clamp-f (v lo hi)
    (if (< v lo) lo (if (> v hi) hi v)))

(defun clamp01 (v) (clamp-f v 0.0 1.0))

(defun max-f (a b) (if (> a b) a b))
(defun min-f (a b) (if (< a b) a b))

; ---------------------------------------------------------------------
; Fixed-point (integer) helpers for the hot path (control-loop and
; everything it calls, up to 200 Hz).
;
; Why: confirmed by reading lispBM's own heap.c - on this 32-bit target,
; lbm_enc_float AND lbm_enc_i32 (what `to-i32`, and any literal typed
; with a decimal point, produce) both call lbm_cons(...), i.e. every
; single float or i32 value allocates one heap cell. `to-i` (and plain
; integer arithmetic - `+`/`-`/`*`/`/` between two integers, confirmed
; in fundamental.c) instead produces LBM_TYPE_I, an inline tagged value
; that costs zero heap cells. A control loop doing float math was
; therefore allocating and immediately garbage-collecting dozens of
; heap cells every tick just from arithmetic, at 200 Hz.
;
; `fp-scale` (1000) matches the wire protocol's own existing x1000
; fixed-point convention (fx-enc/fx-dec in protocol.lisp) exactly on
; purpose: values that travel over the wire (throttle calibration, map
; cells, live telemetry) need no conversion at all now - the on-the-
; wire i16 IS the internal representation, just read/written directly.
;
; This can't remove every float: get-adc-decoded, get-ppm, get-duty,
; get-rpm, get-current and conf-get are native extensions that always
; return a real (boxed) float - that's firmware behavior, not something
; a package can change. `to-fp` below is the one unavoidable float box
; per raw sensor read, immediately collapsed to a fixnum; everything
; downstream of it (normalize, filter, map lookup) is then pure integer
; and allocates nothing.
(define fp-scale 1000)

; raw is a real (float, 0.0..1.0 or so) straight from a sensor read;
; returns the fp-scale fixnum equivalent. The multiply here still boxes
; one intermediate float (raw is already a float, so the product is
; too) before to-i collapses it - unavoidable at this single point, but
; it replaces what used to be a float propagating through 5+ more
; function calls.
(defun to-fp (raw) (to-i (* raw 1000.0)))

; fp-scale fixnum -> real float, needed only where a native extension
; genuinely requires a float argument (set-current-rel).
(defun fp-to-f (v) (/ (to-float v) 1000.0))

; Shared -1.0..1.0 (fp-scale, i.e. -1000..1000) <-> signed-byte
; quantization (1% resolution), used by map.lisp (the live RAM buffer,
; see the note there). Both sides are plain integers now - no floats,
; no heap allocation.
(defun cell-to-i8 (v) (clamp-f (/ v 10) -100 100))
(defun i8-to-cell (v) (* v 10))

@const-end
