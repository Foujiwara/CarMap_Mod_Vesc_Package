; protocol.lisp - CarMap custom app-data protocol (QML <-> LispBM)
;
; Every packet's first byte is a command id. Numeric fields use big-endian
; bufget-*/bufset-* (the LispBM default byte order) unless noted.
;
; Packets are always built as real byte arrays (array-create + bufset-*),
; never as a plain list of Lisp numbers: `send-data` accepts either, but a
; list has no documented guarantee that a value like 850 (a fixed-point
; i16) survives intact rather than being narrowed to a single byte. A byte
; array we've already laid out ourselves removes that ambiguity entirely
; and matches exactly what the QML side parses with DataView.
;
; QML -> Lisp
;   0x01 SET_CELL      [0x01 thr_idx:u8 duty_idx:u8 value:i16(x1000)]
;   0x02 SET_MAP_ROW   [0x02 row_idx:u8 value0:i16 ... value20:i16]  (21 cells)
;   0x03 SET_CONFIG    [0x03 preset:u8 torque_resp:i16(x1000) speed_coupling:i16(x1000)
;                        trans_width:i16(x1000) trans_shape:u8 high_hold:i16(x1000)
;                        engine_brake:i16(x1000) overrun_regen:i16(x1000) regen_curve:u8]
;   0x04 SET_THROTTLE  [0x04 source:u8 invert:u8 min:i16(x1000) max:i16(x1000)
;                        deadband:i16(x1000) filter:i16(x1000)]
;   0x05 CMD_SAVE      [0x05]
;   0x06 CMD_LOAD      [0x06]
;   0x07 CMD_RESET     [0x07]
;   0x08 REQUEST_MAP   [0x08]   -> triggers 0x81 dump, one packet per row
;   0x09 REQUEST_CFG   [0x09]   -> triggers 0x83 config echo
;   0x0A SET_TEST_THROTTLE [0x0A value:i16(x1000)]  -> only applied while
;        throttle source == Test (bench), see docs/architecture.md. Lets
;        the QML UI drive the control loop directly over USB/CAN with no
;        ADC/PPM/UART hardware wired up, for bench testing.
;
; Lisp -> QML
;   0x80 LIVE     [0x80 throttle:i16 duty:i16 erpm:i32 cur_rel:i16 cur_a:i16(x100)]
;   0x81 MAP_ROW  [0x81 row_idx:u8 value0:i16 ... value20:i16]
;   0x82 STATUS   [0x82 code:u8]         ; 0 = ok/ack, 1 = saved, 2 = loaded, 3 = reset
;   0x83 CFG_ECHO [0x83 ... mirrors 0x03/0x04 payloads concatenated ...]

(define pkt-set-cell    0x01)
(define pkt-set-map-row 0x02)
(define pkt-set-config  0x03)
(define pkt-set-thr     0x04)
(define pkt-cmd-save    0x05)
(define pkt-cmd-load    0x06)
(define pkt-cmd-reset   0x07)
(define pkt-req-map     0x08)
(define pkt-req-cfg     0x09)
(define pkt-set-test-thr 0x0A)

(define pkt-live        0x80)
(define pkt-map-row     0x81)
(define pkt-status      0x82)
(define pkt-cfg-echo    0x83)

; ---- small helpers -------------------------------------------------------

; Fixed point helpers: the wire format uses i16 scaled by 1000 for values
; that live in roughly the -1.0 .. 1.0 / 0.0 .. 1.0 range. This keeps
; packets small and avoids ever sending a raw float over the wire.
(defun fx-enc (v) (to-i (* v 1000.0)))
(defun fx-dec (v) (/ (to-float v) 1000.0))

(defun proto-send (buf) (send-data buf))

(defun proto-send-status (code)
    (let ((b (array-create 2)))
    (progn
        (bufset-u8 b 0 pkt-status)
        (bufset-u8 b 1 code)
        (proto-send b))))
