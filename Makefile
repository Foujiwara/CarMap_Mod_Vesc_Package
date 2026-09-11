# CarMap Thermal Throttle - VESC Package build
#
# This mirrors the build convention used by the official packages in
# https://github.com/vedderb/vesc_pkg (see e.g. refloat/Makefile): the
# actual .vescpkg is produced by VESC Tool itself via its command-line
# packaging mode, not by any tool in this repo.
#
# Usage:
#   make                              # build carmap_thermal_throttle.vescpkg
#   make VESC_TOOL=/path/to/vesc_tool # point at a specific VESC Tool binary
#   make clean
#
# Requirements: a VESC Tool build that supports --buildPkgFromDesc
# (desktop VESC Tool 6.05+). See docs/architecture.md if your VESC Tool
# only has the GUI "Pack" button and no working CLI flag - the same
# ui.qml + lisp/package.lisp can be packed manually from there instead.

VESC_TOOL ?= vesc_tool
# use `make MINIFY_QML=1` if you have rjsmin.py available and want a
# smaller ui.qml embedded in the package; default is verbatim (no minify)
# to avoid depending on a third-party script that isn't vendored here.
MINIFY_QML ?= 0

PACKAGE_OUT = carmap_thermal_throttle.vescpkg

all: $(PACKAGE_OUT)

$(PACKAGE_OUT): lisp/package.lisp lisp/util.lisp lisp/map.lisp lisp/throttle.lisp lisp/storage.lisp lisp/protocol.lisp package_README-gen.md ui.qml pkgdesc.qml
	"$(VESC_TOOL)" --buildPkgFromDesc pkgdesc.qml

VERSION := $(shell cat version)
PACKAGE_NAME := $(shell cat package_name | cut -c-20)

ifeq ($(strip $(MINIFY_QML)),1)
    MINIFY_CMD = ./rjsmin.py
else
    MINIFY_CMD = cat
endif

package_README-gen.md: package_README.md version
	cp $< $@
	echo "" >> $@
	echo "### Build Info" >> $@
	echo "- Version: $(VERSION)" >> $@
	echo "- Build Date: $$(date --rfc-3339=seconds 2>/dev/null || date)" >> $@
	echo "- Git Commit: #$$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >> $@

ui.qml: ui.qml.in package_name version
	cat $< | \
	sed "s/{{PACKAGE_NAME}}/$(PACKAGE_NAME)/g" | \
	sed "s/{{VERSION}}/$(VERSION)/g" | \
	$(MINIFY_CMD) > $@

clean:
	rm -f $(PACKAGE_OUT) package_README-gen.md ui.qml

.PHONY: all clean
