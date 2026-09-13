# Map and EEPROM format

## Runtime map

21 throttle points by 21 absolute-duty points, at 5% intervals.
Index = throttle_index * 21 + duty_index. Each cell is a signed byte
in -100..100, representing -1.00..1.00 at 1% resolution.
The buffer is mutable RAM, never constant flash.

Lookup accepts throttle/duty in 0..1000 and clamps at the edges. It
interpolates the four adjacent cells using integer arithmetic; the result
is scaled by 1000. Positive values command relative propulsion current.
Negative values command relative brake current.

The generator computes peak = throttle ^ torque_response, then blends
towards throttle above 60% according to high_hold. An exponent below 1
increases low-throttle response; above 1 softens it. With nonzero speed
coupling, balance duty = clamp(throttle * coupling), with a shaped taper
over transition_width before balance and overrun regen after balance.
The released row uses -engine_brake * duty ^ (1 + regen_curve).
Zero speed coupling selects duty-independent torque (Direct Electric),
while retaining the released-row brake. QML previews the same formula.

## EEPROM layout

There are 128 persistent 32-bit slots. Layout is retained from format
20260912; new saves use marker 20260913 and add a checksum.

| Slot | Content |
| --- | --- |
| 0 | Format marker; 0 means incomplete/invalid |
| 1 | Throttle source |
| 2, 3 | Throttle min/max, integers scaled by 1000 |
| 4 | Invert in bit 0, deadband scaled by 1000 in bits 8+ |
| 5 | Filter alpha scaled by 1000, 1..1000 |
| 6 | Preset id, 0..4 |
| 7, 8, 9 | float32 torque response, speed coupling, transition width |
| 10 | Transition shape |
| 11, 12, 13 | float32 high hold, engine brake, overrun regen |
| 14 | Regen curve |
| 15..125 | Four offset map bytes per word; first cell in least significant byte |
| 126 | Brake mode, 0..2 |
| 127 | CRC16 of slots 0..126 encoded as big-endian words |

Each cell is stored as signed_value + 128. Padding cells in the last slot
represent zero. Packing promotes to u32 **before** shifts; ordinary Lisp
integers cannot hold all four bytes on a 32-bit VESC. Reading arbitrary
words uses bufget-u32 then to-i32, avoiding versions of bufget-i32 which
return a narrowed fixnum.

Save snapshots the current map/configuration, pauses output until the operation
finishes, invalidates slot 0, writes changed slots only, checks every written
word by re-reading it, writes the checksum, and commits the marker last.
An identical save performs no flash writes. eeprom-store-i already writes
flash; conf-store is unnecessary and would also persist unrelated app/motor
settings.

Load checks marker, field ranges, map byte ranges, completeness and checksum
before applying anything. Invalid data leaves the active configuration alone;
at boot only, failed load generates the default map. Valid 20260912 data is
accepted without CRC and upgraded on the next explicit save. Earlier formats
and already-corrupt legacy maps are rejected, because truncated bits cannot
be recovered reliably.

This is a single-image store: a power cut during an update can invalidate
the previous save. It detects partial updates, but does not promise rollback.
EEPROM is shared with other Lisp packages and is not preserved across every
firmware update. Save only while stopped; motor output is paused until the
operation completes. Errors produce a failure status, never “saved”.
