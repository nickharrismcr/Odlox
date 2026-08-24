package compiler

// Cross-module type checking: what a module statically exports, and how
// a Type_Checker asks for another module's signature. The single-file
// checker (typecheck.odin/typecheck_expr.odin/typecheck_stmt.odin/
// typecheck_class.odin) is otherwise unchanged by this -- every
// consultation site (Stmt_From_Import/Stmt_Import in typecheck_stmt.odin,
// type_from_expr in types.odin, flatten_class in typecheck_class.odin)
// just gets one more fallback tier to try before giving up to Dynamic.

// Module_Signature is what a Resolve_Module_Proc hands back: every
// top-level binding a module makes, by name. `vars` covers functions,
// plain vars/consts, and class names alike (a class's own top-level
// binding already gets a .Class-kind Type recorded via record_decl_type
// in typecheck_stmt.odin's typecheck_class_decl, same as any other
// global), so `vars` alone is enough for `from mod import Name` lookup.
// `classes` exposes the same Class_Type objects directly (not rebuilt),
// so type_from_expr/flatten_class can consume a ^Class_Type the same way
// they already do for a same-file class -- see build_module_signature.
Module_Signature :: struct {
	name:    string,
	vars:    map[string]^Type,
	classes: map[string]^Class_Type,
}

// Resolve_Module_Proc is how a Type_Checker reaches another module's
// signature, supplied by the caller (ultimately vm/module_typecheck.odin)
// -- Odin procs aren't closures, so state that would otherwise be
// captured (a resolver's own cache, in-progress set, search root) is
// passed explicitly as ctx and cast back to a concrete type at the
// implementation site, the same pattern core.Builtin_Fn/vm.native_vm
// already use to cross the compiler/vm package boundary the other
// direction (core/obj_native.odin's Builtin_Fn doc comment). Returns
// ok=false for "couldn't reach this module at all" (not found, a builtin
// with no source, a cache-only module with no AST, a cycle) -- every
// consultation site degrades to today's exact Dynamic-everywhere
// behavior in that case, never a diagnostic (see typecheck_stmt.odin's
// Stmt_From_Import case for the one exception: a module reached
// successfully but missing the specific requested name).
Resolve_Module_Proc :: #type proc(ctx: rawptr, name: string) -> (^Module_Signature, bool)

// build_module_signature reads a fully-typechecked program's own
// top-level bindings out of an already-populated Global_Table/
// Type_Checker (no new tree walk) -- only names the Resolver actually
// marked *declared* (globals.declared), not merely referenced, count as
// real exports.
@(private = "file")
build_module_signature :: proc(name: string, globals: Global_Table, tc: ^Type_Checker) -> ^Module_Signature {
	sig := new(Module_Signature)
	sig.name = name
	sig.vars = make(map[string]^Type)
	for var_name, is_declared in globals.declared {
		if !is_declared {
			continue
		}
		slot, has_slot := globals.slots[var_name]
		if !has_slot {
			continue
		}
		if t, ok := tc.globals[slot]; ok {
			sig.vars[var_name] = t
		}
	}
	sig.classes = tc.classes
	return sig
}

// Typecheck_Module_Signature runs the same Parse -> Resolve -> Typecheck
// pipeline Compile does (resolve_program/typecheck_program reused
// unchanged), but stops *before* Emit and returns the module's own
// exported signature instead of a runnable Function_Object. This is what
// lets a module's exports be discovered statically even when its
// *bytecode* would be served from the .lxc cache when actually loaded/
// run (see vm/bc_cache.odin -- a cache hit skips Compile, and therefore
// this whole pipeline, entirely; a signature lookup independently
// re-derives from source instead, once per process run, the first time
// it's needed). name is the module's own logical name (what it's
// imported as); filename is only used for parser/diagnostic line context,
// matching Compile's own filename param -- the two commonly match but
// don't have to. resolve_module/resolve_module_ctx let *this* module's
// own imports be resolved too, transitively (see typecheck_program's own
// matching params).
Typecheck_Module_Signature :: proc(
	name, source, filename: string,
	resolve_module: Resolve_Module_Proc = nil,
	resolve_module_ctx: rawptr = nil,
) -> (
	sig: ^Module_Signature,
	diagnostics: []Type_Diagnostic,
	ok: bool,
) {
	scn := tokenize(source)
	defer destroy_scanner(&scn)

	p := Parser{scn = &scn, filename = filename}
	advance(&p)

	stmts: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration(&p)
		if s != nil {
			append(&stmts, s)
		}
	}
	if p.had_error {
		return nil, nil, false
	}

	globals, had_error := resolve_program(stmts[:], nil, filename)
	if had_error {
		return nil, nil, false
	}

	diags, tc := typecheck_program(stmts[:], resolve_module, resolve_module_ctx)
	return build_module_signature(name, globals, tc), diags, true
}
