#!/usr/bin/env bash
# Builds odlox into bin/odlox.exe. Run from anywhere; cds to the repo root first.
set -e
cd "$(dirname "$0")/.."

ODIN=odin
if ! command -v "$ODIN" >/dev/null 2>&1; then
	ODIN="$HOME/AppData/Local/Programs/Odin/odin.exe"
fi

set -x
"$ODIN" build src -o:speed -disable-assert -no-bounds-check -out:bin/odlox.exe
