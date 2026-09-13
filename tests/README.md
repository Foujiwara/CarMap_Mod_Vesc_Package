# Regression tests

The application runs in the real LispBM interpreter; only VESC sensors,
motor output, custom transport, EEPROM and time are mocked. The program is
loaded incrementally with its flash directives intact. Module bodies are
concatenated for this harness; the .vescpkg uses actual imported modules.

Tested on 32-bit LispBM commit
`48f9259cb5aa6315ca37aa80fa814914c3fac1f1`, GCC, Ubuntu/WSL.
The test runner requires a C compiler with 32-bit libc (Ubuntu:
gcc-multilib), make, git and Node.js. No VESC connection is used.

```sh
git clone https://github.com/svenssonjoel/lispBM.git .test-runtime/lispBM
git -C .test-runtime/lispBM checkout 48f9259cb5aa6315ca37aa80fa814914c3fac1f1
make -C .test-runtime/lispBM/tests test_lisp_code_cps_time
node tests/prepare-lisp.mjs
.test-runtime/lispBM/tests/test_lisp_code_cps_time -i -h 2048 -t 25 .test-runtime/regression.lisp
node tests/ui.test.mjs
```

The upstream runner returns **1 on success** and prints SUCCESS.
An “injected-write-error” trapped diagnostic is expected: it tests cleanup
after an EEPROM failure. The final memory report includes the mocks and
test globals; it is not a measurement on a physical controller.

Coverage includes map/config cold reload, all quantized byte values and final
map padding, legacy migration, CRC corruption, missing slots, silent failed
writes, explicit errors, unchanged-save write count, direct preset, bounds,
filter settling, inversion/deadband, bench/PPM expiry, partial UART frames,
single ADC sample for bidirectional mode, brake routing, malformed commands,
custom generation and imported-map preservation. A 10,000-tick worker uses
the production 150-word control stack.

The Node test executes JavaScript extracted from ui.qml.in and tests command
ordering, correlated replies, save ordering, malformed replies, incomplete
downloads and import validation. It does not emulate Qt rendering.

Build the installable package with VESC Tool:
`./build.ps1 -VescTool 'C:/path/to/vesc_tool.exe'` on Windows,
or `./build.sh /path/to/vesc_tool` on Linux.
