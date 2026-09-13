; EEPROM layout remains compatible with 20260912; slot 127 now holds
; CRC16 of slots 0..126 (big-endian words). New saves use 20260913.
; Only complete, validated images are applied to the live state.
(define storage-busy nil)

@const-start
(define eeprom-magic 20260913)
(define eeprom-legacy-magic 20260912)
(define eeprom-map-base 15)
(define eeprom-map-slots 111)

; Avoid firmware versions where bufget-i32 narrows to a 28-bit fixnum.
(defun storage-buffer-i32 (b offset) (to-i32 (bufget-u32 b offset)))

; Promote BEFORE shifting: plain LispBM integers have only 28 bits on VESC.
(defun pack4 (v0 v1 v2 v3)
    (bitwise-or
        (bitwise-or (to-u32 (+ v0 128)) (shl (to-u32 (+ v1 128)) 8))
        (bitwise-or (shl (to-u32 (+ v2 128)) 16) (shl (to-u32 (+ v3 128)) 24))))

(defun map-cell-flat-i8 (i)
    (if (< i map-cells) (bufget-i8 map-buf i) 0))

(defun storage-image ()
    (let ((b (array-create 508)))
        (progn (bufset-i32 b 0 eeprom-magic)
        (bufset-i32 b 4 thr-cfg-source)
        (bufset-i32 b 8 thr-cfg-min)
        (bufset-i32 b 12 thr-cfg-max)
        (bufset-i32 b 16 (bitwise-or thr-cfg-invert (shl thr-cfg-deadband 8)))
        (bufset-i32 b 20 thr-cfg-filter)
        (bufset-i32 b 24 cfg-preset)
        (bufset-f32 b 28 cfg-torque-resp)
        (bufset-f32 b 32 cfg-speed-coupling)
        (bufset-f32 b 36 cfg-trans-width)
        (bufset-i32 b 40 cfg-trans-shape)
        (bufset-f32 b 44 cfg-high-hold)
        (bufset-f32 b 48 cfg-engine-brake)
        (bufset-f32 b 52 cfg-overrun-regen)
        (bufset-i32 b 56 cfg-regen-curve)
        (bufset-i32 b 504 thr-cfg-brake-mode)
        (looprange s 0 eeprom-map-slots
            (bufset-u32 b (+ 60 (* s 4))
                (pack4 (map-cell-flat-i8 (* s 4))
                       (map-cell-flat-i8 (+ (* s 4) 1))
                       (map-cell-flat-i8 (+ (* s 4) 2))
                       (map-cell-flat-i8 (+ (* s 4) 3)))))
        b)))

; Readback is mandatory: some firmware paths return true without writing
; if motor release times out. Unchanged slots incur no flash writes.
(defun storage-write-word (addr value)
    (let ((old (eeprom-read-i addr)))
        (if (and (number? old) (= old value))
            t
            (and (eeprom-store-i addr value)
                (let ((actual (eeprom-read-i addr)))
                    (and (number? actual) (= actual value)))))))

(defun storage-write-image (b)
    (let ((checksum (crc16 b)) (same t))
        (progn (looprange s 0 127
            (let ((old (eeprom-read-i s)))
                (if (not (and (number? old) (= old (storage-buffer-i32 b (* s 4)))))
                    (setq same nil))))
        (if (and same (let ((old (eeprom-read-i 127)))
                          (and (number? old) (= old checksum))))
            t
            ; Invalidate FIRST, commit marker LAST. A power failure leaves
            ; an invalid image, never a mix of old and new settings.
            (and (storage-write-word 0 0)
                (let ((ok t))
                    (progn (looprange s 1 127
                        (if ok
                            (setq ok (storage-write-word s (storage-buffer-i32 b (* s 4))))))
                    (and ok (storage-write-word 127 checksum)
                         (storage-write-word 0 eeprom-magic)))))))))

