package compiler

import "core:fmt"

// The Type_Checker: the optional type annotations feature (docs/plans/
// optional-type-checking-implementation.md). Walks the AST the Resolver
// already annotated (resolve.odin), producing type diagnostics --
// warnings by default; compile.odin's StrictTypes (set by the
// --strict-types CLI flag) is what turns them into build failures. Runs
// strictly after resolve_program succeeds (see compile.odin), so every
// Var_Ref/declared_slot/is_local this walk reads is already final.
//
// The load-bearing idea, straight from the design doc's "Reusing the
// Resolver's slot numbers" section: this walk never does its own name
// lookup. A local/global read or write keys directly into the maps below
// by Var_Ref.slot/declared_slot -- all scope work already happened in the
// Resolver. Local_Type_Scope mirrors Resolve_Scope's own shape (one fresh
// scope per function activation, chained via .enclosing, blocks/if/while/
// for don't get their own -- see resolve.odin's own comment on why a
// function's locals live in one flat array regardless of nested block
// depth) for exactly the same reason Resolve_Scope does: slot numbers are
// only unique *within* one function activation, reused across sibling
// blocks once each one's locals go out of scope.
Type_Checker :: struct {
	globals:            map[int]^Type, // one map for the whole program, keyed by Var_Ref.slot -- global slots are unique program-wide (see resolve.odin's global_slot_rs), so no chaining needed here the way locals need it
	pinned_globals:     map[int]bool, // which of the above came from an explicit annotation -- see record_decl_type/record_inferred_type's own doc comments for what "pinned" means and why it exists
	locals:             ^Local_Type_Scope, // current function activation's own scope
	fn_return:          ^Type, // current function's declared return type; nil if untyped or at top level -- Stmt_Return skips checking entirely when nil, see typecheck_stmt.odin
	classes:            map[string]^Class_Type, // every class's signature, name-keyed -- built once, program-wide, before anything else (see typecheck_class.odin's typecheck_collect_class_signatures), since a class can be referenced anywhere regardless of where (or whether yet) it's declared
	current_class:      ^Class_Type, // pushed/popped around a class's own member checking (typecheck_stmt.odin's typecheck_class_decl), mirroring Resolver.current_class bracketing resolve_class_decl -- nil outside any class body, consulted by Expr_This/Expr_Super
	resolve_module:     Resolve_Module_Proc, // nil unless the caller supplied one (see typecheck_program) -- consulted as a fallback tier by Stmt_Import/Stmt_From_Import (typecheck_stmt.odin), type_from_expr (types.odin), and flatten_class's superclass lookup (typecheck_class.odin) before any of them give up to Dynamic/methods_uncertain
	resolve_module_ctx: rawptr, // opaque state resolve_module casts back to a concrete type -- see Resolve_Module_Proc's own doc comment (module_signature.odin) for why this exists instead of a captured closure
	diagnostics:        [dynamic]Type_Diagnostic,
}

// Local_Type_Scope.upvalues is decl.upvalues (already filled in by the
// Resolver by the time typecheck runs) for whichever Function_Decl this
// scope belongs to -- see lookup_upvalue_type's own doc comment for why a
// captured variable's type can't be found by naively reinterpreting a
// Var_Ref's upvalue slot as a raw local slot in the enclosing scope.
Local_Type_Scope :: struct {
	enclosing: ^Local_Type_Scope,
	slots:     map[int]^Type,
	pinned:    map[int]bool,
	upvalues:  []Upvalue,
}

Type_Diagnostic :: struct {
	token:   Token,
	message: string,
}

