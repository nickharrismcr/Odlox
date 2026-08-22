package compiler

import "core:fmt"

// One case per Stmt variant, mirroring resolve_stmt's switch shape
// (resolve.odin:607-676) -- same traversal, now producing diagnostics
// from already-resolved slots instead of assigning them.
typecheck_stmt_list :: proc(tc: ^Type_Checker, stmts: []Stmt) {
	for s in stmts {
		typecheck_stmt(tc, s)
	}
}

typecheck_stmt :: proc(tc: ^Type_Checker, s: Stmt) {
	if s == nil {
		return
	}
	switch v in s {
	case ^Stmt_Expression:
		typecheck_expr(tc, v.expr)
	case ^Stmt_Print:
		typecheck_expr(tc, v.expr)
	case ^Stmt_Raise:
		typecheck_expr(tc, v.expr)
	case ^Stmt_Breakpoint:
	// nothing to check
	case ^Stmt_Var_Decl:
		typecheck_var_decl(tc, v)
	case ^Stmt_Implicit_Assign:
		typecheck_implicit_assign(tc, v)
	case ^Stmt_Destructure:
		typecheck_expr(tc, v.value)
		for target in v.targets {
			// No annotation surface for a destructuring target -- an
			// untyped-widening site only, matching Stmt_Implicit_Assign's
			// own new-binding branch.
			record_decl_type(tc, target.is_local, target.declared_slot, dynamic_type())
		}
	case ^Stmt_Block:
		typecheck_stmt_list(tc, v.stmts)
	case ^Stmt_If:
		typecheck_expr(tc, v.condition)
		typecheck_stmt(tc, v.then_branch)
		typecheck_stmt(tc, v.else_branch)
	case ^Stmt_While:
		typecheck_expr(tc, v.condition)
		typecheck_stmt(tc, v.body)
	case ^Stmt_For:
		typecheck_for(tc, v)
	case ^Stmt_Foreach:
		typecheck_expr(tc, v.iterable)
		// The loop variable and the hidden __iter local have no
		// annotation surface either -- always Dynamic.
		record_decl_type(tc, true, v.var_slot, dynamic_type())
		typecheck_stmt(tc, v.body)
	case ^Stmt_Break, ^Stmt_Continue:
	// nothing to check -- validity (loop nesting) is the Resolver's job
	case ^Stmt_Return:
		typecheck_return(tc, v)
	case ^Stmt_Function_Decl:
		// Declared (its own Func type recorded) *before* the body is
		// checked, mirroring resolve_function_declaration_stmt's own
		// declare-before-resolve ordering -- so a recursive call inside
		// the body resolves against this function's own signature.
		fn_type := build_func_type(v.decl)
		record_decl_type(tc, v.is_local, v.declared_slot, fn_type)
		typecheck_function_decl(tc, v.decl)
	case ^Stmt_Class_Decl:
		typecheck_class_decl_body(tc, v)
	case ^Stmt_Try:
		typecheck_try(tc, v)
	case ^Stmt_Import:
		for item in v.items {
			// Always global (see resolve_import) and always Dynamic --
			// no cross-module type information exists (see the
			// implementation plan's Stmt_Import/Stmt_From_Import note).
			record_decl_type(tc, false, item.declared_slot, dynamic_type())
		}
	case ^Stmt_From_Import:
		if !v.wildcard {
			for n in v.names {
				record_decl_type(tc, false, n.declared_slot, dynamic_type())
			}
		}
	}
}

// -----------------------------------------------------------------------
// var / const / implicit declarations
//
// A slot's recorded type is exactly its explicit annotation's type when
// one exists, and Dynamic otherwise -- deliberately *not* the
// initializer's inferred type for an unannotated `var` the way the
// implementation plan's own prose suggests ("records ... the
// initializer's synthesized type" for the no-annotation case). That
// would break the plan's own, more important invariant one section
// later: "assigning to an unannotated var never diagnoses regardless of
// type". If `var x = 1` persisted Int (inferred, not annotated) into the
// slot map, a later `x = "hi"` would call types_compatible(Int, String)
// -- both concrete, kinds differ -- and wrongly diagnose a reassignment
// that was never actually promised to stay an Int. Distinguishing
// "annotated" from "merely inferred" per-slot would need a second map
// throughout this file for no real Phase 2 benefit (the plan's own catch
// list never asks for inference beyond explicit annotations), so this
// implementation always keys assignment-compatibility off "was this slot
// ever explicitly annotated" -- Dynamic otherwise, permanently.

@(private = "file")
typecheck_var_decl :: proc(tc: ^Type_Checker, v: ^Stmt_Var_Decl) {
	init_type := typecheck_expr(tc, v.init)

	declared := dynamic_type()
	if v.type_annotation != nil {
		declared = type_from_expr(v.type_annotation)
		if !types_compatible(declared, init_type) {
			diagnose(
				tc,
				v.name,
				fmt.tprintf(
					"cannot initialize '%s' of type %s with %s",
					lexeme(v.name),
					type_string(declared),
					type_string(init_type),
				),
			)
		}
	}

	record_decl_type(tc, v.is_local, v.declared_slot, declared)
}

