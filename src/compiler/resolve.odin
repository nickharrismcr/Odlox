package compiler

import "core:fmt"

// Implementation phase 4 of docs/plans/compiler-ast-split.md: the
// Resolver. Reincarnates compiler_state.odin's scope/local/upvalue/global
// logic as an AST walk instead of parse-time interleaving -- annotates
// nodes in place (Var_Ref/declared_slot/is_local/local_exits/etc., all
// already declared on the relevant ast.odin node types) and runs every
// validity check the original performs inline during parsing that needs
// more than a token comparison to decide (self-inheritance is pure lexeme
// comparison and already happens at parse time -- see v2_stmt.odin's
// class_declaration_ast).
//
// Scope covers everything except try/finally *crossing* (a return/break/
// continue whose target is outside an enclosing try) -- that's
// implementation phase 6. This phase still resolves names *inside*
// try/except/finally bodies as ordinary nested scopes, including a single
// normal-completion pass over finally_body; phase 6 layers the per-
// crossing-site re-resolution on top of that without disturbing this.
//
// Hard invariant carried over from the plan doc: this file never touches
// core.Chunk. It only ever assigns slot *numbers* (local index, upvalue
// index, global index) -- never bytecode-pool indices -- which is what
// keeps the seam clean for a future type-checker to occupy the same
// position in the pipeline (after this, before Emit).

// -----------------------------------------------------------------------
// Types
//
// Local/Upvalue/Class_Compiler are compiler_state.odin's, reused
// unchanged (both migrate to this file at cutover, at which point
// compiler_state.odin goes away and this comment does too). Local's
// `debug_info_idx` is never touched here -- it only means something once
// a real Chunk exists (Emit's job).

Resolve_Scope :: struct {
	enclosing:     ^Resolve_Scope,
	fn_type:       Function_Type,
	locals:        [256]Local,
	local_count:   int,
	scope_depth:   int,
	loop_depth:    int, // >0 while resolving a while/for/foreach body in *this* function scope -- break/continue validity
	upvalues:      [256]Upvalue,
	upvalue_count: int,
}

Global_Table :: struct {
	slots:         map[string]int,
	declared:      map[string]bool,
	count:         int,
	names_by_slot: [dynamic]string,
}

Resolver :: struct {
	scope:         ^Resolve_Scope,
	current_class: ^Class_Compiler,
	had_error:     bool,

	globals:              map[string]int,
	globals_declared:     map[string]bool,
	global_count:         int,
	global_names_by_slot: [dynamic]string,
}

@(private = "file")
resolve_error :: proc(rs: ^Resolver, tok: Token, message: string) {
	rs.had_error = true
	if tok.type == .Eof {
		fmt.printfln("[line %d] Error at end: %s", tok.line, message)
	} else if tok.type == .Error {
		fmt.printfln("[line %d] Error: %s", tok.line, message)
	} else {
		fmt.printfln("[line %d] Error at '%s': %s", tok.line, lexeme(tok), message)
	}
}

// -----------------------------------------------------------------------
// Entry point

resolve_program :: proc(stmts: []Stmt) -> (globals: Global_Table, had_error: bool) {
	rs := new(Resolver)
	rs.globals = make(map[string]int)
	rs.globals_declared = make(map[string]bool)

	root := new(Resolve_Scope)
	root.fn_type = .Script
	rs.scope = root
	add_local_rs(rs, synthetic_token(.Identifier, "", 0))
	mark_initialised_rs(rs)

	resolve_stmt_list(rs, stmts)

	globals = Global_Table {
		slots         = rs.globals,
		declared      = rs.globals_declared,
		count         = rs.global_count,
		names_by_slot = rs.global_names_by_slot,
	}
	had_error = rs.had_error
	return
}

// -----------------------------------------------------------------------
// Scopes

@(private = "file")
begin_scope_rs :: proc(rs: ^Resolver) {
	rs.scope.scope_depth += 1
}

