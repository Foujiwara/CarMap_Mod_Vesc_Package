# CarMap Thermal Throttle

A [VESC Package](https://github.com/vedderb/vesc_pkg) (LispBM + QML) that
replaces plain throttle-to-current control with a configurable
**Throttle x Duty -> Current Relative** map, tuned by default to feel like
a thermal-engine powertrain instead of a flat electric current curve.

- `+1.0` current-rel = 100% of the VESC's configured positive motor current
- `0.0` = freewheel
- negative = regen / motor braking, `-1.0` = 100% of configured negative current

The map is independent of the actual amps configured on the VESC, and the
motor commands use `set-current-rel` for propulsion and `set-brake-rel`
for braking. Every native VESC protection (current/ERPM/duty/temperature/
voltage limits) stays fully in control.

![status](https://img.shields.io/badge/status-first_working_version-blue)
![license](https://img.shields.io/badge/license-GPLv3-blue)

## Features

- Throttle source: ADC, PPM or UART, with min/max/deadband/invert/filter
  calibration and a clean seam for adding more sources later.
- 21x21 Throttle x Duty grid, bilinear interpolation, ~200 Hz control
  loop, entirely in LispBM (see [docs/architecture.md](docs/architecture.md)).
- Automatic map generator with 4 presets (Thermal Street, Thermal Race,
  Wet, Direct Electric) plus 8 free parameters (torque response, speed
  coupling, transition width/shape, high-throttle hold, engine braking,
  overrun regen, regen curve) - see [docs/map_format.md](docs/map_format.md).
- QML UI: live heatmap with a real-time throttle/duty dot, 2D cross-section
  curves per throttle row, a pseudo-3D isometric view, manual cell/row/
  column editing (bump %, smooth, copy/paste, interpolate a selection),
  and text-based export/import.
- Persisted on the VESC itself (emulated eeprom), survives VESC Tool
  disconnects and controller reboots - see [docs/map_format.md](docs/map_format.md#eeprom-layout).
- A compact, package-private binary protocol between QML and LispBM - see
  [docs/protocol.md](docs/protocol.md).

## Repository layout

```
pkgdesc.qml, ui.qml.in, package_README.md, Makefile, version, package_name
lisp/        package.lisp, util.lisp, map.lisp, throttle.lisp,
             storage.lisp, protocol.lisp
docs/        architecture.md, protocol.md, map_format.md
```

See [docs/architecture.md](docs/architecture.md) for the full breakdown.

## Building the `.vescpkg`

Windows: `./build.ps1 -VescTool 'C:/path/to/vesc_tool.exe'`.

Version 0.1.52 includes the [code audit and fixes](docs/audit-2026-09-12.md).
See [tests/README.md](tests/README.md) for repeatable 32-bit LispBM and UI tests.

This repo follows the same build convention as the official packages in
[vedderb/vesc_pkg](https://github.com/vedderb/vesc_pkg) (e.g. `refloat/`):
the actual `.vescpkg` is produced by **VESC Tool itself**, via its
command-line packaging mode.

```bash
make                              # -> carmap_thermal_throttle.vescpkg
make VESC_TOOL=/path/to/vesc_tool # if vesc_tool isn't on PATH
```

This runs `vesc_tool --buildPkgFromDesc pkgdesc.qml` (desktop VESC Tool
6.05+). If your VESC Tool build only exposes the GUI **Pack** button and
not a working `--buildPkgFromDesc` flag, you can pack manually instead:
open VESC Tool -> Developer/Custom Config page -> point it at `ui.qml`
and `lisp/package.lisp` from this repo -> **Pack** -> save as
`carmap_thermal_throttle.vescpkg`.

## Installing

1. VESC Tool -> **VESC Packages** -> install the built/downloaded
   `carmap_thermal_throttle.vescpkg` onto your VESC.
2. In **App Settings**, keep the app for the input you intend to use
   (ADC / PPM / UART) **enabled/active** - just change its **Control
   Type** dropdown to **Off** (`ADC_CTRL_TYPE_NONE` / equivalent). This
   is two different settings: disabling the app entirely also stops it
   decoding the signal at all, so this package would see no input
   either; leaving Control Type on anything other than Off means the
   app *and* this package both try to drive the motor from the same
   signal at once, which shows up as jerky/stuttering acceleration
   (confirmed on real hardware - see the LIVE feedback: if `Throttle`
   never moves, the app is decoding nothing; if the motor stutters
   in bursts, the app's own control type is still active). This is the
   one existing setting this package expects you to change; it does
   not touch anything else in your motor/app config.
3. Open the new **CarMap** tab, pick a throttle source + calibration, pick
   a preset (or tune the Configurator by hand), **Apply parameters ->
   generate map**, then **Save to VESC**.

## Status / testing

Built and reviewed against the real LispBM extension set (`vedderb/bldc`
lispBM docs) and the real VESC Package conventions (`vedderb/vesc_pkg`,
notably `refloat/`), but **not yet run on physical hardware** - there is
no VESC connected to this development environment. Before riding:

- Bench-test with the wheel off the ground first, confirm the live dot on
  the Map tab tracks your throttle/duty as expected, and confirm the
  default Thermal Street map's engine-braking feel at 0% throttle before
  trusting it at speed.
- Start with conservative motor current limits in the standard VESC motor
  config regardless of this package's map, since this package only ever
  requests a *fraction* of whatever those limits allow.

## License

GPL-3.0-or-later, matching the license used by the official VESC Packages
repository. See [LICENSE](LICENSE).
