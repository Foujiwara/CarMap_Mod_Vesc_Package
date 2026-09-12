; storage.lisp - persist the map + config to the emulated eeprom
; (eeprom-store-f / eeprom-store-i, addresses 0..127, see bldc lispBM docs).
;
; Layout (see docs/map_format.md for the authoritative version):
;   0   magic/version (i32)              - EEPROM-MAGIC when valid data present
;   1   throttle source (i32)
;   2   throttle min, fp-scale (i32)     - see util.lisp; was f32 before
;   3   throttle max, fp-scale (i32)     ; the fixed-point rewrite, bumped
;   4   invert(bit0) | deadband fp-scale (bits 8..31) (i32) ; eeprom-magic
;   5   throttle filter alpha, fp-scale (i32) ; below to force a fresh reset
;   6   preset id (i32)
;   7   torque response (f32)
;   8   speed coupling (f32)
;   9   transition width (f32)
;   10  transition shape (i32)
;   11  high throttle hold (f32)
;   12  engine braking (f32)
;   13  overrun regen (f32)
;   14  regen curve (i32)
;   15..125  map cells, 4 int8 (offset +128, i.e. -100..100 -> 0..255-ish) packed per i32
;            111 slots * 4 = 444 >= 441 cells
;   126 brake mode (i32, 0=off 1=dual-channel ADC2 2=bidirectional ADC1)

; Bumped from 20260911: addresses 2/3/4/5 changed from f32 (IEEE-754
; bit pattern) to plain fp-scale i32 (throttle.lisp's fixed-point
; rewrite) - a different byte representation entirely, so a device with
; an old save must NOT have it reinterpreted as the new format (it
; would decode to nonsense min/max/deadband/filter values). Bumping the
; magic makes storage-load correctly treat any pre-existing save as "no
; valid data" and fall through to storage-reset instead - a one-time
; reset of calibration/map/brake-mode back to defaults on first boot
; with this version, which is far safer than silently misreading bytes.
(define eeprom-magic 20260912)
(define eeprom-map-base 15)
(define eeprom-map-slots 111)

(defun pack4 (v0 v1 v2 v3)
    (bitwise-or (bitwise-or (byte-u v0) (shl (byte-u v1) 8))
                (bitwise-or (shl (byte-u v2) 16) (shl (byte-u v3) 24))))

(defun byte-u (v) (bitwise-and (+ v 128) 0xff))
(defun byte-s (v) (- (bitwise-and v 0xff) 128))

; cell-to-i8/i8-to-cell moved to util.lisp (loaded before map.lisp,
; which needs them too now that map-buf stores i8 cells directly - see
; the comment there).

(defun storage-save ()
    (progn
        (eeprom-store-i 1 thr-cfg-source)
        ; thr-cfg-min/max/deadband/filter are already fp-scale integers
        ; (throttle.lisp) - stored with eeprom-store-i, not -f, and no
        ; *1000 scaling here since they're already at that scale.
        (eeprom-store-i 2 thr-cfg-min)
        (eeprom-store-i 3 thr-cfg-max)
        (eeprom-store-i 4 (bitwise-or thr-cfg-invert (shl thr-cfg-deadband 8)))
        (eeprom-store-i 5 thr-cfg-filter)
        (eeprom-store-i 6 cfg-preset)
        (eeprom-store-f 7 cfg-torque-resp)
        (eeprom-store-f 8 cfg-speed-coupling)
        (eeprom-store-f 9 cfg-trans-width)
        (eeprom-store-i 10 cfg-trans-shape)
        (eeprom-store-f 11 cfg-high-hold)
        (eeprom-store-f 12 cfg-engine-brake)
        (eeprom-store-f 13 cfg-overrun-regen)
        (eeprom-store-i 14 cfg-regen-curve)
        (eeprom-store-i 126 thr-cfg-brake-mode)
        (looprange s 0 eeprom-map-slots
            (let ((c0 (+ (* s 4) 0)) (c1 (+ (* s 4) 1))
                  (c2 (+ (* s 4) 2)) (c3 (+ (* s 4) 3)))
            (eeprom-store-i (+ eeprom-map-base s)
                (pack4 (map-cell-flat-i8 c0) (map-cell-flat-i8 c1)
                       (map-cell-flat-i8 c2) (map-cell-flat-i8 c3)))
            ))
        (eeprom-store-i 0 eeprom-magic)
        (conf-store-quiet)
        t
    ))