// end_scope_rs pops every local declared at a depth deeper than the scope
// being exited and returns them as Local_Exit entries -- innermost/most-
// recently-declared first, matching end_scope's own iteration order today
// (the correct order for a stack machine to pop them in, since the last-
// declared local is the one on top of the stack).
@(private = "file")
end_scope_rs :: proc(rs: ^Resolver) -> []Local_Exit {
	sc := rs.scope
	sc.scope_depth -= 1
	exits: [dynamic]Local_Exit
	for sc.local_count > 0 && sc.locals[sc.local_count - 1].depth > sc.scope_depth {
		i := sc.local_count - 1
		append(&exits, Local_Exit{slot = i, is_captured = sc.locals[i].is_captured})
		sc.local_count -= 1
	}
	return exits[:]
}

// -----------------------------------------------------------------------
// Locals

@(private = "file")
add_local_rs :: proc(rs: ^Resolver, name: Token) -> int {
	sc := rs.scope
	if sc.local_count == 256 {
		resolve_error(rs, name, "Too many local variables in function.")
		return 0
	}
	slot := sc.local_count
	sc.locals[slot] = Local{name = name, lexeme = lexeme(name), depth = -1}
	sc.local_count += 1
	return slot
}

// declare_variable_rs is a no-op (returns -1) at global scope, same as
// declare_variable -- callers branch on scope_depth themselves to decide
// between this and global_slot_rs, matching finish_declare's own split.
@(private = "file")
declare_variable_rs :: proc(rs: ^Resolver, name: Token) -> int {
	sc := rs.scope
	if sc.scope_depth == 0 {
		return -1
	}
	lex := lexeme(name)
	for i := sc.local_count - 1; i >= 0; i -= 1 {
		local := sc.locals[i]
		if local.depth != -1 && local.depth < sc.scope_depth {
			break
		}
		if local.lexeme == lex {
			resolve_error(rs, name, "Already a variable with this name in this scope.")
		}
	}
	return add_local_rs(rs, name)
}

@(private = "file")
mark_initialised_rs :: proc(rs: ^Resolver) {
	sc := rs.scope
	sc.locals[sc.local_count - 1].depth = sc.scope_depth
}

@(private = "file")
mark_local_const_rs :: proc(rs: ^Resolver) {
	sc := rs.scope
	sc.locals[sc.local_count - 1].is_const = true
}

@(private = "file")
resolve_local_rs :: proc(rs: ^Resolver, sc: ^Resolve_Scope, name: Token) -> int {
	lex := lexeme(name)
	for i := sc.local_count - 1; i >= 0; i -= 1 {
		if sc.locals[i].lexeme == lex {
			if sc.locals[i].depth == -1 {
				resolve_error(rs, name, "Can't read local variable in its own initializer.")
			}
			return i
		}
	}
	return -1
}

// -----------------------------------------------------------------------
// Upvalues

@(private = "file")
add_upvalue_rs :: proc(rs: ^Resolver, sc: ^Resolve_Scope, index: u8, is_local: bool) -> int {
	count := sc.upvalue_count
	for i in 0 ..< count {
		uv := sc.upvalues[i]
		if uv.index == index && uv.is_local == is_local {
			return i // already captured -- reuse the same upvalue slot
		}
	}
	if count == 256 {
		resolve_error(rs, Token{}, "Too many closure variables in function.")
		return 0
	}
	sc.upvalues[count] = Upvalue{index = index, is_local = is_local}
	sc.upvalue_count += 1
	return count
}

// resolve_upvalue_rs is the recursive clox-style climb, same shape as
// resolve_upvalue -- just walking Resolve_Scope.enclosing (built by this
// Resolver's own recursion into nested Function_Decl bodies) instead of a
// live parse-time Compiler.enclosing chain.
@(private = "file")
resolve_upvalue_rs :: proc(rs: ^Resolver, sc: ^Resolve_Scope, name: Token) -> int {
	if sc.enclosing == nil {
		return -1
	}
	if local := resolve_local_rs(rs, sc.enclosing, name); local != -1 {
		sc.enclosing.locals[local].is_captured = true
		return add_upvalue_rs(rs, sc, u8(local), true)
	}
	if upvalue := resolve_upvalue_rs(rs, sc.enclosing, name); upvalue != -1 {
		return add_upvalue_rs(rs, sc, u8(upvalue), false)
	}
	return -1
}

