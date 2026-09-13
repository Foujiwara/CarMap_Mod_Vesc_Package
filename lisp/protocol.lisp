; Protocol constants and reusable event-task status buffer. See docs/protocol.md.
(define status-packet (array-create 3))
@const-start

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
(defun fx-dec (v) (/ v 1000.0))

(defun proto-send (buf) (send-data buf))

(defun proto-send-status (code cmd)
    (let ((b status-packet))
    (progn
        (bufset-u8 b 0 pkt-status)
        (bufset-u8 b 1 code)
        (bufset-u8 b 2 cmd)
        (proto-send b))))

@const-end
