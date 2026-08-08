#!/usr/bin/env bash
# Runs odlox's Odin unit tests: core/compiler/debug as one batched `odin
# test <pkg>` each, but vm one test at a time, each its own process.
# (`natives` has no @(test) procs of its own -- see
# src/natives/README.md's Testing section: pytest against the built
# binary is the real gate for native dispatch, not `odin test`.)
#
# Why vm is special: TODO.md's Phase 0 entry and ROADMAP.md's Phase 4
# writeup document a real, unresolved `odin test` toolchain bug --
# enough full VM instances constructed across enough tests *in one test
# binary process* eventually hangs or crashes the run, even with
# -define:ODIN_TEST_THREADS=1. It's not particular tests at fault (that
# was checked directly: disabling the one test logged right before a
# hang did not fix it) -- it's cumulative allocation weight across
# however many vm-package tests happen to run in the same process this
# time. Splitting core/compiler/debug into batches was enough to dodge
# it there; vm's own tests construct enough VMs per test that even a
# same-package batch isn't safe, so every vm test gets its own fresh
# process via -define:ODIN_TEST_NAMES=vm.<name>. This costs wall-clock
# time (~1s/test of odin compile+link+run overhead, ~80 tests) but loses
# no coverage and fully sidesteps the accumulation, rather than curating
# an ever-changing "risky test" exclusion list by hand.
#
# Usage: bin/test_odin.sh [timeout_seconds]
#   Default 60s for the core/compiler/debug batches, 15s per individual
#   vm test (isolated runs take well under 1s normally; a real hang on
#   one in isolation would be its own separate bug worth seeing, not
#   something to wait 60s to notice 80 times over).
set -u
cd "$(dirname "$0")/.."

ODIN=odin
if ! command -v "$ODIN" >/dev/null 2>&1; then
	ODIN="$HOME/AppData/Local/Programs/Odin/odin.exe"
fi

BATCH_TIMEOUT="${1:-60}"
VM_TEST_TIMEOUT=15

overall_status=0

for pkg in src/core src/compiler src/debug; do
	echo "=== $pkg ==="
	timeout "${BATCH_TIMEOUT}s" "$ODIN" test "$pkg" -define:ODIN_TEST_THREADS=1
	code=$?
	if [ "$code" -eq 0 ]; then
		echo "--- $pkg: OK ---"
	elif [ "$code" -eq 124 ]; then
		echo "--- $pkg: TIMED OUT after ${BATCH_TIMEOUT}s ---"
		overall_status=1
	else
		echo "--- $pkg: FAILED (exit $code) ---"
		overall_status=1
	fi
	echo
done

echo "=== src/vm (one test per process) ==="
# Extract every `proc_name :: proc(t: ^testing.T) {` declaration
# immediately following an `@(test)` line, across every *_test.odin file
# in src/vm -- not a hardcoded list, so a newly added/renamed test is
# picked up automatically instead of silently skipped.
vm_tests=$(grep -h -A1 '^@(test)' src/vm/*_test.odin | grep -v '^@(test)' | grep -v '^--$' | sed -E 's/[[:space:]]*::.*$//')
vm_total=0
vm_ok=0
vm_failed=()
vm_timed_out=()

for name in $vm_tests; do
	vm_total=$((vm_total + 1))
	output=$(timeout "${VM_TEST_TIMEOUT}s" "$ODIN" test src/vm -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES="vm.$name" 2>&1)
	code=$?
	if [ "$code" -eq 0 ]; then
		vm_ok=$((vm_ok + 1))
	elif [ "$code" -eq 124 ]; then
		vm_timed_out+=("$name")
		echo "--- vm.$name: TIMED OUT after ${VM_TEST_TIMEOUT}s ---"
		overall_status=1
	else
		vm_failed+=("$name")
		echo "--- vm.$name: FAILED (exit $code) ---"
		echo "$output"
		overall_status=1
	fi
done

echo "--- src/vm: $vm_ok/$vm_total OK"
if [ "${#vm_failed[@]}" -gt 0 ]; then
	echo "    failed: ${vm_failed[*]}"
fi
if [ "${#vm_timed_out[@]}" -gt 0 ]; then
	echo "    timed out: ${vm_timed_out[*]}"
fi
echo

exit $overall_status