// typecheck_program's signature deliberately doesn't take resolve_program's
// own Global_Table: nothing here needs it. Every read/write this walk does
// goes through a slot number already baked into the AST (Var_Ref.slot,
// Param/Stmt_Var_Decl.declared_slot, ...), and a slot with no entry yet in
// `globals`/the current scope's `slots` (a forward-referenced global, or a
// local genuinely never declared -- can't happen, the Resolver would have
// already errored) synthesizes Dynamic rather than needing a name to look
// anything up by.
//
// resolve_module/resolve_module_ctx default to nil for every ordinary
// single-file caller (Compile/Compile_Repl, and the whole existing
// typecheck_test.odin suite) -- with no resolver, every cross-module
// consultation site degrades to exactly today's Dynamic-everywhere
// behavior, so this is a strictly additive capability. Returns the
// populated ^Type_Checker itself alongside diagnostics so a caller
// building a Module_Signature (module_signature.odin's
// Typecheck_Module_Signature) can read the finished globals/classes maps
// straight back out -- ordinary callers just discard it.
typecheck_program :: proc(
	stmts: []Stmt,
	resolve_module: Resolve_Module_Proc = nil,
	resolve_module_ctx: rawptr = nil,
) -> (
	diagnostics: []Type_Diagnostic,
	tc: ^Type_Checker,
) {
	tc = new(Type_Checker)
	tc.globals = make(map[int]^Type)
	tc.pinned_globals = make(map[int]bool)
	tc.classes = make(map[string]^Class_Type)
	tc.resolve_module = resolve_module
	tc.resolve_module_ctx = resolve_module_ctx
	root := new(Local_Type_Scope)
	root.slots = make(map[int]^Type)
	root.pinned = make(map[int]bool)
	tc.locals = root

	// Pass 1: every class's full signature (fields/methods/superclass),
	// program-wide, before pass 2 (the ordinary statement walk just
	// below) checks a single statement -- a class can be called/
	// referenced anywhere, regardless of where, or even whether yet,
	// it's declared (see typecheck_class.odin's own header comment).
	typecheck_collect_class_signatures(tc, stmts)

	// Pass 2.
	typecheck_stmt_list(tc, stmts)

	return tc.diagnostics[:], tc
}

diagnose :: proc(tc: ^Type_Checker, tok: Token, message: string) {
	append(&tc.diagnostics, Type_Diagnostic{token = tok, message = message})
}

// record_decl_type is every *authoritative* declaration site's own "this
// slot now has this type, permanently" write -- an explicitly annotated
// Param/Stmt_Var_Decl, Stmt_Function_Decl/Stmt_Class_Decl's own name
// (a function/class binding is a deliberate, strong declaration, not an
// ordinary var -- reassigning `f` after `func f() {}` to something
// incompatible is still flagged), Stmt_Destructure/Stmt_Foreach's hidden
// locals/Except_Clause's binding/Stmt_Import (always Dynamic regardless,
// so pinning them has no observable effect either way). Marks the slot
// *pinned*: Expr_Assign/Stmt_Implicit_Assign's reassignment checks
// (typecheck_expr.odin/typecheck_stmt.odin) diagnose an incompatible
// write to a pinned slot and never change what's recorded there. See
// record_inferred_type just below for the unpinned counterpart, and this
// file's own is_pinned for how a reassignment site decides which
// treatment applies.
record_decl_type :: proc(tc: ^Type_Checker, is_local: bool, slot: int, t: ^Type) {
	if is_local {
		tc.locals.slots[slot] = t
		tc.locals.pinned[slot] = true
	} else {
		tc.globals[slot] = t
		tc.pinned_globals[slot] = true
	}
}

// record_inferred_type is the unpinned counterpart, for a slot whose type
// was never promised by an explicit annotation -- an unannotated Stmt_
// Var_Decl (records the initializer's own synthesized type rather than
// forcing Dynamic) and an unannotated Param, plus Stmt_Implicit_Assign's
// new-binding branch (which has no annotation surface of its own at
// all). Unlike record_decl_type, a slot recorded
// this way is *never* checked on reassignment -- Expr_Assign/Stmt_
// Implicit_Assign instead call this again to *widen* it to whatever the
// new value's type is, so later reads between here and the next
// reassignment stay reasonably accurate without ever risking a false
// positive on the reassignment itself (see typecheck_stmt.odin's var/
// implicit-assign header comment for the concrete scenario this avoids:
// an unannotated `var x = 1` later reassigned to a string must never be
// flagged, unlike an *annotated* `var x: int = 1` doing the same).
// Explicitly clears any stale pinned flag left behind by an earlier,
// different declaration that happened to reuse this exact slot number
// (locals are only unique *within* one function activation -- see this
// file's own header comment -- so a slot number can be pinned by one
// sibling block's declaration and then legitimately reused, unpinned, by
// a later one).
record_inferred_type :: proc(tc: ^Type_Checker, is_local: bool, slot: int, t: ^Type) {
	if is_local {
		tc.locals.slots[slot] = t
		delete_key(&tc.locals.pinned, slot)
	} else {
		tc.globals[slot] = t
		delete_key(&tc.pinned_globals, slot)
	}
}