// -----------------------------------------------------------------------
// Globals

@(private = "file")
global_slot_rs :: proc(rs: ^Resolver, name: string) -> int {
	if slot, ok := rs.globals[name]; ok {
		return slot
	}
	slot := rs.global_count
	rs.globals[name] = slot
	rs.global_count += 1
	append(&rs.global_names_by_slot, name)
	return slot
}

@(private = "file")
mark_global_declared_rs :: proc(rs: ^Resolver, name: string) {
	rs.globals_declared[name] = true
}

@(private = "file")
is_global_declared_rs :: proc(rs: ^Resolver, name: string) -> bool {
	return rs.globals_declared[name] or_else false
}

// resolve_variable_rs is the three-tier dispatcher every name reference
// goes through -- local, then upvalue, then (falling back) global, same
// priority as resolve_variable. Returns a Var_Ref (location only) instead
// of resolve_variable's (arg, get_op, set_op) -- see Var_Ref's own doc
// comment in ast.odin for why that's a deliberate split.
@(private = "file")
resolve_variable_rs :: proc(rs: ^Resolver, name: Token) -> Var_Ref {
	if local := resolve_local_rs(rs, rs.scope, name); local != -1 {
		return Var_Ref{kind = .Local, slot = local, is_const = rs.scope.locals[local].is_const}
	}
	if upvalue := resolve_upvalue_rs(rs, rs.scope, name); upvalue != -1 {
		return Var_Ref{kind = .Upvalue, slot = upvalue}
	}
	return Var_Ref{kind = .Global, slot = global_slot_rs(rs, lexeme(name))}
}

// -----------------------------------------------------------------------
// Function lifecycle

@(private = "file")
begin_function_resolve :: proc(rs: ^Resolver, fn_type: Function_Type) {
	sc := new(Resolve_Scope)
	sc.enclosing = rs.scope
	sc.fn_type = fn_type
	rs.scope = sc

	// Slot 0 is always reserved for the enclosing-context value, same as
	// init_function_compiler -- see that proc's own doc comment.
	slot0_name := "this" if (fn_type == .Method || fn_type == .Initializer) else ""
	add_local_rs(rs, synthetic_token(.Identifier, slot0_name, 0))
	mark_initialised_rs(rs)
}

// end_function_resolve pops back to the enclosing scope. No Local_Exit
// list comes out of this -- unlike a Stmt_Block, a function's own top-
// level scope (params + slot 0) is never explicitly popped by end_scope
// either today: Op_Return already discards the whole call frame, so no
// per-local Pop/Close_Upvalue is ever emitted for it.
@(private = "file")
end_function_resolve :: proc(rs: ^Resolver) -> ^Resolve_Scope {
	finished := rs.scope
	rs.scope = finished.enclosing
	return finished
}

resolve_function_decl :: proc(rs: ^Resolver, decl: ^Function_Decl) {
	begin_function_resolve(rs, decl.fn_type)
	// Matches compile_function_body's own begin_scope call, for params +
	// body -- deliberately no matching end_scope_rs; see
	// end_function_resolve's own doc comment on why a function's top-level
	// scope is never explicitly popped either today.
	begin_scope_rs(rs)
	for &param in decl.params {
		declare_variable_rs(rs, param.name)
		mark_initialised_rs(rs)
		param.declared_slot = rs.scope.local_count - 1
		resolve_expr(rs, param.default)
	}
	resolve_stmt_list(rs, decl.body)
	finished := end_function_resolve(rs)
	decl.upvalues = finished.upvalues[:finished.upvalue_count]
}

// -----------------------------------------------------------------------
// Statements

resolve_stmt_list :: proc(rs: ^Resolver, stmts: []Stmt) {
	for s in stmts {
		resolve_stmt(rs, s)
	}
}