@(private = "file")
typecheck_implicit_assign :: proc(tc: ^Type_Checker, v: ^Stmt_Implicit_Assign) {
	value_type := typecheck_expr(tc, v.value)
	if v.declares_new {
		// No annotation surface for a bare `x = expr` declaration --
		// see this section's header comment.
		record_decl_type(tc, v.resolved.kind == .Local, v.declared_slot, dynamic_type())
		return
	}
	existing := lookup_var_type(tc, v.resolved)
	if !types_compatible(existing, value_type) {
		diagnose(
			tc,
			v.name,
			fmt.tprintf("cannot assign %s to '%s' of type %s", type_string(value_type), lexeme(v.name), type_string(existing)),
		)
	}
}

// -----------------------------------------------------------------------
// Control flow

@(private = "file")
typecheck_for :: proc(tc: ^Type_Checker, v: ^Stmt_For) {
	if v.init != nil {
		switch init in v.init {
		case ^Stmt_Var_Decl:
			typecheck_var_decl(tc, init)
		case ^Stmt_Implicit_Assign:
			typecheck_implicit_assign(tc, init)
		case ^Stmt_Expression:
			typecheck_expr(tc, init.expr)
		}
	}
	typecheck_expr(tc, v.condition)
	typecheck_expr(tc, v.increment)
	typecheck_stmt(tc, v.body)
}

// typecheck_return checks value's synthesized type (or Nil for a bare
// `return`) against tc.fn_return -- skipped entirely when tc.fn_return is
// nil (the enclosing function's return type is unannotated, or this is
// top-level code, where a bare `return` is itself a Resolver-caught
// error already).
@(private = "file")
typecheck_return :: proc(tc: ^Type_Checker, v: ^Stmt_Return) {
	value_type := typecheck_expr(tc, v.value) if v.value != nil else nil_type()
	if tc.fn_return != nil && !types_compatible(tc.fn_return, value_type) {
		diagnose(
			tc,
			v.token,
			fmt.tprintf("return type mismatch: expected %s, got %s", type_string(tc.fn_return), type_string(value_type)),
		)
	}
}

@(private = "file")
typecheck_try :: proc(tc: ^Type_Checker, v: ^Stmt_Try) {
	typecheck_stmt_list(tc, v.body)
	for except in v.excepts {
		if except.has_binding {
			record_decl_type(tc, true, except.binding_slot, dynamic_type())
		}
		typecheck_stmt_list(tc, except.body)
	}
	if v.has_finally {
		typecheck_stmt_list(tc, v.finally_body)
	}
}

// -----------------------------------------------------------------------
// Classes -- Phase 2 walks into a class body's method statements (so
// nested functions/expressions inside methods still get ordinary Phase 2
// checking) but performs no class-specific checking (no Class_Type table
// exists yet -- Phase 3 adds typecheck_class.odin and replaces this).

@(private = "file")
typecheck_class_decl_body :: proc(tc: ^Type_Checker, v: ^Stmt_Class_Decl) {
	for member in v.members {
		switch m in member {
		case ^Method:
			typecheck_function_decl(tc, m.decl)
		case ^Class_Var_Member:
			typecheck_expr(tc, m.init)
		}
	}
}

// -----------------------------------------------------------------------
// Functions

// build_func_type synthesizes decl's own Func type from its param/return
// annotations alone -- no body walk needed, which is exactly what lets
// Stmt_Function_Decl record it into the declaring slot *before* checking
// the body (see typecheck_stmt's own case above), so a recursive call
// inside that body resolves against this function's own signature.
// Memoized on the node itself (Function_Decl.cached_func_type) per the
// implementation plan, so a function referenced from many call sites
// doesn't rebuild the same Func type at every one of them.
build_func_type :: proc(decl: ^Function_Decl) -> ^Type {
	if decl.cached_func_type != nil {
		return decl.cached_func_type
	}
	param_types := make([dynamic]^Type, 0, len(decl.params))
	for param in decl.params {
		pt := type_from_expr(param.type_annotation) if param.type_annotation != nil else dynamic_type()
		append(&param_types, pt)
	}
	return_type := type_from_expr(decl.return_type) if decl.return_type != nil else dynamic_type()
	fn_type := new_clone(Type{kind = .Func, func_params = param_types[:], func_return = return_type})
	decl.cached_func_type = fn_type
	return fn_type
}

// typecheck_function_decl walks decl's own body in a fresh child scope
// chained onto the current one (mirroring begin_function_resolve/
// end_function_resolve's structural shape -- resolve.odin:556-578) and
// returns decl's own Func type. Shared by Stmt_Function_Decl and Expr_
// Lambda, matching how resolve_function_decl is already shared by both
// call sites in the Resolver; Expr_Lambda has no self-reference concern
// (no name to recurse through), so it skips Stmt_Function_Decl's own
// pre-recording step and just calls straight in here.
typecheck_function_decl :: proc(tc: ^Type_Checker, decl: ^Function_Decl) -> ^Type {
	fn_type := build_func_type(decl)

	child := new(Local_Type_Scope)
	child.enclosing = tc.locals
	child.slots = make(map[int]^Type)
	child.upvalues = decl.upvalues

	saved_locals := tc.locals
	saved_fn_return := tc.fn_return
	tc.locals = child
	tc.fn_return = type_from_expr(decl.return_type) if decl.return_type != nil else nil

	for &param, i in decl.params {
		child.slots[param.declared_slot] = fn_type.func_params[i]
		if param.default != nil {
			typecheck_expr(tc, param.default)
		}
	}

	typecheck_stmt_list(tc, decl.body)

	tc.locals = saved_locals
	tc.fn_return = saved_fn_return
	return fn_type
}
