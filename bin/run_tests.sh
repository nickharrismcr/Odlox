#!/usr/bin/env bash
# Runs the ported pytest suite against bin/odlox.exe. Run from anywhere;
# cds to the repo root first. Extra args are forwarded to pytest, e.g.
# bin/run_tests.sh -k try_except -v
set -e
cd "$(dirname "$0")/.."

export LOX_PATH="$(pwd)"
python -m pytest tests/new_tests/ "$@"
