# CarMap Thermal Throttle

A configurable 21 x 21 throttle/duty map drives relative propulsion current
and relative brake current. Native VESC current, voltage, temperature and
speed limits remain active.

## Setup

1. Keep the ADC/PPM input app enabled and set its **Control Type** to **Off**,
   so it decodes the input without also commanding the motor.
2. Open **CarMap**, select and calibrate the input, then apply throttle settings.
3. Select a preset or adjust the generator and press **Apply parameters**.
4. Use **Save to VESC** while stopped. This uploads the displayed map and
   parameters, writes EEPROM and verifies the result. Wait for “saved and
   verified”; output is paused during saving.
5. Use **Load from VESC** to check the stored data. Restart the controller
   and check again before relying on the new settings.

Version 0.1.52 fixes persistence, mutable-map flash placement, custom generator
application, Direct Electric behavior and imported-map overwrites. Valid
20260912 EEPROM saves migrate automatically on the next save; corrupt or
older formats require reconfiguration. An interrupted save is detected and
may require saving again.

Test mode has a STOP button and a 500 ms communication watchdog. UART and
PPM also stop commanding current when input updates expire. Test with the
wheel unloaded after installation; automated tests use simulated hardware,
not a connected VESC.

Source documentation includes the audit report and repeatable 32-bit LispBM tests.
