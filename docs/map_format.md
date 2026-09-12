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

`map-buf` is a single LispBM byte array of `21*21 = 441` bytes, one
signed byte per cell (`bufget-i8`/`bufset-i8`, via `cell-to-i8`/
`i8-to-cell` in `util.lisp` - the same -100..100 = -1.00..1.00, 1%-step
quantization the eeprom persistence already uses, see below). Reading
or writing a cell is one `bufget`/`bufset` call - no cons cells, no
list traversal, no GC pressure in the control loop. This used to be
32-bit floats (1764 bytes, no quantization until the next save); the
smaller int8 representation quarters the buffer's memory footprint and
means a freshly-generated map already has the exact same precision as
one just reloaded from eeprom, instead of drifting to it only after
the first save.

Index: `flat = thr_idx * 21 + duty_idx`, byte offset `flat` (one byte
per cell, so index and byte offset are the same number).

## Bilinear interpolation

Given `throttle01` and `duty01` in **fp-scale** (0..1000, see
`util.lisp` - not 0.0..1.0 float; `duty01` is `abs(get-duty)` converted
to fp-scale by the caller, see note below). All-integer arithmetic
(confirmed cheaper on this target: every float allocates a heap cell,
plain integers don't - see `util.lisp`'s `fp-scale` comment):

```
tf = throttle01 * 20      ; 20 = map-thr-n - 1, still fp-scale
df = duty01 * 20
t0 = tf / 1000, t1 = min(t0+1, 20), tw = tf - t0*1000
d0 = df / 1000, d1 = min(d0+1, 20), dw = df - d0*1000
v0 = cell[t0,d0] + (cell[t0,d1] - cell[t0,d0]) * dw / 1000
v1 = cell[t1,d0] + (cell[t1,d1] - cell[t1,d0]) * dw / 1000
result = v0 + (v1 - v0) * tw / 1000      ; fp-scale, -1000..1000
```

This used to be float arithmetic (`tf`/`df` in 0.0..20.0, weights
0.0..1.0, `lerp(a,b,w) = a + (b-a)*w`); the integer version above is
mathematically the same lerp, just with the 0..1 weight expressed as an
integer 0..1000 and an explicit `/1000` where the float version's
multiply by a 0..1 weight did the scaling implicitly.

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
  map (111 slots), 126 holds the brake mode (0=off, 1=dual-channel
  ADC2, 2=bidirectional single-channel ADC1), 127 is
  reserved for future use. See the header
  comment in `storage.lisp` for the exact field order.
- Addresses 2/3/4/5 (throttle min/max/deadband/filter) are `eeprom-store-i`
  now, not `-f`: those four fields became fp-scale integers (see
  "Bilinear interpolation" above and `util.lisp`), so they're stored as
  plain integers instead of an IEEE-754 float bit pattern. `eeprom-magic`
  was bumped for this reason - an old save's bytes for these 4 fields
  would decode to nonsense if read back under the new format, so the
  magic change makes `storage-load` correctly treat any pre-existing
  save as invalid and fall through to `storage-reset` instead, a
  one-time reset to defaults rather than silently misreading bytes.

`storage-save` writes all of the above then calls `conf-store` once so the
eeprom write is committed to flash the same way the rest of the firmware
persists its eeprom data. `storage-load` checks the magic value first and
returns `nil` (caller then calls `storage-reset`, which also generates the
Thermal Street default map) if nothing valid has ever been saved.

**Every `eeprom-store-f`/`eeprom-store-i` call requires the motor to be
genuinely released first, not just "the vehicle stopped".** Reading
`mc_interface.c` in vedderb/bldc: each one calls
`mc_interface_wait_for_motor_release_both`, which polls
`mcpwm_foc_get_state()` for up to 3 seconds waiting for `MC_STATE_OFF`
- and if that timeout is hit, the underlying firmware function returns
as if it succeeded without ever writing anything, so `storage-save`
reports success (`STATUS` code 1) while some or all values silently
never reach flash.

The important part: `MC_STATE_OFF` means *no active current command at
all*, not "vehicle stationary". This package's own `control-loop`
calls `set-current-rel` unconditionally every tick, even when
commanding 0 A - that still counts as "controlling", not "released",
so **every single `storage-save` would fail to persist anything, 100%
of the time, regardless of vehicle motion**, unless something
temporarily stops the control loop from driving during the save.

Before assuming the fix needed to wait out the VESC's configured motor
timeout: it doesn't. `mc_interface_release_motor_override_both`
(called internally by every `eeprom-store-f`/`-i`, right before the
wait) is an *explicit, immediate* release
(`mcpwm_foc_release_motor()`), not something that depends on the
configured timeout elapsing naturally. The only thing that can defeat
it is this script itself immediately re-asserting `set-current-rel`
again before the next poll notices the release - so the actual fix is
just "don't do that for the whole save", nothing more elaborate.
`storage-pause-ticks` (`storage.lisp`) is that: `storage-save` sets it
before touching eeprom, `control-loop` skips
`set-current-rel`/`timeout-reset` entirely while it's nonzero, and it
decrements on its own every tick regardless of what `storage-save`
does, so it can never get stuck even if `storage-save` itself errors.
