package vm

import "../compiler"
import "../core"
import "core:strings"

// Module_Resolver is the vm-side implementation of compiler.Resolve_
// Module_Proc: turns a module name into a compiler.Module_Signature by
// independently parsing+resolving+typechecking that module's own *source*
// text -- never by consulting module_cache/bc_cache (see the plan's
// "Bytecode cache interaction is the load-bearing constraint" design
// note: a cache-served .lxc module has no AST to typecheck at all, and a
// signature is needed the first time it's asked for regardless of
// whether the module's own *bytecode* later comes from cache when it's
// actually loaded/run). root_script anchors every search the same way
// read_module_source's own three tiers do (module.odin) -- bound once,
// per top-level run (module_resolve_proc, just below), and reused
// unchanged at every depth of the transitive import graph: nothing here
// ever needs to know "who is asking".
Module_Resolver :: struct {
	root_script:     string,
	builtin_modules: map[^core.String_Object]^core.Module_Object, // aliased from the owning VM's own map, same safe-sharing rationale as sub.builtin_modules in module.odin's load_module (populated once by define_builtins, never mutated afterward)
	cache:           map[string]^compiler.Module_Signature,
	in_progress:     map[string]bool, // mirrors flatten_class's own cycle guard (typecheck_class.odin) and load_module's modules_loading (module.odin) -- same problem shape, one level further out
}

make_module_resolver :: proc(root_script: string, builtin_modules: map[^core.String_Object]^core.Module_Object) -> ^Module_Resolver {
	r := new(Module_Resolver)
	r.root_script = root_script
	r.builtin_modules = builtin_modules
	r.cache = make(map[string]^compiler.Module_Signature)
	r.in_progress = make(map[string]bool)
	return r
}

// module_resolve_proc is every Compile()/Compile_Repl() call site's own
// "what resolver, if any, applies here" decision, in one place -- a VM
// with no module_resolver set (compile_file's throwaway Environment path
// in main.odin has no ^VM at all to set one on, so this never even runs
// for it) must get back a nil proc, not a valid proc paired with a nil
// ctx, since resolve_module_for_typecheck below dereferences ctx
// unconditionally.
module_resolve_proc :: proc(vm: ^VM) -> (compiler.Resolve_Module_Proc, rawptr) {
	if vm.module_resolver == nil {
		return nil, nil
	}
	return resolve_module_for_typecheck, vm.module_resolver
}

// resolve_module_for_typecheck is the concrete compiler.Resolve_Module_
// Proc -- ctx is always a ^Module_Resolver, cast back the same way
// native_vm casts a rawptr back to ^VM (builtins.odin).
resolve_module_for_typecheck :: proc(ctx: rawptr, name: string) -> (^compiler.Module_Signature, bool) {
	r := (^Module_Resolver)(ctx)

	if sig, ok := r.cache[name]; ok {
		return sig, true
	}
	if _, ok := r.builtin_modules[core.intern_string(name)]; ok {
		// No native-module signatures in v1 -- every consultation site
		// already degrades to Dynamic on ok=false (typecheck_stmt.odin/
		// types.odin/typecheck_class.odin), so this is simply "can't
		// statically resolve this one", not a special case to thread
		// through.
		return nil, false
	}
	if r.in_progress[name] {
		return nil, false
	}
	r.in_progress[name] = true
	defer delete_key(&r.in_progress, name)

	filename := strings.concatenate({name, ".lox"})
	defer delete(filename)

	data, path, found := find_module_lox_path_tier(filename, false)
	if !found {
		data, path, found = find_module_alongside_root_tier(r.root_script, filename, false)
	}
	if !found {
		data, path, found = find_module_recursive_tier(r.root_script, filename)
	}
	if !found {
		return nil, false
	}
	defer delete(data)

	// Diagnostics discipline: this lookup is memoized and shared across
	// every importer of this module, so its own warnings must never be
	// printed here -- that would duplicate them once per importer,
	// instead of the one real print that already happens when the
	// module is actually loaded for execution (compile_and_run_module's
	// own compiler.Compile call, module.odin).
	sig, _, ok := compiler.Typecheck_Module_Signature(name, string(data), path, resolve_module_for_typecheck, ctx)
	if !ok {
		return nil, false
	}
	r.cache[name] = sig
	return sig, true
}
