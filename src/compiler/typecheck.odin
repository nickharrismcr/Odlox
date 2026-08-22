package compiler

import "core:fmt"

// The Type_Checker: Phase 2 of optional type annotations (docs/plans/
// optional-type-checking-implementation.md). Walks the AST the Resolver
// already annotated (resolve.odin), producing type diagnostics --
// warnings only through Phase 3; Phase 4's --strict-types is what turns
// them into build failures. Runs strictly after resolve_program succeeds
// (see compile.odin), so every Var_Ref/declared_slot/is_local this walk
// reads is already final.
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
	globals:     map[int]^Type, // one map for the whole program, keyed by Var_Ref.slot -- global slots are unique program-wide (see resolve.odin's global_slot_rs), so no chaining needed here the way locals need it
	locals:      ^Local_Type_Scope, // current function activation's own scope
	fn_return:   ^Type, // current function's declared return type; nil if untyped or at top level -- Stmt_Return skips checking entirely when nil, see typecheck_stmt.odin
	diagnostics: [dynamic]Type_Diagnostic,
}

// Local_Type_Scope.upvalues is decl.upvalues (already filled in by the
// Resolver by the time typecheck runs) for whichever Function_Decl this
// scope belongs to -- see lookup_upvalue_type's own doc comment for why a
// captured variable's type can't be found by naively reinterpreting a
// Var_Ref's upvalue slot as a raw local slot in the enclosing scope.
Local_Type_Scope :: struct {
	enclosing: ^Local_Type_Scope,
	slots:     map[int]^Type,
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
typecheck_program :: proc(stmts: []Stmt) -> []Type_Diagnostic {
	tc := new(Type_Checker)
	tc.globals = make(map[int]^Type)
	root := new(Local_Type_Scope)
	root.slots = make(map[int]^Type)
	tc.locals = root

	typecheck_stmt_list(tc, stmts)

	return tc.diagnostics[:]
}

diagnose :: proc(tc: ^Type_Checker, tok: Token, message: string) {
	append(&tc.diagnostics, Type_Diagnostic{token = tok, message = message})
}

// record_decl_type is every declaration site's own "this slot now has
// this type" write -- Param/Stmt_Var_Decl (typecheck_stmt.odin),
// Stmt_Function_Decl/Stmt_Implicit_Assign's new-binding branch, Stmt_
// Destructure, Stmt_Foreach's hidden locals, Except_Clause's binding,
// Stmt_Import/Stmt_From_Import (always global).
record_decl_type :: proc(tc: ^Type_Checker, is_local: bool, slot: int, t: ^Type) {
	if is_local {
		tc.locals.slots[slot] = t
	} else {
		tc.globals[slot] = t
	}
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
