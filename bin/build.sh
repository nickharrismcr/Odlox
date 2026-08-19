#!/usr/bin/env bash
# Builds odlox into bin/odlox.exe. Run from anywhere; cds to the repo root first.
#
# Usage: bin/build.sh [--release]
#   (no args)   Debug build: -debug -vet -strict-style. Enables ODIN_DEBUG,
#               so --debug/--instrument/--trace-gc's hooks (src/debug/trace.odin)
#               are actually compiled in instead of warning and no-opping.
#   --release   Release/benchmark build: -o:speed -disable-assert
#               -no-bounds-check, no ODIN_DEBUG. This is the flag set
#               benchmark baselines (bin/benchmarks.sh) are measured
#               against -- don't change it without re-measuring.
set -e
cd "$(dirname "$0")/.."

ODIN=odin
if ! command -v "$ODIN" >/dev/null 2>&1; then
	ODIN="$HOME/AppData/Local/Programs/Odin/odin.exe"
fi

set -x
if [ "$1" = "--release" ]; then
	"$ODIN" build src -o:speed -disable-assert -no-bounds-check -out:bin/odlox.exe
else
	"$ODIN" build src -debug -vet -strict-style -out:bin/odlox.exe
fi
