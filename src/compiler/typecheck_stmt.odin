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
		fn_type := build_func_type(tc, v.decl)
		record_decl_type(tc, v.is_local, v.declared_slot, fn_type)
		typecheck_function_decl(tc, v.decl)
	case ^Stmt_Class_Decl:
		typecheck_class_decl(tc, v)
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
			typecheck_from_import(tc, v)
		}
	}
}

// typecheck_register_imported_classes is typecheck_program's pass 0
// (typecheck.odin) -- merges every top-level, non-wildcard from-imported
// class straight into tc.classes, keyed by its local bound name, before
// pass 1 (typecheck_collect_class_signatures) or pass 2 ever runs. This
// is what makes a from-imported class usable as a superclass
// (flatten_class's ordinary tc.classes[super_name] lookup, typecheck_
// class.odin) or a type annotation (type_from_expr's ordinary
// tc.classes[name] lookup, types.odin) -- *neither* of those sites needs
// its own separate resolver consultation, since both already just read
// tc.classes by name and this pass is what gets a cross-module class
// into that table in the first place. Deliberately restricted to
// *top-level* Stmt_From_Import: tc.classes is one program-wide name
// space, unlike a local variable's own scoped slot, so registering a
// class imported inside a function/block body here would leak that name
// into every other scope's annotations, wider than the import's own
// real visibility. Non-class exports (functions, plain vars) need no
// equivalent pre-pass -- typecheck_from_import (just below) already
// resolves those correctly regardless of statement order, since a
// variable read/annotation always goes through its own declared_slot,
// never a name-keyed table the way a class annotation does. Not file-
// private -- called from typecheck_program (typecheck.odin) as pass 0.
typecheck_register_imported_classes :: proc(tc: ^Type_Checker, stmts: []Stmt) {
	for s in stmts {
		v, is_from_import := s.(^Stmt_From_Import)
		if !is_from_import || v.wildcard {
			continue
		}
		sig, found := resolve_module_signature(tc, lexeme(v.module))
		if !found {
			continue
		}
		for n in v.names {
			name := lexeme(n.name)
			if ct, has_class := sig.classes[name]; has_class {
				tc.classes[name] = ct
			}
		}
	}
}

// typecheck_from_import looks each named import up in its module's own
// Module_Signature (resolve_module_signature, typecheck.odin) -- a real
// type on success, Dynamic with no diagnostic if the module itself
// couldn't be reached at all (not found, a builtin, a cycle -- a
// different, unrelated problem class from "reached it and the name is
// missing"), or Dynamic *with* a diagnostic when the module was reached
// but genuinely doesn't export this name -- mirrors the runtime error of
// identical shape (vm/module.odin's do_import_from:
// "Module '%s' has no export '%s'."), moving a subset of that mistake
// class from "crashes the first time this code runs" to "flagged at
// compile time". `from mod import *` (wildcard) is a deliberate,
// documented non-goal: it declares no From_Import_Name entries at all
// (see resolve_from_import's own wildcard early return), so there's no
// declared_slot here to hang a resolved type on -- fixing it needs a
// materially different mechanism (binding every one of the target's
// exported names into the importer's own scope at typecheck time,
// mirroring what the runtime wildcard branch already does), not
// something this consultation site can cover incidentally.
@(private = "file")
typecheck_from_import :: proc(tc: ^Type_Checker, v: ^Stmt_From_Import) {
	module_name := lexeme(v.module)
	sig, found := resolve_module_signature(tc, module_name)
	for n in v.names {
		name := lexeme(n.name)
		t := dynamic_type()
		if found {
			if vt, ok := sig.vars[name]; ok {
				t = vt
			} else {
				diagnose(tc, n.name, fmt.tprintf("module '%s' has no export '%s'", module_name, name))
			}
		}
		record_decl_type(tc, false, n.declared_slot, t)
	}
}

// -----------------------------------------------------------------------
// var / const / implicit declarations
//
// An *annotated* var/const's slot is pinned to its declared type
// (record_decl_type): every later reassignment is checked against it and
// never changes what's recorded. An *unannotated* one (including a bare
// `x = expr` first mention, which has no annotation surface of its own
// at all) is unpinned (record_inferred_type): its slot still starts out
// as whatever the initializer's own type is (useful for a call/property
// check a few lines later in straight-line code), but every later
// reassignment *widens* it to the new value's type instead of being
// checked against it -- so `var x: int = 1; x = "hi"` diagnoses (an
// annotation is a promise), while `var x = 1; x = "hi"` never does (no
// promise was ever made) -- the gradual-typing escape valve the design
// doc's own test list calls for. See record_decl_type/record_inferred_
// type/is_pinned in typecheck.odin for the mechanism this rests on.

@(private = "file")
typecheck_var_decl :: proc(tc: ^Type_Checker, v: ^Stmt_Var_Decl) {
	init_type := typecheck_expr(tc, v.init)

	if v.type_annotation != nil {
		declared := type_from_expr(tc, v.type_annotation)
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
		record_decl_type(tc, v.is_local, v.declared_slot, declared)
		return
	}

	record_inferred_type(tc, v.is_local, v.declared_slot, init_type)
}

