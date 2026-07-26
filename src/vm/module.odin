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
// KNOWN GAP vs. glox: built-in modules (sys/gfx/os/...) resolve through
// vm.builtin_modules, but nothing registers any yet -- that's Phase 6's
// job (native/builtin functions). Importing another *.lox file works
// now; importing a not-yet-implemented built-in module reports "not
// found" rather than working, until Phase 6 lands.

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

// read_module_source tries, in order: alongside the running script,
// then LOX_PATH's module directory -- a reduced version of glox's
// search (which also recurses into subdirectories; not ported yet,
// since no built-in module registrations exist to need it this phase).
@(private = "file")
read_module_source :: proc(vm: ^VM, name: string) -> (data: []byte, path: string, found: bool) {
	filename := strings.concatenate({name, ".lox"})
	defer delete(filename)

	dir := filepath.dir(vm.script)
	defer delete(dir)
	candidate, _ := filepath.join({dir, filename})
	if d, err := os.read_entire_file_from_path(candidate, context.allocator); err == nil {
		return d, candidate, true
	}
	delete(candidate)

	if lox_path, ok := os.lookup_env_alloc("LOX_PATH", context.allocator); ok {
		defer delete(lox_path)
		candidate2, _ := filepath.join({lox_path, filename})
		if d, err := os.read_entire_file_from_path(candidate2, context.allocator); err == nil {
			return d, candidate2, true
		}
		delete(candidate2)
	}

	return nil, "", false
}
