# CarMap Thermal Throttle

Replaces plain throttle-to-current control with a configurable **Throttle x
Duty -> Current Relative** map, tuned to feel like a thermal-engine
powertrain: strong low-end pull that holds, a natural taper as the vehicle
approaches the throttle's "equilibrium" speed, mild overrun regen past that
point, and progressive engine braking on lift-off.

The final motor command is always a **relative current** (`set-current-rel`,
-1.0..+1.0), never a duty-cycle command, so all of the VESC's native
protections (current limits, ERPM limits, duty limits, temperature,
voltage) remain fully in charge.

## What it does

- Reads throttle from ADC, PPM or UART (selectable), normalizes it to
  0..1 with configurable min/max/deadband/invert/filter.
- Reads the current duty cycle and ERPM.
- Looks up a 21x21 Throttle x Duty grid with bilinear interpolation to get
  a Current Relative value every control loop iteration (~100 Hz).
- Sends that value with `set-current-rel`.

## Setup (one-time, in VESC Tool)

1. In **App Settings**, keep the app for your input (ADC / PPM / UART)
   **enabled**, and set only its **Control Type** dropdown to **Off**.
   Disabling the app entirely also stops it decoding the signal, so
   this package would see no input; leaving Control Type on anything
   else means the app and this package both try to drive the motor at
   once, which shows up as jerky/stuttering acceleration.
2. Open the **CarMap** tab.
3. Pick a throttle source and calibrate min/max/deadband if needed.
4. Pick a preset (Thermal Street / Thermal Race / Wet / Direct Electric)
   or dial in the Configurator parameters yourself, then
   **Apply parameters -> generate map**.
5. **Save to VESC** so the map and settings survive a reboot.

See the Map / Curves / 3D tabs to inspect and hand-edit the map, and the
live dot to see where you are on it while riding.

Full documentation: `docs/architecture.md`, `docs/protocol.md`,
`docs/map_format.md` in the source repository.
