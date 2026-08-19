package compiler

import "../core"

// AST-walking counterparts to stmt.odin's declaration/statement/control-
// flow functions. break/continue emit the Resolver's pop_exits/Local_Exit
// cleanup for jumping past enclosing blocks, then End_Try/finally
// re-emission (emit_try_crossings) for every enclosing try being crossed,
// then their terminal jump. try/except/finally emission always re-resolves
// finally_body fresh immediately before emitting it.

// -----------------------------------------------------------------------
// Top-level dispatch

emit_stmt_list :: proc(em: ^Emitter, stmts: []Stmt) {
	for s in stmts {
		emit_stmt(em, s)
	}
}

emit_stmt :: proc(em: ^Emitter, s: Stmt) {
	if s == nil {
		return
	}
	switch v in s {
	case ^Stmt_Expression:
		emit_expr(em, v.expr)
		emit_op(em, .Pop, v.token.line)
	case ^Stmt_Print:
		emit_expr(em, v.expr)
		// Op_Str first: also the __str__() dispatch point, not just
		// generic string conversion -- matches print_statement exactly.
		emit_op(em, .Str, v.token.line)
		emit_op(em, .Print, v.token.line)
	case ^Stmt_Raise:
		emit_expr(em, v.expr)
		emit_op(em, .Raise, v.token.line)
	case ^Stmt_Breakpoint:
		emit_op(em, .Breakpoint, v.token.line)
	case ^Stmt_Var_Decl:
		emit_var_decl(em, v)
	case ^Stmt_Implicit_Assign:
		emit_implicit_assign(em, v)
	case ^Stmt_Destructure:
		emit_destructure(em, v)
	case ^Stmt_Block:
		emit_stmt_list(em, v.stmts)
		emit_local_exits(em, v.local_exits, v.token.line)
	case ^Stmt_If:
		emit_if(em, v)
	case ^Stmt_While:
		emit_while(em, v)
	case ^Stmt_For:
		emit_for(em, v)
	case ^Stmt_Foreach:
		emit_foreach(em, v)
	case ^Stmt_Break:
		emit_break(em, v)
	case ^Stmt_Continue:
		emit_continue(em, v)
	case ^Stmt_Return:
		emit_return_stmt(em, v)
	case ^Stmt_Function_Decl:
		emit_function_declaration_stmt(em, v)
	case ^Stmt_Class_Decl:
		emit_class_decl(em, v)
	case ^Stmt_Try:
		emit_try(em, v)
	case ^Stmt_Import:
		emit_import(em, v)
	case ^Stmt_From_Import:
		emit_from_import(em, v)
	}
}

// emit_local_exits is what every scope-close point (Stmt_Block, loop
// bodies, except/finally clauses, a break/continue's own pop_exits) drives
// off of -- Close_Upvalue for a captured local, plain Pop otherwise,
// matching end_scope/pop_locals_above's own Pop-vs-Close_Upvalue choice.
@(private = "file")
emit_local_exits :: proc(em: ^Emitter, exits: []Local_Exit, line: int) {
	for ex in exits {
		if ex.is_captured {
			emit_op(em, .Close_Upvalue, line)
		} else {
			emit_op(em, .Pop, line)
		}
		close_local_debug(em, ex.slot)
	}
}

// -----------------------------------------------------------------------
// var / const / implicit / destructuring declarations

@(private = "file")
emit_var_decl :: proc(em: ^Emitter, v: ^Stmt_Var_Decl) {
	line := v.token.line
	if v.init != nil {
		emit_expr(em, v.init)
	} else {
		emit_op(em, .Nil, line)
	}
	if v.is_local {
		open_local_debug(em, lexeme(v.name), v.declared_slot)
	} else {
		op := core.Op_Code.Define_Global_Const if v.is_const else core.Op_Code.Define_Global
		emit_op_byte(em, op, u8(v.declared_slot), line)
	}
}

