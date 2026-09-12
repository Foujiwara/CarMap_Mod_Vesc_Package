# QML <-> LispBM protocol

Transport: `Commands::sendCustomAppData(QByteArray)` /
`Commands::customAppDataReceived(QByteArray)` on the QML side, matched by
`send-data` / the `event-data-rx` event on the LispBM side (both are real,
documented VESC extensions - see the "Custom App Data" / "Events" chapters
of the LispBM reference in `vedderb/bldc`). Every packet's first byte is a
command id; all multi-byte integers are **big-endian**, matching LispBM's
`bufget-*`/`bufset-*` default byte order.

Fixed-point encoding: values roughly in -1.0..1.0 (or 0.0..1.0) are sent as
a signed 16-bit integer scaled by 1000 (`fx-enc`/`fx-dec` in
`lisp/protocol.lisp`, `fxEnc`/`fxDec` in `ui.qml.in`). This keeps packets
small without sending raw floats over the wire.

For the throttle-calibration fields (`min`/`max`/`deadband`/`filter` in
`SET_THROTTLE`/`CFG_ECHO`), the map cell fields (`SET_CELL`/
`SET_MAP_ROW`/`MAP_ROW`), and the throttle/brake/current-rel fields in
`LIVE`, this x1000 scale is *also* the LispBM side's own internal
representation now (`fp-scale` in `util.lisp`) - not just a wire
encoding. `fx-enc`/`fx-dec` are skipped entirely for those fields
(the raw wire `i16` is read/written directly); they're still used for
the map-generator parameters (`torque_resp`, `speed_coupling`, etc.),
which stay real floats internally since `gen-thermal-map` needs `pow`.
See `util.lisp`'s `fp-scale` comment for why: on this 32-bit target,
every float (and even `to-i32`) allocates a heap cell, confirmed by
reading lispBM's own `heap.c`, while plain integer arithmetic does
not - real hardware showed heap usage near saturation from the 200 Hz
control loop's own float math before this change.

## QML -> Lisp

| id | name | payload |
|----|------|---------|
| 0x01 | SET_CELL | `thr_idx:u8 duty_idx:u8 value:i16` |
| 0x02 | SET_MAP_ROW | `row_idx:u8 value0:i16 ... value20:i16` (21 cells) |
| 0x03 | SET_CONFIG | `preset:u8 torque_resp:i16 speed_coupling:i16 trans_width:i16 trans_shape:u8 high_hold:i16 engine_brake:i16 overrun_regen:i16 regen_curve:u8` |
| 0x04 | SET_THROTTLE | `source:u8 invert:u8 min:i16 max:i16 deadband:i16 filter:i16 brake_mode:u8 (0=off 1=dual 2=bidir)` |
| 0x05 | CMD_SAVE | (none) |
| 0x06 | CMD_LOAD | (none) |
| 0x07 | CMD_RESET | (none) |
| 0x08 | REQUEST_MAP | (none) -> triggers one 0x81 packet per row (21 total) |
| 0x09 | REQUEST_CFG | (none) -> triggers one 0x83 packet |
| 0x0A | SET_TEST_THROTTLE | `value:i16` |

`SET_TEST_THROTTLE` only has an effect while the throttle source is set to
**Test (bench, via USB)** (source id 3, see `docs/architecture.md`). It
lets the QML UI drive the control loop directly over whatever link VESC
Tool is already connected through (USB or CAN), for bench-testing with no
ADC/PPM/UART hardware wired up. It bypasses min/max/deadband/invert
calibration (the UI already sends a clean 0..1 value) but still goes
through the same low-pass filter as every other source. There is no
automatic timeout: the Configurator tab has an explicit **STOP** button
next to the bench slider (mirroring VESC Tool's own Stop button) that
sends `SET_TEST_THROTTLE 0` immediately - use it before disconnecting or
switching source, the same way you would with any other bench test.

`SET_CONFIG` with `preset > 0` (1=Street, 2=Race, 3=Wet, 4=Direct Electric)
tells the VESC to regenerate the *entire* map from
`gen-thermal-map` using the given parameters. `preset == 0` (Custom) only
updates the stored parameters, leaving any manually-edited cells alone.

## Lisp -> QML

| id | name | payload |
|----|------|---------|
| 0x80 | LIVE | `throttle:i16 duty:i16 erpm:i32 cur_rel:i16 cur_a:i16(x100) brake:i16` |
| 0x81 | MAP_ROW | `row_idx:u8 value0:i16 ... value20:i16` |
| 0x82 | STATUS | `code:u8` (0=ok, 1=saved, 2=loaded, 3=reset) |
| 0x83 | CFG_ECHO | mirrors the payloads of 0x03 then 0x04, concatenated, with `brake_mode:u8 (0=off 1=dual 2=bidir)` appended at the end |

`LIVE` is sent unconditionally at ~20 Hz whenever the package is running,
whether or not VESC Tool is even connected (`send-data` is a no-op if
nothing is listening). `MAP_ROW`/`CFG_ECHO` are only sent in response to a
request, and status packets only after a command that changes something,
so the link is never saturated with unrequested map/config traffic - only
the small LIVE packet is periodic.

## Design notes

- The protocol is intentionally package-private: there is no VESC-wide
  standard for what a package's custom app data means, each package
  defines its own (this is normal - see how Refloat structures its own
  binary protocol for lights/alerts/telemetry).
- Row-based map transfer (21 x 21 = 441 cells) was chosen over a single
  giant packet to stay well under typical custom-app-data payload sizes
  and to make partial updates (one edited row) cheap.
