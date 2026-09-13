# Architecture

CarMap runs three LispBM processes: the input/control loop (nominal 200 Hz,
150-word stack), telemetry (20 Hz, 80 words), and the serial command handler
(256 words). Actual frequency depends on the firmware scheduler and GC.

The entry point imports five Lisp sources and evaluates them incrementally.
Immutable functions and constants live in flash via `@const-start`.
Configuration globals and byte buffers are defined outside these blocks.
Moving the mutable map into a constant block makes writes fail; separate
source files do not require private copies of shared arithmetic helpers.

The 441-cell map occupies 441 RAM bytes. Control calculations use signed
28-bit fixnums scaled by 1000. This reduces boxed numeric allocations; local
environments and function calls still consume heap cells. The ADC voltage
is sampled once per tick in bidirectional mode and converted to millivolts.
RPM is read only by telemetry. The EMA retains a fractional accumulator so
small deltas cannot leave a permanent positive throttle after release.

Each sender owns a reusable packet buffer: live 15 bytes, row 44 bytes,
configuration 27 bytes, status 3 bytes. EEPROM operations temporarily allocate
a 508-byte image, reclaimed by GC. Buffers must not be shared between the
telemetry and command processes.

Positive map output uses `set-current-rel`; negative output uses
`set-brake-rel` with a positive magnitude. Signed current alone would request
reverse torque rather than direction-independent braking. Native firmware
limits remain active. There is no extra `timeout-reset` call because both
motor commands already reset the firmware timeout.

Sources: ADC, PPM, UART, and USB Test. Keep the ADC/PPM input decoder enabled
and its control type Off. Bidirectional ADC uses the midpoint of configured
start/end voltages, supports reversed endpoints, and applies deadband.
After changing those ADC endpoints in App Settings, apply the package's
throttle settings again (or restart) to invalidate the calibration cache.

UART accepts A5 / percent (0..200) / XOR checksum, preserving partial frames.
UART, Test and PPM input expires after 500 ms without a valid update; expired
input clears the filter and requests zero current. The UI refreshes an active
bench command every 100 ms; STOP clears both the bench value and filter.

Commands validate length, indices and all fields before mutation. Map generation,
configuration replacement and EEPROM operations pause motor output while they
run. A recoverable command error returns an explicit failure status; a fatal
interpreter error still requires restarting the script.

QML sends one queued command at a time and waits for its correlated status.
This prevents a 21-row upload overflowing the receiver mailbox. Bench commands
bypass this queue so STOP remains responsive; their acknowledgements cannot
complete another command. Full-map reads verify all 21 rows arrived.

See [protocol](protocol.md), [storage layout](map_format.md),
[audit](audit-2026-09-12.md) and [tests](../tests/README.md).
