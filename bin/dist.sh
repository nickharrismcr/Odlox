#!/usr/bin/env bash
# Bundles a standalone Windows folder for handing a .lox script (or a
# self-contained script folder) to someone with no Odin toolchain and no
# checkout of this repo. Run from anywhere; cds to the repo root first.
#
# Usage:
#   bin/dist.sh <name> <script.lox> [<script2.lox> ...]
#       Flat mode: bundles the given script file(s) only (no sibling files).
#       Correct for the common case -- most of lox_examples/*.lox are single
#       files with no local imports or asset paths (confirmed by grep: only
#       gfx/box2d natives, nothing under lox_examples/assets or shaders/).
#
#   bin/dist.sh <name> --dir <root-dir> <entry.lox>
#       Folder mode: bundles a self-contained example folder that has its own
#       local imports and/or asset paths resolved relative to its own
#       directory -- e.g. lox_examples/defender (main.lox + game/ + npc/ +
#       player/ + world/ + pngs/ + assets/). entry.lox is given relative to
#       root-dir.
#
#       Local modules living in subdirectories (game/npc/player/world) get
#       *flattened* into the bundle root rather than kept in their original
#       layout: read_module_source (module.odin:268-340) only supports
#       cache-only resolution for two tiers -- $LOX_PATH/modules/<name>.lox
#       and a <name>.lox sitting directly beside the entry script -- not for
#       find_module_in_subdirs' recursive walk, which requires the literal
#       .lox on disk unconditionally (module.odin:283-289's own comment: a
#       deliberate, documented scope cut, not an oversight). Flattening
#       every local module into the entry script's own directory moves them
#       all onto the tier that *does* support cache-only, since
#       read_module_source resolves relative to vm.root_script -- the
#       top-level entry script -- regardless of which module is doing the
#       importing (see that same comment block). Duplicate basenames across
#       the tree would make flattening ambiguous, so that's a hard error.
#       Asset paths (image()/sound() natives resolve relative to the
#       process's working directory, which run.bat sets to the bundle root)
#       are copied preserving their original relative layout, unaffected by
#       the module flattening.
#
#       This bundles the entry script itself as real source unconditionally
#       -- main.odin's run_file reads it directly by path, never through
#       read_module_source, so there's no cache-only path for it at all
#       (main.odin's own comment: the entry script "never consults the cache
#       at all").
#
# Either mode writes dist/<name>/ and dist/<name>.zip. The bundle ships
# modules/ as compiled __loxcache__/*.lxc only (no .lox source) and its
# run.bat launches odlox.exe --force-bc-cache, matching module.odin's
# documented use case for that flag: "distributing a library as compiled
# bytecode only" (see docs/plans/done/bytecode-cache.md). --force-bc-cache is
# required here, not optional -- without it, module resolution only accepts
# a literal <name>.lox next to the script, and this bundle never ships one.
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