// emit_implicit_assign has two shapes, matching implicit_assignment_core's
// own split: a brand-new binding (declares_new) leaves its value on the
// stack with no Set/Pop for a local (Define_Global for a global, same as
// Stmt_Var_Decl's global branch); an existing binding of any kind emits
// Set_*+Pop, since as a full statement the assignment's own value isn't
// consumed by anything the way a sub-expression assignment's is.
@(private = "file")
emit_implicit_assign :: proc(em: ^Emitter, v: ^Stmt_Implicit_Assign) {
	line := v.token.line
	kind := v.resolved.kind
	slot := u8(v.resolved.slot)

	if v.declares_new {
		emit_expr(em, v.value)
		if kind == .Global {
			emit_op_byte(em, .Define_Global, slot, line)
		} else {
			open_local_debug(em, lexeme(v.name), v.declared_slot)
		}
		return
	}

	emit_expr(em, v.value)
	emit_op_byte(em, set_op_for_ref(kind), slot, line)
	emit_op(em, .Pop, line)
}

// emit_destructure: Op_Unpack already pushed the values in declaration
// order -- for fresh locals that's already their correct slot layout,
// but Define_Global pops exactly one value each, so those must run in
// the reverse of push order to match what Unpack left on the stack,
// matching destructuring_assignment_statement exactly.
@(private = "file")
emit_destructure :: proc(em: ^Emitter, v: ^Stmt_Destructure) {
	line := v.token.line
	emit_expr(em, v.value)
	emit_op_byte(em, .Unpack, u8(len(v.targets)), line)

	if len(v.targets) == 0 {
		return
	}
	if v.targets[0].is_local {
		for target in v.targets {
			open_local_debug(em, lexeme(target.name), target.declared_slot)
		}
	} else {
		for i := len(v.targets) - 1; i >= 0; i -= 1 {
			emit_op_byte(em, .Define_Global, u8(v.targets[i].declared_slot), line)
		}
	}
}

// -----------------------------------------------------------------------
// Functions

@(private = "file")
emit_function_declaration_stmt :: proc(em: ^Emitter, v: ^Stmt_Function_Decl) {
	line := v.token.line
	emit_function_decl(em, v.decl, lexeme(v.decl.name))
	if v.is_local {
		open_local_debug(em, lexeme(v.decl.name), v.declared_slot)
	} else {
		emit_op_byte(em, .Define_Global, u8(v.declared_slot), line)
	}
}

// -----------------------------------------------------------------------
// Control flow

@(private = "file")
emit_if :: proc(em: ^Emitter, v: ^Stmt_If) {
	line := v.token.line
	emit_expr(em, v.condition)
	then_jump := emit_jump(em, .Jump_If_False, line)
	emit_op(em, .Pop, line)
	emit_stmt(em, v.then_branch)
	else_jump := emit_jump(em, .Jump, line)

	patch_jump(em, then_jump, line)
	emit_op(em, .Pop, line)
	emit_stmt(em, v.else_branch)
	patch_jump(em, else_jump, line)
}

@(private = "file")
push_loop :: proc(em: ^Emitter) -> ^Loop {
	loop := new(Loop)
	loop.previous = em.current.loop
	em.current.loop = loop
	return loop
}

@(private = "file")
pop_loop :: proc(em: ^Emitter) {
	em.current.loop = em.current.loop.previous
}

@(private = "file")
emit_while :: proc(em: ^Emitter, v: ^Stmt_While) {
	line := v.token.line
	loop := push_loop(em)
	loop.start = len(current_chunk(em).code)

	emit_expr(em, v.condition)
	exit_jump := emit_jump(em, .Jump_If_False, line)
	emit_op(em, .Pop, line)
	emit_stmt(em, v.body)
	emit_loop(em, loop.start, line)

	patch_jump(em, exit_jump, line)
	emit_op(em, .Pop, line)
	for b in loop.breaks {
		patch_jump(em, b, line)
	}
	pop_loop(em)
}

