package vm

import "../core"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Module import execution. A process-wide module cache would need a
// mutex in glox (shared across thread-module workers); with threads
// out of scope entirely (see docs/ARCHITECTURE.md's Scope section),
// vm.module_cache is just a plain per-VM map, no lock.
//
// Built-in modules (sys/os so far -- see builtins.odin/builtins_sys.odin/
// builtins_os.odin) resolve through vm.builtin_modules; gfx/re/pickle/
// process/colour_utils/inspect aren't registered yet (Phase 6b). A *.lox
// source module resolves through read_module_source below.

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
		// `from mod import *`
		for k, v in mod.environment.vars {
			bind_imported_name(vm, core.string_get(k), v)
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
}

@(private = "file")
load_module :: proc(vm: ^VM, name: string) -> (^core.Module_Object, bool) {
	if cached, ok := vm.module_cache[name]; ok {
		return cached, true
	}
	if builtin, ok := vm.builtin_modules[core.intern_string(name)]; ok {
		vm.module_cache[name] = builtin
		return builtin, true
	}

	data, path, found := read_module_source(vm, name)
	if !found {
		runtime_error(vm, "Module '%s' not found.", name)
		return nil, false
	}
	defer delete(data)

	sub := new_vm_raw(path)
	// Share (not copy) the parent's builtin registrations -- an
	// imported module's own top-level code should be able to call
	// `type()`/`len()`/... and `import sys` itself, same as the
	// script that imported it. Safe to alias these two maps directly:
	// both are populated once by define_builtins and never mutated
	// afterward (see builtins.odin), so there's no shared-mutable-state
	// hazard despite every sub-VM pointing at the same underlying map.
	sub.builtins = vm.builtins
	sub.builtin_modules = vm.builtin_modules
	status, _ := interpret(sub, string(data))
	if status != .Ok {
		runtime_error(vm, "Failed to import module '%s'.", name)
		return nil, false
	}

	// Publish the module's slot-indexed globals into its own name-keyed
	// Vars map too, so `from mod import x` (name-based lookup) works --
	// mirrors glox's post-import sync step.
	for gname, slot in sub.environment.global_names {
		if slot < len(sub.environment.defined) && sub.environment.defined[slot] {
			core.env_set_var(sub.environment, core.intern_string(gname), sub.environment.globals[slot])
		}
	}

	mod := core.make_module_object(name, sub.environment)
	gc_track(vm, &mod.obj)
	vm.module_cache[name] = mod
	return mod, true
}

// read_module_source tries, in order: `$LOX_PATH/modules/<name>.lox`,
// then alongside the running script, then a recursive search of the
// script's own directory tree -- matching glox's own three-tier search
// (`getPath`/`findModuleInSubdirs` in glox's vm.go) so scripts can
// group their own modules into subfolders, with one deliberate path
// difference: glox looks under `$LOX_PATH/src/modules`, its own repo's
// Lox-source-stdlib location; odlox's `src/` is exclusively Odin
// source, so the equivalent convention here is a `modules/` directory
// at the LOX_PATH root instead (see `ROADMAP.md`'s Phase 6 section --
// this is that fix). An earlier version of this proc checked the
// script's own directory first and never searched subdirectories at
// all, silently diverging from glox's search order; fixed here rather
// than left for `import math` (or any other stdlib module) to keep
// failing "not found" once those get copied over.
@(private = "file")
read_module_source :: proc(vm: ^VM, name: string) -> (data: []byte, path: string, found: bool) {
	filename := strings.concatenate({name, ".lox"})
	defer delete(filename)

	if lox_path, ok := os.lookup_env_alloc("LOX_PATH", context.allocator); ok {
		defer delete(lox_path)
		modules_dir, _ := filepath.join({lox_path, "modules"})
		defer delete(modules_dir)
		candidate, _ := filepath.join({modules_dir, filename})
		if d, err := os.read_entire_file_from_path(candidate, context.allocator); err == nil {
			return d, candidate, true
		}
		delete(candidate)
	}

	// filepath.dir (os.dir) returns a slice *into* vm.script, not a
	// fresh allocation (see os/path.odin's split_path) -- deleting it
	// is a bad free of memory this proc doesn't own. Real bug, not
	// hypothetical: it silently corrupted the heap on every successful
	// module import since Phase 4 first wrote this line, without
	// crashing immediately (bad frees don't always crash where they
	// happen) -- surfaced reliably once find_module_in_subdirs' extra
	// allocations changed the heap layout enough to turn latent
	// corruption into an actual segfault on the very first test of
	// this phase's subdirectory-search addition.
	dir := filepath.dir(vm.script)
	if dir == "" {
		dir = "."
	}

	candidate2, _ := filepath.join({dir, filename})
	if d, err := os.read_entire_file_from_path(candidate2, context.allocator); err == nil {
		return d, candidate2, true
	}
	delete(candidate2)

	if found_path, ok := find_module_in_subdirs(dir, filename); ok {
		defer delete(found_path)
		if d, err := os.read_entire_file_from_path(found_path, context.allocator); err == nil {
			return d, strings.clone(found_path), true
		}
	}

	return nil, "", false
}

// find_module_in_subdirs recursively searches root for a file named
// target, skipping directories that are never going to contain a
// script's own Lox modules (VCS/build/cache dirs -- glox's own
// equivalent skips just `__loxcache__`, its bytecode-cache directory;
// this port has no bytecode cache -- see ARCHITECTURE.md's Bytecode
// cache section -- but the same principle applies to its own
// build/tooling directories).
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
