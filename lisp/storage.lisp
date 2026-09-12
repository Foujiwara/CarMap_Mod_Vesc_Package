; storage.lisp - persist the map + config to the emulated eeprom
; (eeprom-store-f / eeprom-store-i, addresses 0..127, see bldc lispBM docs).
;
; Layout (see docs/map_format.md for the authoritative version):
;   0   magic/version (i32)              - EEPROM-MAGIC when valid data present
;   1   throttle source (i32)
;   2   throttle min (f32)
;   3   throttle max (f32)
;   4   invert(bit0) | deadband*1000 (bits 8..31) (i32)
;   5   throttle filter alpha (f32)
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

(define eeprom-magic 20260911)
(define eeprom-map-base 15)
(define eeprom-map-slots 111)

(defun pack4 (v0 v1 v2 v3)
    (bitwise-or (bitwise-or (byte-u v0) (shl (byte-u v1) 8))
                (bitwise-or (shl (byte-u v2) 16) (shl (byte-u v3) 24))))

(defun byte-u (v) (bitwise-and (+ v 128) 0xff))
(defun byte-s (v) (- (bitwise-and v 0xff) 128))

(defun cell-to-i8 (v) (to-i (* (clamp-f v -1.0 1.0) 100.0)))
(defun i8-to-cell (v) (/ (to-float v) 100.0))

(defun storage-save ()
    (progn
        (eeprom-store-i 1 thr-cfg-source)
        (eeprom-store-f 2 thr-cfg-min)
        (eeprom-store-f 3 thr-cfg-max)
        (eeprom-store-i 4 (bitwise-or thr-cfg-invert
                                       (shl (to-i (* thr-cfg-deadband 1000.0)) 8)))
        (eeprom-store-f 5 thr-cfg-filter)
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

(defun map-cell-flat-i8 (flat-idx)
    (if (< flat-idx map-cells)
        (cell-to-i8 (bufget-f32 map-buf (* flat-idx 4)))
        0))

(defun map-set-flat (flat-idx val)
    (if (< flat-idx map-cells) (bufset-f32 map-buf (* flat-idx 4) val) nil))

(defun storage-load ()
    (if (eq (eeprom-read-i 0) eeprom-magic)
        (progn
            (define thr-cfg-source (eeprom-read-i 1))
            (define thr-cfg-min (eeprom-read-f 2))
            (define thr-cfg-max (eeprom-read-f 3))
            (let ((packed (eeprom-read-i 4)))
                (define thr-cfg-invert (bitwise-and packed 1))
                (define thr-cfg-deadband (/ (to-float (shr packed 8)) 1000.0)))
            (define thr-cfg-filter (eeprom-read-f 5))
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
                    (map-set-flat (+ (* s 4) 0) (i8-to-cell (byte-s (bitwise-and packed 0xff))))
                    (map-set-flat (+ (* s 4) 1) (i8-to-cell (byte-s (bitwise-and (shr packed 8) 0xff))))
                    (map-set-flat (+ (* s 4) 2) (i8-to-cell (byte-s (bitwise-and (shr packed 16) 0xff))))
                    (map-set-flat (+ (* s 4) 3) (i8-to-cell (byte-s (bitwise-and (shr packed 24) 0xff))))
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
        (define thr-cfg-min 0.02)
        (define thr-cfg-max 0.98)
        (define thr-cfg-deadband 0.02)
        (define thr-cfg-filter 1.0) ; no filtering by default - see
                                     ; throttle.lisp, filtering felt like
                                     ; input latency on real hardware
        (define thr-cfg-brake-mode 0)
        (gen-thermal-map cfg-torque-resp cfg-speed-coupling cfg-trans-width
                          cfg-trans-shape cfg-high-hold cfg-engine-brake
                          cfg-overrun-regen cfg-regen-curve)
        t
    ))
