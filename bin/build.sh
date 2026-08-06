#!/usr/bin/env bash
# Builds odlox into bin/odlox.exe. Run from anywhere; cds to the repo root first.
#
# Usage: bin/build.sh [--release]
#   (no args)   Debug build: -debug -vet -strict-style. Enables Odin's
#               ODIN_DEBUG constant, so `--debug`/`--instrument`/
#               `--trace-gc`'s Trace_Hook/Instrument_Hook/Gc_Hook are
#               actually compiled in (see src/debug/trace.odin) instead
#               of warning and producing empty output (see main.odin's
#               warnIfNoDebugHook-equivalent). -vet/-strict-style surface
#               real Odin lints as build warnings (not build-breaking --
#               this is a dev build, not the examples/ repo's CI-grade
#               -warnings-as-errors regime; see that project's own
#               CLAUDE.md if you're looking for that stricter flag set).
#   --release   Release/benchmark build: -o:speed -disable-assert
#               -no-bounds-check. No ODIN_DEBUG -- `--debug`/
#               `--instrument`/`--trace-gc` warn and produce empty/zero
#               output on this build. This is the exact flag set every
#               Phase 7 benchmark baseline in ROADMAP.md was measured
#               against (see bin/benchmarks.sh) -- don't change it
#               without re-measuring.
#
# Mirrors the reference implementation's own fast-vs-debug build split
# (bin/build.sh vs. bin/build_debug.sh / core.HotLoopDebugHookCompiled) --
# see ROADMAP.md's Phase 0 entry for this decision. Simpler here than the
# reference implementation's own version: Odin's `when ODIN_DEBUG` is real
# conditional compilation, so there's no temporary source-edit-then-restore
# dance needed to toggle
# the hot-loop debug hook in and out of the binary -- just a different
# set of odin build flags.
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
