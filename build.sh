#!/bin/bash
# build.sh - replicates the Makefile's pipeline by hand (no `make` binary
# in this environment). ALWAYS use this to rebuild the .vescpkg - never
# call vesc_tool --buildPkgFromDesc directly, since pkgdesc.qml points at
# the *generated* ui.qml / package_README-gen.md (both gitignored build
# artifacts), not at ui.qml.in / package_README.md directly. Calling
# vesc_tool directly silently repackages whatever stale ui.qml happens to
# already be sitting on disk - this is exactly what caused v0.1.36
# through v0.1.41 (six releases) to all ship the v0.1.35 UI unchanged.
#
# Usage: ./build.sh [path-to-vesc_tool-binary]
set -e
cd "$(dirname "$0")"

VESC_TOOL="${1:-vesc_tool}"
VERSION=$(cat version)
PACKAGE_NAME=$(cut -c-20 package_name)

cp package_README.md package_README-gen.md
{
    echo ""
    echo "### Build Info"
    echo "- Version: $VERSION"
    echo "- Build Date: $(date --rfc-3339=seconds 2>/dev/null || date)"
    echo "- Git Commit: #$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
} >> package_README-gen.md

sed -e "s/{{PACKAGE_NAME}}/$PACKAGE_NAME/g" -e "s/{{VERSION}}/$VERSION/g" ui.qml.in > ui.qml

"$VESC_TOOL" --buildPkgFromDesc pkgdesc.qml

echo "Built carmap_thermal_throttle.vescpkg (version $VERSION)"
grep -o 'buildMarker: [0-9]*' ui.qml
