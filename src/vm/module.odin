#+feature global-context
package vm

import "../compiler"
import "../core"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Module import execution. With threads out of scope entirely, module_cache
// is a plain process-wide map, no lock needed. Built-in modules (sys/os,
// registered in builtins.odin; gfx/re/pickle/process/colour_utils/
// inspect/physics, registered from the natives package) resolve through
// vm.builtin_modules. A *.lox source module resolves through
// read_module_source below.

// module_cache holds every imported module, keyed by its bare import
// name, shared by every VM in the process rather than kept per-VM: a
// module reached via two different import paths (e.g. two files that
// both `import particle_sys`) resolves to the *same* Class_Objects and
// the *same* module-level state (a `var` free list, a `static` class
// field, ...), not two independent copies.
@(private)
module_cache: map[string]^core.Module_Object

// module_source_cache holds every imported module's own source text,
// keyed by its bare import name -- process-wide for the same reason as
// module_cache: a module's functions run as ordinary closures long after
// the sub-VM that compiled them is gone, but the stack trace still needs
// that source text to print a context line.
@(private)
module_source_cache: map[string]string

// module_source_allocator is captured once, at package init -- same
// rationale as core.obj_string.odin's intern_allocator: module_source_cache
// must outlive any single test task or VM run, so it can't allocate
// through whichever ambient context.allocator happens to be active on
// the call that first populates it (under `odin test`, a short-lived,
// recycled per-task scratch allocator).
@(private = "file")
module_source_allocator: mem.Allocator

// modules_loading tracks module names currently in the middle of their own
// load_module call, process-wide like module_cache (same "no threads,
// plain map, no lock" reasoning) -- a genuine circular import (A's own
// top-level code does `import B`, B's does `import A`) would otherwise
// recurse load_module -> compile_and_run_module -> do_import -> load_module
// unboundedly: module_cache is only populated *after* a module's load
// fully completes (see load_module below), so nothing else would ever
// see the cycle. Cleared via defer the moment this module's own
// load_module call returns, successfully or not, so it only ever reflects
// modules genuinely mid-load right now, not everything ever loaded.
@(private)
modules_loading: map[string]bool

@(init)
init_module_source_cache :: proc() {
	module_source_allocator = context.allocator
	module_source_cache = make(map[string]string, allocator = module_source_allocator)
}

do_import :: proc(vm: ^VM, module_name: string, alias: string) {
	mod, ok := load_module(vm, module_name)
	if !ok {
		return // runtime_error already set inside load_module
	}
	bind_imported_name(vm, alias, core.make_object_value(&mod.obj))
}

do_import_from :: proc(vm: ^VM, module_name: string, names: []string) {
	mod, ok := load_module(vm, module_name)
	if !ok {
		return
	}
	if len(names) == 0 {
		// `from mod import *` -- every name in the module's environment, not
		// just its "real" top-level declarations, since Environment.vars also
		// holds whatever free builtins the module's own code referenced
		// (seed_builtin_globals writes those into both globals and vars).
		// bind_imported_name_soft (not bind_imported_name) tolerates names
		// that aren't real exports, just incidental references.
		for k, v in mod.environment.vars {
			bind_imported_name_soft(vm, core.string_get(k), v)
		}
		return
	}
	for name in names {
		v, found := core.env_get_var(mod.environment, core.intern_string(name))
		if !found {
			runtime_error(vm, "Module '%s' has no export '%s'.", module_name, name)
			return
		}
		bind_imported_name(vm, name, v)
	}
}

@(private = "file")
bind_imported_name :: proc(vm: ^VM, name: string, val: core.Value) {
	slot := core.env_slot_for_name(vm.environment, name)
	if slot < 0 {
		runtime_error(vm, "Internal error: import name '%s' has no global slot.", name)
		return
	}
	core.env_grow_globals(vm.environment, slot + 1)
	core.env_set_global(vm.environment, slot, val)
	write_barrier_value(vm, val)
}

// bind_imported_name_soft is `from mod import *`'s binding step --
// deliberately more forgiving than bind_imported_name, which treats a
// missing global slot as an internal-error bug. A named import is
// guaranteed a slot at compile time, but `import *` walks names the
// importing script's compiled code never mentioned at all, so a missing
// slot is silently skipped here rather than treated as an error.
@(private = "file")
bind_imported_name_soft :: proc(vm: ^VM, name: string, val: core.Value) {
	core.env_set_var(vm.environment, core.intern_string(name), val)
	write_barrier_value(vm, val)
	slot := core.env_slot_for_name(vm.environment, name)
	if slot < 0 {
		return
	}
	core.env_grow_globals(vm.environment, slot + 1)
	core.env_set_global(vm.environment, slot, val)
	write_barrier_value(vm, val)
}

