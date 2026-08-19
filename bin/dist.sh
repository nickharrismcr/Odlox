#!/usr/bin/env bash
# Bundles a standalone Windows folder for handing a .lox script (or a
# self-contained script folder) to someone with no Odin toolchain and no
# checkout of this repo. Run from anywhere; cds to the repo root first.
#
# Usage:
#   bin/dist.sh <name> <script.lox> [<script2.lox> ...]
#       Flat mode: bundles the given script file(s) only, no sibling files.
#   bin/dist.sh <name> --dir <root-dir> <entry.lox>
#       Folder mode: bundles a self-contained example folder (local
#       imports/assets resolved relative to root-dir). entry.lox is given
#       relative to root-dir. Local modules are flattened into the bundle
#       root and shipped as compiled __loxcache__/*.lxc only, since
#       cache-only module resolution only checks $LOX_PATH/modules and
#       beside the entry script, not subdirectories. Duplicate basenames
#       across the tree are a hard error. Assets keep their original
#       relative layout; the entry script is always bundled as source.
#
# Writes dist/<name>/ and dist/<name>.zip. run.bat launches odlox.exe
# --force-bc-cache, required because the bundle never ships a literal
# .lox for any flattened module.
set -e
cd "$(dirname "$0")/.."
repo_root="$(pwd)"
repo_root_win="$(pwd -W)"

if [ $# -lt 2 ]; then
	echo "usage: bin/dist.sh <name> <script.lox> [<script2.lox> ...]" >&2
	echo "       bin/dist.sh <name> --dir <root-dir> <entry.lox>" >&2
	exit 1
fi

name="$1"
shift

out="dist/$name"
rm -rf "$out"
mkdir -p "$out"

bin/build.sh --release

if [ "$1" = "--dir" ]; then
	root_dir="$2"
	entry="$3"
	if [ -z "$root_dir" ] || [ -z "$entry" ]; then
		echo "bin/dist.sh: --dir requires <root-dir> <entry.lox>" >&2
		exit 1
	fi
	if [ ! -f "$root_dir/$entry" ]; then
		echo "bin/dist.sh: $root_dir/$entry not found" >&2
		exit 1
	fi

	local_lox_files="$(find "$root_dir" -name '*.lox')"
	dupes="$(basename -a $local_lox_files | sort | uniq -d)"
	if [ -n "$dupes" ]; then
		echo "bin/dist.sh: duplicate module filename(s) under $root_dir -- can't flatten for cache-only resolution:" >&2
		echo "$dupes" >&2
		exit 1
	fi

	# Staged as a full working replica first (flattened local modules +
	# assets in their original relative layout + the entry script) so the
	# priming run below -- which actually executes $entry -- can resolve
	# every image()/sound() asset path exactly as the final bundle will.
	stage="dist/.stage-$name"
	rm -rf "$stage"
	mkdir -p "$stage"
	for f in $local_lox_files; do
		cp "$f" "$stage/"
	done
	(cd "$root_dir" && find . -type f -not -name '*.lox' -not -path '*/__loxcache__/*') | while IFS= read -r f; do
		mkdir -p "$stage/$(dirname "$f")"
		cp "$root_dir/$f" "$stage/$f"
	done

	echo "priming local bytecode cache for $entry (launches briefly, killed after 10s -- expected for graphical examples)..."
	prime_log="$stage/.prime.log"
	set +e
	(cd "$stage" && LOX_PATH="$repo_root_win" timeout -s KILL 10 "$repo_root/bin/odlox.exe" "$entry" >".prime.log" 2>&1)
	prime_rc=$?
	set -e
	if [ "$prime_rc" != 0 ] && [ "$prime_rc" != 124 ] && [ "$prime_rc" != 137 ]; then
		echo "bin/dist.sh: priming run failed (exit $prime_rc):" >&2
		cat "$prime_log" >&2
		rm -rf "$stage"
		exit 1
	fi
	if [ ! -d "$stage/__loxcache__" ]; then
		echo "bin/dist.sh: priming run produced no __loxcache__ -- did $entry import anything?" >&2
		cat "$prime_log" >&2
		rm -rf "$stage"
		exit 1
	fi

	# Finalize: drop every flattened .lox module (now captured as .lxc in
	# stage/__loxcache__) except the entry script itself, which odlox
	# always reads as literal source -- then copy the rest of the staged
	# replica (assets + __loxcache__ + entry script) into the bundle.
	rm -f "$prime_log"
	for f in $local_lox_files; do
		base="$(basename "$f")"
		if [ "$base" != "$entry" ]; then
			rm -f "$stage/$base"
		fi
	done
	cp -r "$stage/." "$out/"
	rm -rf "$stage"

	entry_script="$entry"
else
	for script in "$@"; do
		if [ ! -f "$script" ]; then
			echo "bin/dist.sh: $script not found" >&2
			exit 1
		fi
		cp "$script" "$out/"
	done
	entry_script="$(basename "$1")"
fi

cp bin/odlox.exe "$out/"

mkdir -p "$out/modules/__loxcache__"
stale=0
for f in modules/*.lox; do
	base="$(basename "$f" .lox)"
	cache="modules/__loxcache__/$base.lxc"
	if [ ! -f "$cache" ] || [ "$f" -nt "$cache" ]; then
		echo "warning: $cache missing or stale for $f -- run bin/showcase.sh or bin/run_tests.sh once to refresh, then re-run dist.sh" >&2
		stale=1
	fi
done
cp modules/__loxcache__/*.lxc "$out/modules/__loxcache__/" 2>/dev/null || true

cat > "$out/run.bat" <<BATCH
@echo off
setlocal
cd /d %~dp0
set LOX_PATH=%~dp0
if "%~1"=="" (
	"%~dp0odlox.exe" --force-bc-cache $entry_script
) else (
	"%~dp0odlox.exe" --force-bc-cache %*
)
BATCH

(cd dist && powershell -NoProfile -Command "Compress-Archive -Path '$name' -DestinationPath '$name.zip' -Force")

echo "bundle ready: $out/ and dist/$name.zip"
if [ "$stale" = "1" ]; then
	echo "note: some stdlib module caches were stale/missing -- see warnings above" >&2
fi