// emit_for compiles the classic C-shaped `for init; cond; incr { body }`.
// The increment clause is emitted out of line and jumped over on the
// first pass, then run *after* the body via its own back-edge, with the
// loop's own back-edge retargeted to land on the increment instead of the
// condition -- same trick for_statement uses, now driven by already-
// resolved AST children instead of interleaved parsing.
@(private = "file")
emit_for :: proc(em: ^Emitter, v: ^Stmt_For) {
	line := v.token.line

	if v.init != nil {
		switch init in v.init {
		case ^Stmt_Var_Decl:
			emit_var_decl(em, init)
		case ^Stmt_Implicit_Assign:
			emit_implicit_assign(em, init)
		case ^Stmt_Expression:
			emit_expr(em, init.expr)
			emit_op(em, .Pop, init.token.line)
		}
	}

	loop := push_loop(em)
	loop.start = len(current_chunk(em).code)

	exit_jump := -1
	if v.condition != nil {
		emit_expr(em, v.condition)
		exit_jump = emit_jump(em, .Jump_If_False, line)
		emit_op(em, .Pop, line)
	}

	if v.increment != nil {
		body_jump := emit_jump(em, .Jump, line)
		increment_start := len(current_chunk(em).code)
		emit_expr(em, v.increment)
		emit_op(em, .Pop, line)
		emit_loop(em, loop.start, line)
		loop.start = increment_start
		patch_jump(em, body_jump, line)
	}

	emit_stmt(em, v.body)
	emit_loop(em, loop.start, line)

	if exit_jump != -1 {
		patch_jump(em, exit_jump, line)
		emit_op(em, .Pop, line)
	}
	for b in loop.breaks {
		patch_jump(em, b, line)
	}
	pop_loop(em)

	emit_local_exits(em, v.init_local_exits, line) // closes the init-variable's own outer scope
}

// emit_foreach reproduces the Foreach/Next/End_Foreach trio's exact
// operand layout -- see core/chunk.odin's Op_Code doc comment and
// foreach_statement's own inline notes; this bytecode shape is a fixed
// contract with the VM's foreach handler.
@(private = "file")
emit_foreach :: proc(em: ^Emitter, v: ^Stmt_Foreach) {
	line := v.token.line

	// var_slot's stack slot must exist before Op_Foreach/Op_Next ever
	// write into it -- it has no initializer expression of its own, so
	// without this explicit Nil push its slot would silently alias
	// whatever the iterable expression pushes instead.
	emit_op(em, .Nil, line)
	open_local_debug(em, lexeme(v.var_name), v.var_slot)

	emit_expr(em, v.iterable) // becomes __iter's initial value
	open_local_debug(em, "__iter", v.iter_slot)

	loop := push_loop(em)
	loop.is_foreach = true

	emit_op(em, .Foreach, line)
	emit_byte(em, u8(v.var_slot), line)
	emit_byte(em, u8(v.iter_slot), line)
	end_jump := len(current_chunk(em).code)
	emit_byte(em, 0xff, line)
	emit_byte(em, 0xff, line)

	loop.start = len(current_chunk(em).code)
	emit_stmt(em, v.body)

	for c in loop.continues {
		patch_jump(em, c, line)
	}

	// Op_Next operands: 2-byte back-jump, then var_slot and iter_slot --
	// "+4" rather than emit_loop's own "+2" since Op_Next has two more
	// trailing operand bytes still part of this same instruction's width.
	emit_op(em, .Next, line)
	back_offset := len(current_chunk(em).code) - loop.start + 4
	if back_offset > 0xffff {
		emit_error(em, line, "Loop body too large.")
	}
	emit_byte(em, u8((back_offset >> 8) & 0xff), line)
	emit_byte(em, u8(back_offset & 0xff), line)
	emit_byte(em, u8(v.var_slot), line)
	emit_byte(em, u8(v.iter_slot), line)

	emit_op(em, .End_Foreach, line)
	patch_jump(em, end_jump, line)
	for b in loop.breaks {
		patch_jump(em, b, line)
	}
	pop_loop(em)

	emit_local_exits(em, v.local_exits, line) // closes __iter and the loop variable's scope
}

// -----------------------------------------------------------------------
// break / continue / return
//
// crosses_tries cleanup runs after pop_exits -- see Stmt_Break/
// Stmt_Continue's doc comment in ast.odin.

@(private = "file")
emit_break :: proc(em: ^Emitter, v: ^Stmt_Break) {
	line := v.token.line
	emit_local_exits(em, v.pop_exits, line)
	emit_try_crossings(em, v.crosses_tries, v.local_count_at_crossing, -1, line)
	loop := em.current.loop
	append(&loop.breaks, emit_jump(em, .Jump, line))
}

@(private = "file")
emit_continue :: proc(em: ^Emitter, v: ^Stmt_Continue) {
	line := v.token.line
	emit_local_exits(em, v.pop_exits, line)
	emit_try_crossings(em, v.crosses_tries, v.local_count_at_crossing, -1, line)
	loop := em.current.loop
	if loop.is_foreach {
		append(&loop.continues, emit_jump(em, .Jump, line))
	} else {
		emit_loop(em, loop.start, line)
	}
}

