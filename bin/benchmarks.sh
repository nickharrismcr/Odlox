#!/usr/bin/env bash
# Runs the loxcraft benchmark suite against odlox, the reference glox
# implementation, and CPython, and prints a comparison table.
#
# Usage: bin/benchmarks.sh [RUNS]
#   RUNS defaults to 3. GLOX_EXE overrides the glox binary location
#   (default: d:/go/glox/bin/glox.exe); glox column skips if not found.
set -e
cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
export LOX_PATH="$REPO_ROOT"

BENCH_DIR="$REPO_ROOT/benchmarks"
RUNS=${1:-3}
GLOX_EXE=${GLOX_EXE:-/d/go/glox/bin/glox.exe}

extract_avg() {
	grep "Average:" | sed 's/Average: \([0-9.]*\) seconds/\1/'
}

have_glox=0
if [ -x "$GLOX_EXE" ]; then
	have_glox=1
fi

printf "\n%-16s %10s %10s %10s %10s %10s\n" "benchmark" "odlox" "glox" "python" "odlox/glox" "odlox/py"
printf "%-16s %10s %10s %10s %10s %10s\n" "----------------" "----------" "----------" "----------" "----------" "----------"

for lox_src in "$BENCH_DIR"/lox/*.lox; do
	name=$(basename "$lox_src" .lox)
	py_src="$BENCH_DIR/python/${name}.py"

	odlox_avg=$(python "$REPO_ROOT/bin/time_lox.py" "$lox_src" --exe "$REPO_ROOT/bin/odlox.exe" --runs "$RUNS" 2>&1 | extract_avg)

	glox_avg=""
	if [ "$have_glox" -eq 1 ]; then
		glox_dir="$(cd "$(dirname "$GLOX_EXE")/.." && pwd)"
		glox_avg=$( (cd "$glox_dir" && export LOX_PATH="$glox_dir" && python "$REPO_ROOT/bin/time_lox.py" "$lox_src" --exe "$GLOX_EXE" --runs "$RUNS") 2>&1 | extract_avg)
	fi

	py_avg=$(python "$REPO_ROOT/bin/time_lox.py" --python "$py_src" --runs "$RUNS" 2>&1 | extract_avg)

	vs_glox="n/a"
	if [ -n "$odlox_avg" ] && [ -n "$glox_avg" ]; then
		vs_glox=$(python -c "print(f'{float(\"$odlox_avg\")/float(\"$glox_avg\"):.2f}x')")
	fi
	vs_py="err"
	if [ -n "$odlox_avg" ] && [ -n "$py_avg" ]; then
		vs_py=$(python -c "print(f'{float(\"$odlox_avg\")/float(\"$py_avg\"):.2f}x')")
	fi

	printf "%-16s %9ss %9ss %9ss %10s %10s\n" "$name" "${odlox_avg:-err}" "${glox_avg:-n/a}" "${py_avg:-err}" "$vs_glox" "$vs_py"
done

echo
echo "odlox/glox < 1.00x means odlox is faster; odlox/py is odlox's time as a multiple of CPython's."
if [ "$have_glox" -eq 0 ]; then
	echo "(glox column skipped: \$GLOX_EXE not found at $GLOX_EXE)"
fi