@(private = "file")
load_module :: proc(vm: ^VM, name: string) -> (^core.Module_Object, bool) {
	if cached, ok := module_cache[name]; ok {
		return cached, true
	}
	if builtin, ok := vm.builtin_modules[core.intern_string(name)]; ok {
		module_cache[name] = builtin
		return builtin, true
	}

	if modules_loading[name] {
		runtime_error(vm, "Circular import detected for module '%s'.", name)
		return nil, false
	}
	modules_loading[name] = true
	defer delete_key(&modules_loading, name)

	data, path, found := read_module_source(vm, name)
	if !found {
		runtime_error(vm, "Module '%s' not found.", name)
		return nil, false
	}
	defer delete(data)
	// data is nil for a --force-bc-cache-only resolution (a .lxc with no
	// matching .lox at all -- see read_module_source) -- there's no
	// source text to cache for stack traces in that case, and
	// frame_source's own map lookup already degrades to an empty context
	// line when module_source_cache has no entry for a name, so this is
	// simply skipped rather than storing "".
	if data != nil {
		module_source_cache[name] = strings.clone(string(data), module_source_allocator)
	}

	sub := new_vm_raw(path)
	sub.root_script = vm.root_script
	// Share (not copy) the parent's builtin registrations -- an
	// imported module's own top-level code should be able to call
	// `type()`/`len()`/... and `import sys` itself, same as the
	// script that imported it. Safe to alias these two maps directly:
	// both are populated once by define_builtins and never mutated
	// afterward (see builtins.odin), so there's no shared-mutable-state
	// hazard despite every sub-VM pointing at the same underlying map.
	sub.builtins = vm.builtins
	sub.builtin_modules = vm.builtin_modules
	sub.force_compile = vm.force_compile
	sub.force_bc_cache = vm.force_bc_cache
	sub.module_resolver = vm.module_resolver
	status := compile_and_run_module(sub, path, string(data), data == nil)
	if status != .Ok {
		// Propagate the sub-VM's own, more specific message (a nested
		// compile error, or -- see modules_loading above -- a circular
		// import detected further down the chain) rather than always
		// discarding it for a generic wrapper: without this, every
		// failure reason collapses to the same uninformative text no
		// matter how deep in the import graph it actually happened.
		if sub.error_msg != "" {
			runtime_error(vm, "Failed to import module '%s': %s", name, sub.error_msg)
		} else {
			runtime_error(vm, "Failed to import module '%s'.", name)
		}
		return nil, false
	}

	// sub is a throwaway VM running only this module's top-level code.
	// Every object that code allocated was gc_track()ed onto sub's own
	// vm.objects, not the parent's -- if sub were simply discarded, those
	// objects would stay reachable via mod.environment but never get swept
	// (sweep() only walks vm.objects). Splicing sub's object list into the
	// parent's makes the parent's sweep the sole owner instead.
	if sub.objects != nil {
		// sub's own GC state is discarded with sub itself. Its last cycle
		// could still have been mid-Marking, leaving some objects marked=true
		// without having been blackened -- left alone, the parent's
		// mark_object would skip re-tracing them (already-marked fast path),
		// so their children would never get marked. Resetting every spliced
		// object to unmarked makes the parent's own reachability analysis
		// the sole authority, as if freshly allocated.
		for o := sub.objects; o != nil; o = o.next {
			o.marked = false
		}
		tail := sub.objects
		for tail.next != nil {
			tail = tail.next
		}
		tail.next = vm.objects
		vm.objects = sub.objects
	}
	vm.bytes_allocated += sub.bytes_allocated

	// Publish the module's slot-indexed globals into its own name-keyed
	// Vars map too, so `from mod import x` (name-based lookup) works.
	for gname, slot in sub.environment.global_names {
		if slot < len(sub.environment.defined) && sub.environment.defined[slot] {
			core.env_set_var(sub.environment, core.intern_string(gname), sub.environment.globals[slot])
		}
	}

	mod := core.make_module_object(name, sub.environment)
	gc_track(vm, &mod.obj)
	module_cache[name] = mod
	return mod, true
}

// compile_and_run_module is load_module's compile-or-cache-hit step --
// not routed through interpret (which always compiles unconditionally),
// since an imported module is the only place a bytecode-cache hit can skip
// compilation entirely. cache_only is true for a --force-bc-cache
// resolution with no .lox at all: if bc_cache_load then misses too,
// that's reported directly rather than compiling "" as an empty program.
@(private = "file")
compile_and_run_module :: proc(sub: ^VM, path: string, source: string, cache_only: bool) -> Interpret_Result {
	reset_stack(sub)
	delete(sub.stack_trace)
	sub.stack_trace = nil
	sub.error_msg = ""
	sub.pending_exception_class = ""
	sub.source = source

	if fn, hit := bc_cache_load(sub, path, sub.environment); hit {
		status, _ := run_compiled(sub, fn)
		return status
	}

	if cache_only {
		fmt.eprintfln("odlox: %s has no source and no usable bytecode cache", path)
		return .Compile_Error
	}

	resolve_module, resolve_module_ctx := module_resolve_proc(sub)
	fn, ok := compiler.Compile(source, sub.script, sub.environment, resolve_module, resolve_module_ctx)
	if !ok {
		return .Compile_Error
	}
	status, _ := run_compiled(sub, fn)
	if status == .Ok {
		bc_cache_write(path, fn)
	}
	return status
}