// For a crossing return, the value expression's emission already leaves it
// at retval_slot's stack position (see resolve_return's doc comment).
// emit_try_crossings reloads it after each crossed try's finally replays;
// Op_Return trusts whatever's on top of the stack by then.
@(private = "file")
emit_return_stmt :: proc(em: ^Emitter, v: ^Stmt_Return) {
	line := v.token.line
	if v.value != nil {
		emit_expr(em, v.value)
	} else if em.current.fn_type == .Initializer {
		emit_op_byte(em, .Get_Local, 0, line) // implicit `return this`
	} else {
		emit_op(em, .Nil, line)
	}

	if len(v.crosses_tries) > 0 {
		emit_try_crossings(em, v.crosses_tries, v.local_count_at_crossing, v.retval_slot, line)
	}
	emit_op(em, .Return, line)
}

// emit_try_crossings emits Op_End_Try (unconditional, purely for its
// handler-popping side effect -- the 0,0 operand is a no-op offset, not a
// real jump) for each try in crosses_tries, plus that try's finally
// re-emitted inline if it has one, in order. retval_slot < 0 for break/
// continue (no value to reload); for a crossing return, each finally
// replay is followed by reloading it -- only needed when a finally replay
// actually disturbs the stack.
@(private = "file")
emit_try_crossings :: proc(em: ^Emitter, crosses_tries: []^Stmt_Try, local_count_at_crossing: int, retval_slot: int, line: int) {
	for try_node in crosses_tries {
		emit_op(em, .End_Try, line)
		emit_byte(em, 0, line)
		emit_byte(em, 0, line)
		if try_node.has_finally {
			emit_finally_copy(em, try_node, local_count_at_crossing)
			if retval_slot >= 0 {
				emit_op_byte(em, .Get_Local, u8(retval_slot), line)
			}
		}
	}
}

// -----------------------------------------------------------------------
// try / except / finally
// emit_finally_copy re-resolves finally_body immediately before emitting
// it rather than trusting previously-computed slot numbers -- a crossing
// return/break/continue inside this try's body or an except clause can
// overwrite finally_body's shared AST nodes with crossing-specific slots.

@(private = "file")
emit_finally_copy :: proc(em: ^Emitter, v: ^Stmt_Try, local_count: int) {
	line := v.token.line
	exits, had_error := resolve_finally_for_crossing(v, local_count)
	em.had_error = em.had_error || had_error
	emit_stmt_list(em, v.finally_body)
	emit_local_exits(em, exits, line)
}

@(private = "file")
emit_try :: proc(em: ^Emitter, v: ^Stmt_Try) {
	line := v.token.line
	try_jump := emit_jump(em, .Try, line)

	emit_stmt_list(em, v.body)
	emit_local_exits(em, v.body_local_exits, line)

	normal_end_jump := emit_jump(em, .End_Try, line)
	patch_jump(em, try_jump, line) // Op_Try's operand -> the first clause, patched once

	clause_exit_jumps: [dynamic]int
	for ex in v.excepts {
		ex_line := ex.type_name.line
		type_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(ex.type_name)))
		emit_op(em, .Except, ex_line)
		emit_byte(em, type_const, ex_line)
		// Except's own 2-byte skip offset makes it self-describing -- see
		// core/chunk.odin's Op_Code doc comment.
		skip_jump := len(current_chunk(em).code)
		emit_byte(em, 0xff, ex_line)
		emit_byte(em, 0xff, ex_line)

		if ex.has_binding {
			open_local_debug(em, lexeme(ex.binding), ex.binding_slot)
		}
		emit_stmt_list(em, ex.body)
		emit_local_exits(em, ex.local_exits, ex_line)

		append(&clause_exit_jumps, emit_jump(em, .Jump, ex_line))
		emit_op(em, .End_Except, ex_line)
		patch_jump(em, skip_jump, ex_line)
	}

	if v.has_finally {
		// Always-matching handler copy: re-raises whatever wasn't
		// otherwise handled once it finishes.
		emit_op(em, .Finally, line)
		emit_finally_copy(em, v, v.finally_ctx.entry_local_count)
		emit_op(em, .Raise, line)
	}

	// Shared normal-completion landing point.
	patch_jump(em, normal_end_jump, line)
	for j in clause_exit_jumps {
		patch_jump(em, j, line)
	}
	if v.has_finally {
		emit_finally_copy(em, v, v.finally_ctx.entry_local_count)
	}
}

