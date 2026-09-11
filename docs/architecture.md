# Architecture

## Goals and constraints

- The final motor command is always **relative current** (`set-current-rel`,
  range -1.0..+1.0). This package never issues a duty-cycle command and
  never touches motor-config current limits - it only decides *how much*
  of the already-configured current envelope to request.
- All native VESC protections (current, ERPM, duty, temperature, voltage,
  hardware faults) stay fully in force. This package cannot see or bypass
  them, by construction: it only calls `set-current-rel`.
- The control loop runs entirely in LispBM. See "Why not C" below.

## File layout

```
CarMap_Mod_Vesc_Package/
  pkgdesc.qml         VESC Tool package descriptor (--buildPkgFromDesc)
  ui.qml.in           QML UI template (-> ui.qml at build time)
  package_README.md   Package description shown in VESC Tool
  Makefile            Calls `vesc_tool --buildPkgFromDesc pkgdesc.qml`
  version, package_name
  lisp/
    package.lisp      Entry point: imports the other files, spawns threads
    util.lisp         clamp/min/max helpers
    map.lisp          21x21 grid storage (flat f32 byte array) + bilinear
                       interpolation + the default map generator
    throttle.lisp      ADC/PPM/UART reading, normalization, filtering
    storage.lisp       eeprom-store-f/i persistence (see map_format.md)
    protocol.lisp      Packet ids + tiny encode helpers shared with QML
  docs/
    architecture.md    This file
    protocol.md         QML <-> Lisp wire protocol
    map_format.md       Map resolution, indexing, storage packing
```

## Why a single `ui.qml` and multiple `.lisp` files

A VESC Package (see `pkgdesc.qml` above, and the official packages in
[vedderb/vesc_pkg](https://github.com/vedderb/vesc_pkg)) declares exactly
**one** QML file and **one** LispBM entry file. There is no package-level
mechanism to ship a second, independently-typed `.qml` component file, so
`ui.qml.in` defines every tab inline as a `Component { ... }` inside one
`Item`, loaded through `Loader { sourceComponent: ... }`.

LispBM is different: `import "file.lisp" 'binding` loads a sibling file as
a **read-only byte array** (not executed), and the byte array is then run
with `read-eval-program`. `lisp/package.lisp` does exactly that for each of
the other four files, in dependency order (see the comment at the top of
that file). This keeps the real-time code split into readable modules
without needing a package-level multi-file QML mechanism that doesn't
exist.

## Why LispBM, not C, for the control loop

Packages like Float/Refloat compile their control loop to C because they
run **closed-loop balance control** at 500-1000 Hz, where a few
milliseconds of extra latency can mean a rider falls. This package instead
performs a static lookup (bilinear interpolation over a 21x21 grid, a
handful of float multiplications) followed by one `set-current-rel` call,
comparable in weight to Refloat's own `bms.lisp` (which *is* plain LispBM).
A ~100 Hz LispBM loop (`sleep 0.01`) is far faster than any driveline or
human-perceptible timescale here, so there is no measured or expected
benefit to a native C library, at the cost of a cross-compilation
toolchain, no ability to test without hardware, and a native-code sandbox
escape hatch that isn't needed. If real-world testing on hardware ever
shows otherwise, only `map-lookup` + the `set-current-rel` call would need
to move into a native library - not the rest of the package.

## Threads

`lisp/package.lisp` spawns three concurrent LispBM processes:

1. **Event handler** (`spawn event-handler`) - blocks on `recv` for
   `event-data-rx`, dispatches incoming QML packets (see protocol.md).
2. **Control loop** (`carmap-ctl`, ~100 Hz) - read throttle/duty/erpm,
   bilinear-interpolate the map, `set-current-rel`, `timeout-reset`.
3. **Telemetry loop** (`carmap-tel`, 20 Hz) - sends one compact LIVE
   packet. The full map/config are *never* sent proactively, only on
   request (`REQUEST_MAP` / `REQUEST_CFG`, e.g. on QML `Component.onCompleted`).

## Throttle source abstraction

`throttle.lisp` exposes a single `thr-read` function returning 0.0..1.0
regardless of source. Adding a new source (e.g. CAN-forwarded throttle from
another VESC) means adding one more branch in `thr-read-raw` and one more
enum value on both the LispBM and QML sides - the control loop and map
code never need to change. Sources: 0 ADC, 1 PPM, 2 UART, 3 Test
(bench, via USB - see below).

### Bench-testing without ADC/PPM/UART hardware wired up

Real ADC/PPM/UART wiring isn't always available on a bench. Source 3
("Test") lets the QML Configurator tab drive the control loop directly
over the same USB/CAN link VESC Tool is already connected through
(`SET_TEST_THROTTLE`, see `docs/protocol.md`) - this is not the same thing
as VESC Tool's own built-in duty/current bench-test panel (that one
commands the motor directly over the commands interface and never touches
this package's control loop at all). It's meant purely for exercising the
map/control loop end-to-end without hardware. There is no automatic
timeout on it: the Configurator tab has an explicit **STOP** button next
to the bench slider, the same idea as VESC Tool's own Stop button - use
it before disconnecting or switching source.

Per the official LispBM docs' own recommendation, the corresponding
ADC/PPM app's control type should be set to **Off** in App Settings so
that app doesn't also try to drive the motor - but the app itself must
stay **enabled**, only its Control Type dropdown goes to Off
(`ADC_CTRL_TYPE_NONE` / equivalent). Disabling the app outright also
stops it decoding the raw signal at all, which `get-adc-decoded`/
`get-ppm` depend on, so this package would see no input either.
Confirmed on real hardware: app disabled entirely -> no throttle
response; app enabled with Control Type left on anything but Off ->
jerky/stuttering acceleration (both the app and this package driving
the motor from the same signal at once). This package does not modify
App Settings itself; that one manual step is documented in
`package_README.md`.

## Why the 3D view is an isometric Canvas, not "real" 3D

VESC Tool's QML runtime is not guaranteed to ship Qt3D/QtQuick3D modules
(they are heavy, platform-dependent, and not used by any official package
we found in vedderb/vesc_pkg), and the CDN-style "just import a 3D engine"
option that exists for web content doesn't apply inside a native Qt QML
package. Rather than depend on a module that may not be present on a given
VESC Tool build (desktop vs. mobile), the 3D tab draws a hand-rolled
isometric projection on a 2D `Canvas` (X = duty, depth = throttle, height
and color = Current Rel), which needs nothing beyond `QtQuick` itself and
degrades gracefully everywhere the 2D heatmap already works. The heatmap
and curve views remain the primary, fully-supported ways to read the map.