// is_pinned reports whether ref's slot came from an explicit annotation
// (record_decl_type) as opposed to inference (record_inferred_type) --
// consulted by every reassignment site to decide "check and leave it
// alone" vs. "skip the check and widen it instead" (see record_inferred_
// type's own doc comment). An upvalue's pinned-ness is looked up through
// the same real Function_Decl.upvalues chain lookup_upvalue_type uses,
// for the same reason (see that proc's own doc comment) -- but, unlike a
// local/global reassignment, an *unpinned* upvalue write is left as a
// pure skip-the-check escape valve with no widening: refreshing the
// original declaring scope's slot from here would need to reach back
// across a closure boundary, a bigger change for a rarer pattern
// (reassigning a captured variable to a different type through a nested
// closure) than the feature's own catch list asks for.
is_pinned :: proc(tc: ^Type_Checker, ref: Var_Ref) -> bool {
	switch ref.kind {
	case .Local:
		return tc.locals.pinned[ref.slot] or_else false
	case .Upvalue:
		return is_upvalue_pinned(tc.locals, ref.slot)
	case .Global:
		return tc.pinned_globals[ref.slot] or_else false
	case .Unresolved:
	}
	return false
}

@(private = "file")
is_upvalue_pinned :: proc(scope: ^Local_Type_Scope, upvalue_index: int) -> bool {
	if scope == nil || upvalue_index < 0 || upvalue_index >= len(scope.upvalues) {
		return false
	}
	uv := scope.upvalues[upvalue_index]
	if uv.is_local {
		if scope.enclosing == nil {
			return false
		}
		return scope.enclosing.pinned[int(uv.index)] or_else false
	}
	return is_upvalue_pinned(scope.enclosing, int(uv.index))
}

// lookup_var_type is every read site's own slot lookup -- Expr_Variable,
// Expr_Assign/Stmt_Implicit_Assign's existing-binding compatibility
// check, and Expr_Call's callee-type resolution (an ordinary variable
// read; see typecheck_expr.odin's typecheck_call). A slot with no entry
// (a forward-referenced global whose own Stmt_Var_Decl/Stmt_Function_Decl
// hasn't been type-checked yet -- matching the Resolver's own
// forward-reference tolerance for globals) synthesizes Dynamic rather
// than erroring.
lookup_var_type :: proc(tc: ^Type_Checker, ref: Var_Ref) -> ^Type {
	switch ref.kind {
	case .Local:
		if t, ok := tc.locals.slots[ref.slot]; ok {
			return t
		}
	case .Upvalue:
		if t := lookup_upvalue_type(tc.locals, ref.slot); t != nil {
			return t
		}
	case .Global:
		if t, ok := tc.globals[ref.slot]; ok {
			return t
		}
	case .Unresolved:
	}
	return dynamic_type()
}

// lookup_upvalue_type resolves a captured variable's type by walking the
// *actual* upvalue chain (Function_Decl.upvalues, filled in by the
// Resolver), not by reinterpreting the Var_Ref's upvalue-table index as a
// raw local slot number in the enclosing scope -- those are different
// numbering spaces (see Var_Ref's own doc comment in ast.odin and
// resolve.odin's add_upvalue_rs/resolve_upvalue_rs): an Upvalue Var_Ref's
// slot is an index into *this* function's own upvalue table; each entry
// there (Upvalue{index, is_local}) says whether `index` is a local slot
// in the immediately enclosing function (is_local) or itself another
// upvalue index one level further up (chained, mirroring the same climb
// resolve_upvalue_rs/Emit's own closure-upvalue-capture logic already do).
@(private = "file")
lookup_upvalue_type :: proc(scope: ^Local_Type_Scope, upvalue_index: int) -> ^Type {
	if scope == nil || upvalue_index < 0 || upvalue_index >= len(scope.upvalues) {
		return nil
	}
	uv := scope.upvalues[upvalue_index]
	if uv.is_local {
		if scope.enclosing == nil {
			return nil
		}
		if t, ok := scope.enclosing.slots[int(uv.index)]; ok {
			return t
		}
		return nil
	}
	return lookup_upvalue_type(scope.enclosing, int(uv.index))
}

// print_type_diagnostics mirrors parser.odin's error_at/resolve.odin's
// resolve_error formatting exactly (just "Warning" in place of "Error"),
// for visual consistency -- see compile.odin for where/how this gets
// called (always for Compile, gated behind StrictTypes for Compile_Repl).
print_type_diagnostics :: proc(diagnostics: []Type_Diagnostic) {
	for d in diagnostics {
		tok := d.token
		if tok.type == .Eof {
			fmt.printfln("[line %d] Warning at end: %s", tok.line, d.message)
		} else if tok.type == .Error {
			fmt.printfln("[line %d] Warning: %s", tok.line, d.message)
		} else {
			fmt.printfln("[line %d] Warning at '%s': %s", tok.line, lexeme(tok), d.message)
		}
	}
}