// read_module_source tries, in order: `$LOX_PATH/modules/<name>.lox`, then
// alongside the top-level entry script (vm.root_script, not vm.script),
// then a recursive search of the entry script's directory tree. When
// vm.force_bc_cache is set, the first two (non-recursive) locations also
// accept a cache-only match -- a `__loxcache__/<name>.lxc` with no
// matching `.lox` (see cache_only_module_path); data is nil in that case.
// The recursive search isn't extended to cache-only matches. Each tier is
// its own proc (find_module_lox_path_tier/find_module_alongside_root_tier/
// find_module_recursive_tier, just below) so module_typecheck.odin's
// Module_Resolver can reuse the exact same search order (with
// force_bc_cache always false -- a signature lookup needs real source to
// typecheck, never a cache-only match) without duplicating it and
// risking the two searches drifting apart.
@(private = "file")
read_module_source :: proc(vm: ^VM, name: string) -> (data: []byte, path: string, found: bool) {
	filename := strings.concatenate({name, ".lox"})
	defer delete(filename)

	if d, p, ok := find_module_lox_path_tier(filename, vm.force_bc_cache); ok {
		return d, p, true
	}
	if d, p, ok := find_module_alongside_root_tier(vm.root_script, filename, vm.force_bc_cache); ok {
		return d, p, true
	}
	if d, p, ok := find_module_recursive_tier(vm.root_script, filename); ok {
		return d, p, true
	}
	return nil, "", false
}

find_module_lox_path_tier :: proc(filename: string, force_bc_cache: bool) -> (data: []byte, path: string, found: bool) {
	lox_path, ok := os.lookup_env_alloc("LOX_PATH", context.allocator)
	if !ok {
		return nil, "", false
	}
	defer delete(lox_path)
	modules_dir, _ := filepath.join({lox_path, "modules"})
	defer delete(modules_dir)
	candidate, _ := filepath.join({modules_dir, filename})
	if d, err := os.read_entire_file_from_path(candidate, context.allocator); err == nil {
		return d, candidate, true
	}
	if force_bc_cache {
		if p, cache_ok := cache_only_module_path(candidate); cache_ok {
			delete(candidate)
			return nil, p, true
		}
	}
	delete(candidate)
	return nil, "", false
}

find_module_alongside_root_tier :: proc(root_script: string, filename: string, force_bc_cache: bool) -> (data: []byte, path: string, found: bool) {
	// filepath.dir (os.dir) returns a slice *into* root_script, not a
	// fresh allocation (see os/path.odin's split_path) -- deleting it
	// would be a bad free of memory this proc doesn't own.
	dir := filepath.dir(root_script)
	if dir == "" {
		dir = "."
	}

	candidate, _ := filepath.join({dir, filename})
	if d, err := os.read_entire_file_from_path(candidate, context.allocator); err == nil {
		return d, candidate, true
	}
	if force_bc_cache {
		if p, ok := cache_only_module_path(candidate); ok {
			delete(candidate)
			return nil, p, true
		}
	}
	delete(candidate)
	return nil, "", false
}

find_module_recursive_tier :: proc(root_script: string, filename: string) -> (data: []byte, path: string, found: bool) {
	dir := filepath.dir(root_script)
	if dir == "" {
		dir = "."
	}
	if found_path, ok := find_module_in_subdirs(dir, filename); ok {
		defer delete(found_path)
		if d, err := os.read_entire_file_from_path(found_path, context.allocator); err == nil {
			return d, strings.clone(found_path), true
		}
	}
	return nil, "", false
}

// cache_only_module_path checks whether would_be_source_path -- a .lox
// path that just failed to open above -- has a matching
// __loxcache__/<name>.lxc sitting next to it anyway. Returns
// would_be_source_path itself, cloned: bc_cache_path/bc_cache_load both
// derive the .lxc location from this string alone, never by statting the
// .lox path itself, so a path with nothing at it on disk is a perfectly
// valid key.
@(private = "file")
cache_only_module_path :: proc(would_be_source_path: string) -> (path: string, ok: bool) {
	cache_path := bc_cache_path(would_be_source_path)
	defer delete(cache_path)
	if _, err := os.modification_time_by_path(cache_path); err != nil {
		return "", false
	}
	return strings.clone(would_be_source_path), true
}

// find_module_in_subdirs recursively searches root for a file named
// target, skipping directories that are never going to contain a
// script's own Lox modules -- VCS/build/cache dirs, including
// `__loxcache__`, the bytecode-cache directory (see
// docs/ARCHITECTURE.md's Bytecode cache section and bc_cache.odin).
@(private = "file")
find_module_in_subdirs :: proc(root: string, target: string) -> (string, bool) {
	w := os.walker_create(root)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		base := filepath.base(info.fullpath)
		if info.type == .Directory {
			switch base {
			case ".git", "__pycache__", ".pytest_cache", "bin", "__loxcache__":
				os.walker_skip_dir(&w)
			}
			continue
		}
		if base == target {
			return strings.clone(info.fullpath), true
		}
	}
	return "", false
}