resolve_stmt :: proc(rs: ^Resolver, s: Stmt) {
	if s == nil {
		return
	}
	switch v in s {
	case ^Stmt_Expression:
		resolve_expr(rs, v.expr)
	case ^Stmt_Print:
		resolve_expr(rs, v.expr)
	case ^Stmt_Raise:
		resolve_expr(rs, v.expr)
	case ^Stmt_Breakpoint:
	// nothing to resolve
	case ^Stmt_Var_Decl:
		resolve_var_decl(rs, v)
	case ^Stmt_Implicit_Assign:
		resolve_implicit_assign(rs, v)
	case ^Stmt_Destructure:
		resolve_destructure(rs, v)
	case ^Stmt_Block:
		begin_scope_rs(rs)
		resolve_stmt_list(rs, v.stmts)
		v.local_exits = end_scope_rs(rs)
	case ^Stmt_If:
		resolve_expr(rs, v.condition)
		resolve_stmt(rs, v.then_branch)
		resolve_stmt(rs, v.else_branch)
	case ^Stmt_While:
		resolve_expr(rs, v.condition)
		rs.scope.loop_depth += 1
		resolve_stmt(rs, v.body)
		rs.scope.loop_depth -= 1
	case ^Stmt_For:
		resolve_for(rs, v)
	case ^Stmt_Foreach:
		resolve_foreach(rs, v)
	case ^Stmt_Break:
		if rs.scope.loop_depth == 0 {
			resolve_error(rs, v.token, "Cannot use break outside loop.")
		}
	case ^Stmt_Continue:
		if rs.scope.loop_depth == 0 {
			resolve_error(rs, v.token, "Cannot use continue outside loop.")
		}
	case ^Stmt_Return:
		resolve_return(rs, v)
	case ^Stmt_Function_Decl:
		resolve_function_declaration_stmt(rs, v)
	case ^Stmt_Class_Decl:
		resolve_class_decl(rs, v)
	case ^Stmt_Try:
		resolve_try(rs, v)
	case ^Stmt_Import:
		resolve_import(rs, v)
	case ^Stmt_From_Import:
		resolve_from_import(rs, v)
	}
}

// -----------------------------------------------------------------------
// var / const / implicit / destructuring declarations