; conf-store also stores motor/app config; we only touch our own eeprom
; range, but call conf-store so the eeprom write is committed to flash
; the same way the rest of the firmware persists eeprom data.
(defun conf-store-quiet () (conf-store))

; map-buf (map.lisp) already stores the quantized i8 value directly at
; byte offset == flat cell index, so these are now a straight
; bufget-i8/bufset-i8 with no float round-trip - one less conversion on
; both the save path (111 slots) and the load path.
(defun map-cell-flat-i8 (flat-idx)
    (if (< flat-idx map-cells)
        (bufget-i8 map-buf flat-idx)
        0))

(defun map-set-flat (flat-idx val)
    (if (< flat-idx map-cells) (bufset-i8 map-buf flat-idx val) nil))

(defun storage-load ()
    (if (eq (eeprom-read-i 0) eeprom-magic)
        (progn
            (define thr-cfg-source (eeprom-read-i 1))
            (define thr-cfg-min (eeprom-read-i 2))
            (define thr-cfg-max (eeprom-read-i 3))
            (let ((packed (eeprom-read-i 4)))
                (define thr-cfg-invert (bitwise-and packed 1))
                (define thr-cfg-deadband (shr packed 8)))
            (define thr-cfg-filter (eeprom-read-i 5))
            (define cfg-preset (eeprom-read-i 6))
            (define cfg-torque-resp (eeprom-read-f 7))
            (define cfg-speed-coupling (eeprom-read-f 8))
            (define cfg-trans-width (eeprom-read-f 9))
            (define cfg-trans-shape (eeprom-read-i 10))
            (define cfg-high-hold (eeprom-read-f 11))
            (define cfg-engine-brake (eeprom-read-f 12))
            (define cfg-overrun-regen (eeprom-read-f 13))
            (define cfg-regen-curve (eeprom-read-i 14))
            (define thr-cfg-brake-mode (eeprom-read-i 126))
            (looprange s 0 eeprom-map-slots
                (let ((packed (eeprom-read-i (+ eeprom-map-base s))))
                (progn
                    (map-set-flat (+ (* s 4) 0) (byte-s (bitwise-and packed 0xff)))
                    (map-set-flat (+ (* s 4) 1) (byte-s (bitwise-and (shr packed 8) 0xff)))
                    (map-set-flat (+ (* s 4) 2) (byte-s (bitwise-and (shr packed 16) 0xff)))
                    (map-set-flat (+ (* s 4) 3) (byte-s (bitwise-and (shr packed 24) 0xff)))
                )))
            t)
        nil ; no valid data yet -> caller should generate a default map
    ))

; Defaults match the "Thermal Street" preset (id 1) in ui.qml.in, so a
; brand new install already feels sane before anyone opens the
; Configurator tab.
(defun storage-reset ()
    (progn
        (define cfg-preset 1)
        (define cfg-torque-resp 0.85)
        (define cfg-speed-coupling 1.0)
        (define cfg-trans-width 0.10)
        (define cfg-trans-shape 1)
        (define cfg-high-hold 0.55)
        (define cfg-engine-brake 0.15)
        (define cfg-overrun-regen 0.12)
        (define cfg-regen-curve 1)
        (define thr-cfg-source thr-src-adc)
        (define thr-cfg-invert 0)
        (define thr-cfg-min 20)     ; 0.02, fp-scale (throttle.lisp)
        (define thr-cfg-max 980)    ; 0.98
        (define thr-cfg-deadband 20) ; 0.02
        (define thr-cfg-filter 1000) ; no filtering by default - see
                                     ; throttle.lisp, filtering felt like
                                     ; input latency on real hardware
        (define thr-cfg-brake-mode 0)
        (gen-thermal-map cfg-torque-resp cfg-speed-coupling cfg-trans-width
                          cfg-trans-shape cfg-high-hold cfg-engine-brake
                          cfg-overrun-regen cfg-regen-curve)
        t
    ))
