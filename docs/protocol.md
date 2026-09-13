# QML / LispBM protocol

Transport: sendCustomAppData / customAppDataReceived and event-data-rx /
send-data. Integers are big-endian. Relative values use signed i16 scaled
by 1000, except current in amps, which uses i16 scaled by 100.
Map cells and throttle calibration use that same integer scale internally.

## Commands

| Id | Name | Total bytes / payload |
| --- | --- | --- |
| 01 | SET_CELL | 5: throttle:u8 duty:u8 value:i16 |
| 02 | SET_MAP_ROW | 44: row:u8 and 21 values:i16 |
| 03 | SET_CONFIG | 16 or 17: preset:u8 torque:i16 coupling:i16 width:i16 shape:u8 hold:i16 engine_brake:i16 overrun:i16 regen_curve:u8 [regenerate:u8] |
| 04 | SET_THROTTLE | 12: source:u8 invert:u8 min:i16 max:i16 deadband:i16 filter:i16 brake_mode:u8 |
| 05 | SAVE | 1 |
| 06 | LOAD | 1 |
| 07 | RESET | 1 |
| 08 | REQUEST_MAP | 1 |
| 09 | REQUEST_CFG | 1 |
| 0A | SET_TEST_THROTTLE | 3: value:i16 |

The optional regenerate byte separates generator action from preset identity:
1 regenerates even for Custom (preset 0); 0 preserves the current map even
when importing a named preset. Legacy 16-byte commands retain the original
preset > 0 behavior. Save transmits displayed settings and all rows with
regenerate=0, then requests persistence. Import validates the entire JSON
first, includes brake mode, sends metadata without regeneration, then rows.

All packet lengths, indices, enum fields and numeric ranges are validated
before mutation. Filter alpha must be at least 1 (0.001); zero would freeze
the throttle. min must be below max.

## Replies

| Id | Name | Total bytes / payload |
| --- | --- | --- |
| 80 | LIVE | 15: throttle:i16 duty:i16 erpm:i32 current_rel:i16 current_A:i16 brake:i16 |
| 81 | MAP_ROW | 44: row:u8 and 21 values:i16 |
| 82 | STATUS | 3: status:u8 original_command:u8 |
| 83 | CFG_ECHO | 27: config fields followed by throttle fields, including brake mode |

Status: 0 OK, 1 saved and verified, 2 loaded, 3 reset, 4 save failed,
5 no valid saved image, 6 invalid packet, 7 command execution failed.
REQUEST_MAP/REQUEST_CFG send their payloads before status 0.
Use matching 0.1.52 QML/Lisp components: the queue requires correlated
three-byte statuses and will time out with an older controller script.

QML allows one queued command in flight with a 20-second timeout and verifies
all rows on full-map reads. A failure cancels the remaining transaction, so
SAVE cannot run after a failed row/config upload. Timeout is not success;
read back before retrying. Test commands bypass this queue, are refreshed
every 100 ms while active, and expire on the controller after 500 ms.
LIVE runs at 20 Hz, and its values never replace the last command result.
