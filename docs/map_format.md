# Map format

## Grid

- 21 throttle points x 21 duty points, both axes 0%, 5%, 10%, ... 100%.
- `map.lisp`: `map-thr-n` / `map-duty-n` (both 21). Change these to
  change resolution; the protocol's `SET_MAP_ROW` payload (21 i16 values)
  and the QML `mapN` constant must be updated to match if you do.
- Cell values: Current Relative, clamped to -1.00..+1.00.
  `+1.0` = 100% of the VESC's configured positive motor current,
  `0.0` = freewheel, negative = regen/motor braking, `-1.0` = 100% of the
  configured negative current. The map is independent of the actual amp
  values configured on the VESC - it only ever produces a -1..1 ratio.

## In-RAM representation

`map-buf` is a single LispBM byte array of `21*21*4 = 1764` bytes, storing
32-bit floats (`bufget-f32`/`bufset-f32`). Reading or writing a cell is one
`bufget`/`bufset` call - no cons cells, no list traversal, no GC pressure
in the control loop.

Index: `flat = thr_idx * 21 + duty_idx`, byte offset `flat * 4`.

## Bilinear interpolation

Given normalized `throttle01` (0..1) and `duty01` (0..1, taken from
`abs(get-duty)` - see note below):

```
tf = throttle01 * 20      ; 20 = map-thr-n - 1
df = duty01 * 20
t0 = floor(tf), t1 = min(t0+1, 20), tw = tf - t0
d0 = floor(df), d1 = min(d0+1, 20), dw = df - d0
v0 = lerp(cell[t0,d0], cell[t0,d1], dw)
v1 = lerp(cell[t1,d0], cell[t1,d1], dw)
result = lerp(v0, v1, tw)
```

`abs(get-duty)` note: the map only has a duty axis 0..100%, i.e. it treats
forward and reverse rotation symmetrically. This matches how the requested
behavior is specified (throttle vs. duty, not throttle vs. signed duty)
and keeps the grid one-sided; direction itself is handled by
`set-current-rel`'s own sign convention (same as `set-current`), not by
this map.

## Default map generator (`gen-thermal-map`)

Implements the "Thermal Street/Race/Wet/Direct Electric" presets and the
Configurator's free parameters:

- **Torque Response** (`torque-resp`): `peak(thr) = thr ^ torque-resp`
  before High Throttle Hold is applied. `<1` = progressive/concave (soft
  low end), `1` = linear, `>1` = aggressive (soft top only).
- **High Throttle Hold** (`high-hold`, 0..1): blends `peak` toward `thr`
  itself for throttle above ~60%, so top-end throttle keeps more of its
  requested current instead of following the concave/convex curve.
- **Speed Coupling** (`speed-coupling`): `balance-duty(thr) = thr *
  speed-coupling` - the duty at which current-rel crosses zero for this
  throttle row. `1.0` means "50% throttle balances around 50% duty".
- **Transition Width** (`trans-width`) and **Transition Shape**
  (`trans-shape`: 0 linear, 1 progressive, 2 exponential, 3 late/abrupt):
  shape the taper from `peak` down to 0 over the duty range
  `[balance-duty - trans-width, balance-duty]`.
- **Overrun Regen** (`overrun-regen`) and **Regen Curve** (`regen-curve`):
  once duty exceeds `balance-duty` while throttle is still partially open,
  a small negative current grows from 0 toward `-overrun-regen` as duty
  approaches 100%, shaped by `(fraction) ^ (1 + regen-curve)`.
- **Engine Braking** (`engine-brake`): applied on the throttle-released
  row (`thr < 0.02`) only: `-engine-brake * duty ^ (1 + regen-curve)`, i.e.
  progressive brake that grows with speed, never a hard snap to full brake.

The QML Configurator tab (`ui.qml.in`, `regenerateLocalMap`) mirrors this
exact formula in JavaScript purely so the heatmap can preview instantly;
the VESC always regenerates authoritatively from the LispBM version when
`SET_CONFIG` is received with `preset > 0`.

## Persistence (`storage.lisp`)

The emulated eeprom (`eeprom-store-f`/`eeprom-store-i`, addresses 0..127,
documented in the LispBM reference) is the only persistent storage
available to a package without a native library. 128 slots is not enough
for 441 raw floats, so:

- Each cell is quantized to a signed byte in -100..100 (`cell-to-i8`),
  offset by +128 to store as an unsigned byte 0..255 (`byte-u`/`byte-s`),
  giving 0.01 (1%) resolution - imperceptible for this use case.
- Four bytes are packed into one 32-bit slot with `eeprom-store-i`
  (`pack4`), so the 441 cells fit in `ceil(441/4) = 111` slots.
- Layout (addresses 0..127): address 0 is a magic/version marker, 1..14
  hold the throttle + configurator parameters, 15..125 hold the packed
  map (111 slots), 126 holds the brake-channel-enable flag, 127 is
  reserved for future use. See the header
  comment in `storage.lisp` for the exact field order.

`storage-save` writes all of the above then calls `conf-store` once so the
eeprom write is committed to flash the same way the rest of the firmware
persists its eeprom data. `storage-load` checks the magic value first and
returns `nil` (caller then calls `storage-reset`, which also generates the
Thermal Street default map) if nothing valid has ever been saved.