// resolve_var_decl resolves the initializer *before* declaring the name,
// matching var_declaration/const_declaration's own order today -- unlike
// clox, odlox does not catch `var x = x` as a self-reference (verified
// directly against Compile() before writing this): the initializer sees
// whatever `x` means in the *enclosing* scope, since the new local isn't
// added until afterward.
@(private = "file")
resolve_var_decl :: proc(rs: ^Resolver, v: ^Stmt_Var_Decl) {
	resolve_expr(rs, v.init)
	v.is_local = rs.scope.scope_depth > 0
	if v.is_local {
		v.declared_slot = declare_variable_rs(rs, v.name)
		mark_initialised_rs(rs)
		if v.is_const {
			mark_local_const_rs(rs)
		}
	} else {
		name := lexeme(v.name)
		v.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
}

// resolve_implicit_assign mirrors implicit_assignment_core's local ->
// upvalue -> already-global -> new-local -> new-global priority exactly,
// including per-branch ordering relative to the RHS: the "new local"
// branch declares (depth -1) *before* resolving the RHS, same as
// implicit_assignment_core's add_local-then-expression-then-mark_
// initialised order -- so a first-mention `x = x` *does* trip "can't read
// local variable in its own initializer" here, unlike `var x = x` above.
// The "new global" branch marks declared before the RHS too, but globals
// have no uninitialised-sentinel state, so that has no compile-time
// consequence -- also matching today's behavior exactly.
@(private = "file")
resolve_implicit_assign :: proc(rs: ^Resolver, v: ^Stmt_Implicit_Assign) {
	sc := rs.scope
	name := lexeme(v.name)
	existing_local := resolve_local_rs(rs, sc, v.name)
	already_global := is_global_declared_rs(rs, name)
	existing_upvalue := -1
	if existing_local == -1 {
		existing_upvalue = resolve_upvalue_rs(rs, sc, v.name)
	}

	if existing_local != -1 {
		if sc.locals[existing_local].is_const {
			resolve_error(rs, v.name, fmt.tprintf("Cannot assign to const '%s'.", name))
		}
		resolve_expr(rs, v.value)
		v.resolved = Var_Ref{kind = .Local, slot = existing_local, is_const = sc.locals[existing_local].is_const}
	} else if existing_upvalue != -1 {
		resolve_expr(rs, v.value)
		v.resolved = Var_Ref{kind = .Upvalue, slot = existing_upvalue}
	} else if already_global {
		slot := global_slot_rs(rs, name)
		resolve_expr(rs, v.value)
		v.resolved = Var_Ref{kind = .Global, slot = slot}
	} else if sc.scope_depth > 0 {
		v.declared_slot = declare_variable_rs(rs, v.name)
		resolve_expr(rs, v.value)
		mark_initialised_rs(rs)
		v.resolved = Var_Ref{kind = .Local, slot = v.declared_slot}
	} else {
		slot := global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
		resolve_expr(rs, v.value)
		v.declared_slot = slot
		v.resolved = Var_Ref{kind = .Global, slot = slot}
	}
}

@(private = "file")
resolve_destructure :: proc(rs: ^Resolver, v: ^Stmt_Destructure) {
	resolve_expr(rs, v.value)
	is_local := rs.scope.scope_depth > 0
	for &target in v.targets {
		target.is_local = is_local
		if is_local {
			target.declared_slot = declare_variable_rs(rs, target.name)
			mark_initialised_rs(rs)
		} else {
			n := lexeme(target.name)
			target.declared_slot = global_slot_rs(rs, n)
			mark_global_declared_rs(rs, n)
		}
	}
}

// -----------------------------------------------------------------------
// Functions

@(private = "file")
resolve_function_declaration_stmt :: proc(rs: ^Resolver, v: ^Stmt_Function_Decl) {
	v.is_local = rs.scope.scope_depth > 0
	// Declared (and marked initialised) *before* the body resolves, so the
	// function can call itself by name for recursion -- matching
	// function_declaration's own ordering.
	if v.is_local {
		v.declared_slot = declare_variable_rs(rs, v.decl.name)
		mark_initialised_rs(rs)
	} else {
		name := lexeme(v.decl.name)
		v.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
	resolve_function_decl(rs, v.decl)
}

// -----------------------------------------------------------------------
// Control flow

@(private = "file")
resolve_for :: proc(rs: ^Resolver, v: ^Stmt_For) {
	begin_scope_rs(rs) // owns the init-variable's scope, matching for_statement's own begin_scope

	if v.init != nil {
		switch init in v.init {
		case ^Stmt_Var_Decl:
			resolve_var_decl(rs, init)
		case ^Stmt_Implicit_Assign:
			resolve_implicit_assign(rs, init)
		case ^Stmt_Expression:
			resolve_expr(rs, init.expr)
		}
	}

	resolve_expr(rs, v.condition)
	resolve_expr(rs, v.increment)

	rs.scope.loop_depth += 1
	resolve_stmt(rs, v.body) // body is always a Stmt_Block (see for_statement_ast), opens/closes its own nested scope
	rs.scope.loop_depth -= 1

	v.init_local_exits = end_scope_rs(rs)
}

// resolve_foreach uses add_local_rs directly for both the loop variable
// and the hidden __iter local, not declare_variable_rs -- matching
// foreach_statement's own add_local calls, which (like these) skip the
// duplicate-name-in-scope check declare_variable does. Both are always
// locals regardless of enclosing scope depth, same as today (add_local is
// called unconditionally, with no scope_depth branch).
@(private = "file")
resolve_foreach :: proc(rs: ^Resolver, v: ^Stmt_Foreach) {
	begin_scope_rs(rs)
	v.var_slot = add_local_rs(rs, v.var_name)
	mark_initialised_rs(rs)

	resolve_expr(rs, v.iterable)

	v.iter_slot = add_local_rs(rs, synthetic_token(.Identifier, "__iter", v.var_name.line))
	mark_initialised_rs(rs)

	rs.scope.loop_depth += 1
	resolve_stmt(rs, v.body)
	rs.scope.loop_depth -= 1

	v.local_exits = end_scope_rs(rs)
}

// -----------------------------------------------------------------------
// return
//
// The try-crossing __retval anchoring return_statement does today is
// implementation phase 6's concern -- this only runs the two validity
// checks that don't need try-context at all.

@(private = "file")
resolve_return :: proc(rs: ^Resolver, v: ^Stmt_Return) {
	if rs.scope.fn_type == .Script {
		resolve_error(rs, v.token, "Can't return from top-level code.")
	}
	if v.value != nil {
		if rs.scope.fn_type == .Initializer {
			resolve_error(rs, v.token, "Can't return a value from an initializer.")
		}
		resolve_expr(rs, v.value)
	}
}

// -----------------------------------------------------------------------
// try / except / finally
//
// Ordinary nested-scope resolution only -- see this file's header comment
// and Stmt_Try's own doc comment in ast.odin for what implementation
// phase 6 adds on top of this.

@(private = "file")
resolve_try :: proc(rs: ^Resolver, v: ^Stmt_Try) {
	begin_scope_rs(rs)
	resolve_stmt_list(rs, v.body)
	v.body_local_exits = end_scope_rs(rs)

	for &ex in v.excepts {
		begin_scope_rs(rs)
		if ex.has_binding {
			ex.binding_slot = add_local_rs(rs, ex.binding)
			mark_initialised_rs(rs)
		}
		resolve_stmt_list(rs, ex.body)
		ex.local_exits = end_scope_rs(rs)
	}

	if v.has_finally {
		begin_scope_rs(rs)
		resolve_stmt_list(rs, v.finally_body)
		v.finally_local_exits = end_scope_rs(rs)
	}
}

// -----------------------------------------------------------------------
// Classes

@(private = "file")
resolve_class_decl :: proc(rs: ^Resolver, v: ^Stmt_Class_Decl) {
	v.is_local = rs.scope.scope_depth > 0
	if v.is_local {
		v.declared_slot = declare_variable_rs(rs, v.name)
		mark_initialised_rs(rs)
	} else {
		name := lexeme(v.name)
		v.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}

	class_ctx := new(Class_Compiler)
	class_ctx.enclosing = rs.current_class
	rs.current_class = class_ctx

	// Self-inheritance is already checked at parse time (pure lexeme
	// comparison -- see class_declaration_ast); only the superclass
	// *reference* (which might be a local/upvalue/global depending on
	// where it's declared) needs real resolution here.
	if v.has_superclass {
		v.superclass_ref = resolve_variable_rs(rs, v.superclass)
		begin_scope_rs(rs)
		v.super_slot = add_local_rs(rs, synthetic_token(.Identifier, "super", v.superclass.line))
		mark_initialised_rs(rs)
		class_ctx.has_superclass = true
	}

	for member in v.members {
		switch m in member {
		case ^Method:
			resolve_function_decl(rs, m.decl)
		case ^Class_Var_Member:
			resolve_expr(rs, m.init)
		}
	}

	if v.has_superclass {
		exits := end_scope_rs(rs)
		if len(exits) > 0 {
			v.super_is_captured = exits[0].is_captured
		}
	}

	rs.current_class = class_ctx.enclosing
}

// -----------------------------------------------------------------------
// Imports
//
// Always global regardless of enclosing scope depth -- global_slot is
// called unconditionally by import_statement/from_import_statement today,
// with no scope_depth branch, so these match that directly.

@(private = "file")
resolve_import :: proc(rs: ^Resolver, v: ^Stmt_Import) {
	for &item in v.items {
		name := lexeme(item.alias) if item.has_alias else lexeme(item.module)
		item.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
}

@(private = "file")
resolve_from_import :: proc(rs: ^Resolver, v: ^Stmt_From_Import) {
	if v.wildcard {
		return
	}
	for &n in v.names {
		name := lexeme(n.name)
		n.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
}

// -----------------------------------------------------------------------
// Expressions

resolve_expr :: proc(rs: ^Resolver, e: Expr) {
	if e == nil {
		return
	}
	switch v in e {
	case ^Expr_Literal:
	// nothing to resolve
	case ^Expr_Str_Call:
		resolve_expr(rs, v.inner)
	case ^Expr_Tuple:
		for el in v.elements {
			resolve_expr(rs, el)
		}
	case ^Expr_Unary:
		resolve_expr(rs, v.operand)
	case ^Expr_Binary:
		resolve_expr(rs, v.left)
		resolve_expr(rs, v.right)
	case ^Expr_Logical:
		resolve_expr(rs, v.left)
		resolve_expr(rs, v.right)
	case ^Expr_Conditional:
		resolve_expr(rs, v.condition)
		resolve_expr(rs, v.then_branch)
		resolve_expr(rs, v.else_branch)
	case ^Expr_Variable:
		v.resolved = resolve_variable_rs(rs, v.name)
	case ^Expr_Assign:
		resolve_assign(rs, v)
	case ^Expr_This:
		if rs.current_class == nil {
			resolve_error(rs, v.token, "Can't use 'this' outside of a class.")
		} else {
			v.resolved = resolve_variable_rs(rs, synthetic_token(.Identifier, "this", v.token.line))
		}
	case ^Expr_Super:
		resolve_super(rs, v)
	case ^Expr_Call:
		resolve_expr(rs, v.callee)
		for a in v.args {
			resolve_expr(rs, a)
		}
	case ^Expr_Property:
		resolve_expr(rs, v.object)
		resolve_expr(rs, v.value)
		for a in v.args {
			resolve_expr(rs, a)
		}
	case ^Expr_Subscript:
		resolve_expr(rs, v.object)
		resolve_expr(rs, v.index)
		resolve_expr(rs, v.slice_start)
		resolve_expr(rs, v.slice_end)
		resolve_expr(rs, v.assign_value)
	case ^Expr_List:
		for el in v.elements {
			resolve_expr(rs, el)
		}
	case ^Expr_Dict:
		for entry in v.entries {
			resolve_expr(rs, entry.key)
			resolve_expr(rs, entry.value)
		}
	case ^Expr_Lambda:
		resolve_function_decl(rs, v.decl)
	}
}

// resolve_assign matches named_variable's assignment branch: resolve the
// target *then* the RHS (see resolve_variable_rs's own doc comment --
// order between the two never changes what either resolves to, but this
// keeps the sequencing identical to today for closeness of fit). Only a
// true local's const-ness is checked, matching named_variable's own
// `get_op == .Get_Local` condition exactly -- an upvalue-captured const
// is not caught at compile time today either.
@(private = "file")
resolve_assign :: proc(rs: ^Resolver, v: ^Expr_Assign) {
	v.resolved = resolve_variable_rs(rs, v.name)
	if v.resolved.kind == .Local && v.resolved.is_const {
		resolve_error(rs, v.name, fmt.tprintf("Cannot assign to const '%s'.", lexeme(v.name)))
	}
	resolve_expr(rs, v.value)
}

@(private = "file")
resolve_super :: proc(rs: ^Resolver, v: ^Expr_Super) {
	if rs.current_class == nil {
		resolve_error(rs, v.token, "Can't use 'super' outside of a class.")
	} else if !rs.current_class.has_superclass {
		resolve_error(rs, v.token, "Can't use 'super' in a class with no superclass.")
	}
	v.this_ref = resolve_variable_rs(rs, synthetic_token(.Identifier, "this", v.token.line))
	v.super_ref = resolve_variable_rs(rs, synthetic_token(.Identifier, "super", v.token.line))
	for a in v.args {
		resolve_expr(rs, a)
	}
}