@(private = "file")
typecheck_implicit_assign :: proc(tc: ^Type_Checker, v: ^Stmt_Implicit_Assign) {
	value_type := typecheck_expr(tc, v.value)
	if v.declares_new {
		record_inferred_type(tc, v.resolved.kind == .Local, v.declared_slot, value_type)
		return
	}

	if is_pinned(tc, v.resolved) {
		existing := lookup_var_type(tc, v.resolved)
		if !types_compatible(existing, value_type) {
			diagnose(
				tc,
				v.name,
				fmt.tprintf(
					"cannot assign %s to '%s' of type %s",
					type_string(value_type),
					lexeme(v.name),
					type_string(existing),
				),
			)
		}
		return
	}
	if v.resolved.kind == .Local || v.resolved.kind == .Global {
		record_inferred_type(tc, v.resolved.kind == .Local, v.resolved.slot, value_type)
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
// Classes -- pass 2's per-class walk. v's own Class_Type signature is
// already fully built (pass 1, typecheck_collect_class_signatures, ran
// before typecheck_program's ordinary statement walk even began -- see
// typecheck.odin). This just records it at v's own declaring slot (a
// class name, like a function name, is itself a value -- the
// constructor/class itself, see typecheck_expr.odin's typecheck_call for
// how a call through it becomes a constructor call), then checks each
// member body for real, with tc.current_class pushed/popped the same way
// Resolver.current_class brackets resolve_class_decl (resolve.odin:1046-
// 1080), and finally checks every override this class's own methods made
// against its superclass for compatibility.

@(private = "file")
typecheck_class_decl :: proc(tc: ^Type_Checker, v: ^Stmt_Class_Decl) {
	ct := tc.classes[lexeme(v.name)]
	record_decl_type(tc, v.is_local, v.declared_slot, new_clone(Type{kind = .Class, class_type = ct}))

	saved_class := tc.current_class
	tc.current_class = ct

	for member in v.members {
		switch m in member {
		case ^Method:
			fn_type := typecheck_function_decl(tc, m.decl)
			// __init__ is exempt from override-compatibility checking --
			// unlike an ordinary method, a constructor is never called
			// polymorphically through a base-class-typed reference, so
			// there's no substitutability requirement to enforce: a
			// subclass's own __init__ legitimately takes a completely
			// different parameter list than its superclass's (see
			// class Dog < Animal in field_slot_basic.lox -- a real
			// false positive this surfaced).
			if !m.is_static && m.decl.fn_type != .Initializer {
				if super_type, is_override := ct.overrides[lexeme(m.name)]; is_override {
					check_override_compatible(tc, m.name, fn_type, super_type)
				}
			}
		case ^Class_Var_Member:
			typecheck_expr(tc, m.init)
		}
	}

	tc.current_class = saved_class
}

// check_override_compatible checks arity match and pointwise param/
// return compatibility via the same types_compatible gradual predicate
// every other call/assignment/return check already uses -- an
// unannotated override param/return is automatically compatible
// (Dynamic), matching the design doc's "compatible or unannotated" bar.
@(private = "file")
check_override_compatible :: proc(tc: ^Type_Checker, name_tok: Token, sub_type, super_type: ^Type) {
	if len(sub_type.func_params) != len(super_type.func_params) {
		diagnose(
			tc,
			name_tok,
			fmt.tprintf("override of '%s' has a different number of parameters than its superclass method", lexeme(name_tok)),
		)
		return
	}
	for i in 0 ..< len(sub_type.func_params) {
		if !types_compatible(super_type.func_params[i], sub_type.func_params[i]) {
			diagnose(
				tc,
				name_tok,
				fmt.tprintf(
					"override of '%s': parameter %d type %s is incompatible with the superclass method's %s",
					lexeme(name_tok),
					i + 1,
					type_string(sub_type.func_params[i]),
					type_string(super_type.func_params[i]),
				),
			)
		}
	}
	if !types_compatible(super_type.func_return, sub_type.func_return) {
		diagnose(
			tc,
			name_tok,
			fmt.tprintf(
				"override of '%s' returns %s, incompatible with the superclass method's %s",
				lexeme(name_tok),
				type_string(sub_type.func_return),
				type_string(super_type.func_return),
			),
		)
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
build_func_type :: proc(tc: ^Type_Checker, decl: ^Function_Decl) -> ^Type {
	if decl.cached_func_type != nil {
		return decl.cached_func_type
	}
	param_types := make([dynamic]^Type, 0, len(decl.params))
	for param in decl.params {
		pt := type_from_expr(tc, param.type_annotation) if param.type_annotation != nil else dynamic_type()
		append(&param_types, pt)
	}
	return_type := type_from_expr(tc, decl.return_type) if decl.return_type != nil else dynamic_type()
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
	fn_type := build_func_type(tc, decl)

	child := new(Local_Type_Scope)
	child.enclosing = tc.locals
	child.slots = make(map[int]^Type)
	child.pinned = make(map[int]bool)
	child.upvalues = decl.upvalues

	saved_locals := tc.locals
	saved_fn_return := tc.fn_return
	tc.locals = child
	tc.fn_return = type_from_expr(tc, decl.return_type) if decl.return_type != nil else nil

	for &param, i in decl.params {
		child.slots[param.declared_slot] = fn_type.func_params[i]
		// An unannotated param is unpinned, same treatment as an
		// unannotated var (see record_inferred_type's own doc comment) --
		// a later reassignment inside the body widens it rather than
		// being checked against it.
		if param.type_annotation != nil {
			child.pinned[param.declared_slot] = true
		}
		if param.default != nil {
			typecheck_expr(tc, param.default)
		}
	}

	typecheck_stmt_list(tc, decl.body)

	tc.locals = saved_locals
	tc.fn_return = saved_fn_return
	return fn_type
}
