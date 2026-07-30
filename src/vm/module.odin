package vm

import "../compiler"
import "../core"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Module import execution. With threads out of scope entirely (see
// docs/ARCHITECTURE.md's Scope section), vm.module_cache is just a
// plain per-VM map, no lock needed.
//
// Built-in modules (sys/os, registered in builtins.odin; gfx/re/pickle/
// process/colour_utils/inspect/physics, registered from the natives/
// package -- see each one's own register_* proc) resolve through
// vm.builtin_modules. A *.lox source module resolves through
// read_module_source below.

// module_source_cache holds every imported module's own source text,
// keyed by its bare import name -- unlike module_cache above, this one
// genuinely is process-wide (no per-VM copy would work): a module's own
// functions run as ordinary closures in whichever VM calls them, often
// long after the sub-VM that originally compiled the module's source has
// gone out of scope, but the stack trace (exceptions.odin's
// append_stack_trace/source_line) still needs that module's source text
// to print a context line for a frame inside one of its functions. No
// mutex needed for the same reason module_cache doesn't have one.
@(private)
module_source_cache: map[string]string

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
		// `from mod import *` -- every name in the module's environment,
		// not just its "real" top-level declarations, since Environment.vars
		// also holds whatever free builtins the module's own code happened
		// to reference (seed_builtin_globals writes those into both the
		// module's globals *and* vars -- see builtins.odin). A module
		// like math.lox that calls vec2()/vec3() internally ends up with
		// "vec2"/"vec3" entries in its own vars purely as a side effect of
		// referencing them, not because it "exports" them -- bind_imported_name_soft
		// (not bind_imported_name) is what makes that harmless: see its
		// own doc comment.
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
}

// bind_imported_name_soft is `from mod import *`'s own binding step --
// deliberately more forgiving than bind_imported_name (used for a
// specific `from mod import name`), which treats a missing global slot
// as an internal-error bug. For a *named* import, the compiler already
// guaranteed a slot exists (from_import_statement's own
// `global_slot(p, name)` call, at compile time) -- so "no slot" really
// would mean something is broken. `import *` has no such guarantee: it
// walks whatever names the module's environment happens to hold, most
// of which the importing script's own compiled code never mentioned by
// identifier at all -- e.g. a name the module's own top-level code
// happened to reference internally but the importing script never did
// -- so there's no reason a global slot would exist for them, and no
// reason one needs to, either, since nothing in the importing script
// can ever try to *read* a name it never referenced. A missing slot is
// silently skipped here rather than treated as an error.
@(private = "file")
bind_imported_name_soft :: proc(vm: ^VM, name: string, val: core.Value) {
	core.env_set_var(vm.environment, core.intern_string(name), val)
	slot := core.env_slot_for_name(vm.environment, name)
	if slot < 0 {
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
	module_source_cache[name] = strings.clone(string(data))

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
	status := compile_and_run_module(sub, path, string(data))
	if status != .Ok {
		runtime_error(vm, "Failed to import module '%s'.", name)
		return nil, false
	}

	// sub is a throwaway VM that exists only to run this module's own
	// top-level code (class/func declarations, any module-level `var`
	// initializers). Every object that code allocated -- including e.g.
	// a module-level `var _pool = [];` list a script mutates long after
	// import -- was gc_track()ed onto *sub's* vm.objects, not the parent
	// vm's. If sub were simply discarded below, those objects would
	// still be reachable (via mod.environment, correctly walked by the
	// parent's mark_roots) but never actually swept by anyone: sweep()
	// only walks vm.objects, so their mark bit, once set on the first
	// cycle that reaches them, would never get cleared again -- and
	// mark_object's "already marked, don't re-queue" fast path then
	// means they never get re-traced either. A List's own object
	// surviving that way is harmless (it just never becomes
	// unreachable), but anything added to it *after* this point (e.g.
	// every particle a pool holds beyond its first GC cycle) would be
	// invisible to every future mark phase and get swept as garbage
	// while still genuinely referenced -- a use-after-free. Splicing
	// sub's object list into the parent's, and folding its allocation
	// total in too, makes the parent's own sweep the sole owner of
	// everything the module allocated, avoiding this instead of
	// special-casing module-level containers.
	if sub.objects != nil {
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
	vm.module_cache[name] = mod
	return mod, true
}

// compile_and_run_module is load_module's own compile-or-cache-hit step
// -- deliberately not routed through interpret (which always compiles
// from source unconditionally), since an imported module is the only
// place a bytecode-cache hit can skip compilation entirely (see
// docs/plans/bytecode-cache.md). Mirrors interpret's own reset-state
// prelude, since it bypasses interpret altogether, but never touches
// sub.repl -- a module's own sub-VM is never a REPL session.
@(private = "file")
compile_and_run_module :: proc(sub: ^VM, path: string, source: string) -> Interpret_Result {
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

	fn, ok := compiler.Compile(source, sub.script, sub.environment)
	if !ok {
		return .Compile_Error
	}
	status, _ := run_compiled(sub, fn)
	if status == .Ok {
		bc_cache_write(path, fn)
	}
	return status
}

// read_module_source tries, in order: `$LOX_PATH/modules/<name>.lox`,
// then alongside the *top-level entry* script (vm.root_script -- not
// vm.script, the module currently being loaded, see the VM struct's
// doc comment on root_script), then a recursive search of the entry
// script's own directory tree -- so scripts can group their own
// modules into subfolders. The stdlib modules live under a `modules/`
// directory at the LOX_PATH root, since `src/` in this repository is
// exclusively Odin source, not Lox source.
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

	// filepath.dir (os.dir) returns a slice *into* vm.root_script, not a
	// fresh allocation (see os/path.odin's split_path) -- deleting it
	// would be a bad free of memory this proc doesn't own.
	dir := filepath.dir(vm.root_script)
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