(defun storage-save ()
    (progn
        (setq storage-busy t)
        (sleep 0.01)
        (let ((result (trap (storage-write-image (storage-image)))))
            (progn (setq storage-busy nil)
            (eq result '(exit-ok t))))))

; Range checks reject missing fields, NaNs, corrupt calibration and maps.
(defun storage-image-valid (b)
    (and
        (in-range (storage-buffer-i32 b 4) 0 3)
        (in-range (storage-buffer-i32 b 8) 0 1000)
        (in-range (storage-buffer-i32 b 12) 0 1000)
        (< (storage-buffer-i32 b 8) (storage-buffer-i32 b 12))
        (= (bitwise-and (storage-buffer-i32 b 16) 0xfe) 0)
        (in-range (shr (storage-buffer-i32 b 16) 8) 0 999)
        (in-range (storage-buffer-i32 b 20) 1 1000)
        (in-range (storage-buffer-i32 b 24) 0 4)
        (in-range (bufget-f32 b 28) 0.3 2.0)
        (in-range (bufget-f32 b 32) 0.0 1.5)
        (in-range (bufget-f32 b 36) 0.02 0.30)
        (in-range (storage-buffer-i32 b 40) 0 3)
        (in-range (bufget-f32 b 44) 0.0 1.0)
        (in-range (bufget-f32 b 48) 0.0 0.6)
        (in-range (bufget-f32 b 52) 0.0 0.5)
        (in-range (storage-buffer-i32 b 56) 0 3)
        (in-range (storage-buffer-i32 b 504) 0 2)
        (let ((ok t))
            (progn (looprange i 0 map-cells
                (if (not (in-range (storage-image-cell b i) -100 100))
                    (setq ok nil)))
            ok))))

(defun storage-image-cell (b i)
    ; Packed slot's least significant byte is the first cell.
    (- (bufget-u8 b (+ 60 (* (/ i 4) 4) (- 3 (mod i 4)))) 128))

(defun storage-apply-image (b)
    (progn
        (setq thr-cfg-source (to-i (storage-buffer-i32 b 4)))
        (setq thr-cfg-min (to-i (storage-buffer-i32 b 8)))
        (setq thr-cfg-max (to-i (storage-buffer-i32 b 12)))
        (setq thr-cfg-filter (to-i (storage-buffer-i32 b 20)))
        (setq cfg-preset (to-i (storage-buffer-i32 b 24)))
        (setq cfg-torque-resp (bufget-f32 b 28))
        (setq cfg-speed-coupling (bufget-f32 b 32))
        (setq cfg-trans-width (bufget-f32 b 36))
        (setq cfg-trans-shape (to-i (storage-buffer-i32 b 40)))
        (setq cfg-high-hold (bufget-f32 b 44))
        (setq cfg-engine-brake (bufget-f32 b 48))
        (setq cfg-overrun-regen (bufget-f32 b 52))
        (setq cfg-regen-curve (to-i (storage-buffer-i32 b 56)))
        (setq thr-cfg-brake-mode (to-i (storage-buffer-i32 b 504)))
        (setq thr-cfg-invert (to-i (bitwise-and (storage-buffer-i32 b 16) 1)))
        (setq thr-cfg-deadband (to-i (shr (storage-buffer-i32 b 16) 8)))
        (looprange i 0 map-cells
            (bufset-i8 map-buf i (storage-image-cell b i)))
        (thr-reset-state)
        t))

(defun storage-read-image ()
    (let ((magic (eeprom-read-i 0)))
        ; eq would reject the i32 returned by EEPROM against a plain integer.
        (if (and (number? magic)
                 (or (= magic eeprom-magic) (= magic eeprom-legacy-magic)))
            (let ((b (array-create 508)) (ok t))
                (progn (looprange s 0 127
                    (let ((v (eeprom-read-i s)))
                        (if (number? v)
                            (bufset-i32 b (* s 4) v)
                            (setq ok nil))))
                (if (and ok (storage-image-valid b)
                         (or (= magic eeprom-legacy-magic)
                             (let ((sum (eeprom-read-i 127)))
                                 (and (number? sum) (= sum (crc16 b))))))
                    (storage-apply-image b)
                    nil)))
            nil)))

(defun storage-load ()
    (progn
        (setq storage-busy t)
        (sleep 0.01)
        (let ((result (trap (storage-read-image))))
            (progn (setq storage-busy nil)
            (eq result '(exit-ok t))))))

(defun storage-reset ()
    (progn
        (setq cfg-preset 1)
        (setq cfg-torque-resp 0.85)
        (setq cfg-speed-coupling 1.0)
        (setq cfg-trans-width 0.10)
        (setq cfg-trans-shape 1)
        (setq cfg-high-hold 0.55)
        (setq cfg-engine-brake 0.15)
        (setq cfg-overrun-regen 0.12)
        (setq cfg-regen-curve 1)
        (setq thr-cfg-source thr-src-adc)
        (setq thr-cfg-invert 0)
        (setq thr-cfg-min 20)
        (setq thr-cfg-max 980)
        (setq thr-cfg-deadband 20)
        (setq thr-cfg-filter 1000)
        (setq thr-cfg-brake-mode 0)
        (thr-reset-state)
        (gen-thermal-map cfg-torque-resp cfg-speed-coupling cfg-trans-width
                         cfg-trans-shape cfg-high-hold cfg-engine-brake
                         cfg-overrun-regen cfg-regen-curve)
        t))
@const-end