// -----------------------------------------------------------------------
// Classes

@(private = "file")
emit_class_decl :: proc(em: ^Emitter, v: ^Stmt_Class_Decl) {
	line := v.token.line
	name_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(v.name)))
	field_slot_table_idx := core.chunk_add_field_slot_table(current_chunk(em), v.field_slot_names)
	emit_op_byte(em, .Class, name_const, line)
	emit_byte(em, field_slot_table_idx, line)

	if v.is_local {
		open_local_debug(em, lexeme(v.name), v.declared_slot)
	} else {
		emit_op_byte(em, .Define_Global, u8(v.declared_slot), line)
	}

	if v.has_superclass {
		emit_op_byte(em, get_op_for_ref(v.superclass_ref.kind), u8(v.superclass_ref.slot), line)
		emit_class_self_ref(em, v, line)
		emit_op(em, .Inherit, line)
		open_local_debug(em, "super", v.super_slot)
	}

	emit_class_self_ref(em, v, line) // class ref every member attaches to

	for member in v.members {
		switch m in member {
		case ^Method:
			emit_method(em, m, line)
		case ^Class_Var_Member:
			emit_class_var_member(em, m, line)
		}
	}

	emit_op(em, .Pop, line) // drop the class reference

	if v.has_superclass {
		exit := Local_Exit{slot = v.super_slot, is_captured = v.super_is_captured}
		emit_local_exits(em, []Local_Exit{exit}, line)
	}
}

// emit_class_self_ref re-reads the class's own just-declared name -- a
// plain local/global read, never an upvalue (nothing crosses a function
// boundary between declaring the class and a member attaching to it), so
// this derives directly from is_local/declared_slot rather than a full
// resolve_variable_rs-style search.
@(private = "file")
emit_class_self_ref :: proc(em: ^Emitter, v: ^Stmt_Class_Decl, line: int) {
	op := core.Op_Code.Get_Local if v.is_local else core.Op_Code.Get_Global
	emit_op_byte(em, op, u8(v.declared_slot), line)
}

@(private = "file")
emit_method :: proc(em: ^Emitter, m: ^Method, line: int) {
	name_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(m.name)))
	emit_function_decl(em, m.decl, lexeme(m.name))
	emit_op_byte(em, .Static_Method if m.is_static else .Method, name_const, line)
}

@(private = "file")
emit_class_var_member :: proc(em: ^Emitter, m: ^Class_Var_Member, line: int) {
	name_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(m.name)))
	if m.init != nil {
		emit_expr(em, m.init)
	} else {
		emit_op(em, .Nil, line)
	}
	emit_op_byte(em, .Class_Var, name_const, line)
}

// -----------------------------------------------------------------------
// Imports

@(private = "file")
emit_import :: proc(em: ^Emitter, v: ^Stmt_Import) {
	line := v.token.line
	for item in v.items {
		module_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(item.module)))
		alias_const := module_const
		if item.has_alias {
			alias_const = core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(item.alias)))
		}
		emit_op_byte(em, .Import, module_const, line)
		emit_byte(em, alias_const, line)
		// Op_Import defines the alias's global itself at runtime; the
		// compiler only needed the slot to exist (already assigned by
		// the Resolver), matching import_statement's own comment.
	}
}

@(private = "file")
emit_from_import :: proc(em: ^Emitter, v: ^Stmt_From_Import) {
	line := v.token.line
	module_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(v.module)))

	if v.wildcard {
		emit_op_byte(em, .Import_From, module_const, line)
		emit_byte(em, 0, line) // 0 = import everything the module exports
		return
	}

	name_consts: [dynamic]u8
	for n in v.names {
		append(&name_consts, core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(n.name))))
	}
	emit_op_byte(em, .Import_From, module_const, line)
	emit_byte(em, u8(len(name_consts)), line)
	for c in name_consts {
		emit_byte(em, c, line)
	}
}
