package compiler

import "../core"

// Declarations, statements, and control flow. See functions.odin for
// function/method body compilation (shared with expr.odin's lambda) and
// compiler_state.odin for the scope/local/loop/try bookkeeping this file
// drives.
//
// KNOWN SIMPLIFICATION vs. glox: this port's break/continue/return
// correctly *unwind exception handlers* when crossing an enclosing `try`
// (cross_tries, below -- so frame.Handlers, once the VM exists in Phase
// 4, never holds a stale entry for a try no longer lexically in scope),
// but does NOT re-run that try's `finally` block on the way out, unlike
// glox's full trampoline design (Try_Finally.pending/Trampoline_Site
// exist here, matching glox's compiler_state.odin shapes, but nothing
// currently populates `pending` or drains it). glox's own
// docs/exception-handling.md documents why that's a real, nontrivial
// design (deferred trampolines, `__retval` slot anchoring, replaying
// `finally` once per crossing exit path) -- implementing it blind, with
// no VM yet to validate against, risked a subtly wrong result that's
// hard to notice without exactly the kind of test coverage Phase 4 will
// finally make possible. Revisit this once the VM lands and the ported
// test suite can actually exercise `break`/`return` inside a
// `try ... finally` and catch a wrong answer.

// -----------------------------------------------------------------------
// Top-level dispatch

block :: proc(p: ^Parser) {
	for !check(p, .Right_Brace) && !check(p, .Eof) {
		declaration(p)
	}
	consume(p, .Right_Brace, "Expect '}' after block.")
}

declaration :: proc(p: ^Parser) {
	p.stmt_depth += 1
	defer p.stmt_depth -= 1
	if p.stmt_depth > MAX_STMT_DEPTH {
		error(p, "Statement nested too deeply.")
		for p.current.type != .Eof {
			advance(p)
		}
		return
	}

	#partial switch p.current.type {
	case .Var:
		advance(p)
		var_declaration(p)
	case .Const:
		advance(p)
		const_declaration(p)
	case .Func:
		advance(p)
		function_declaration(p)
	case .Class:
		advance(p)
		class_declaration(p)
	case .Import:
		advance(p)
		import_statement(p)
	case .From:
		advance(p)
		from_import_statement(p)
	case:
		statement(p)
	}

	if p.panic_mode {
		synchronize(p)
	}
}

statement :: proc(p: ^Parser) {
	#partial switch p.current.type {
	case .Print:
		advance(p)
		print_statement(p)
	case .If:
		advance(p)
		if_statement(p)
	case .While:
		advance(p)
		while_statement(p)
	case .For:
		advance(p)
		for_statement(p)
	case .Foreach:
		advance(p)
		foreach_statement(p)
	case .Return:
		advance(p)
		return_statement(p)
	case .Break:
		advance(p)
		break_statement(p)
	case .Continue:
		advance(p)
		continue_statement(p)
	case .Try:
		advance(p)
		try_except_statement(p)
	case .Raise:
		advance(p)
		raise_statement(p)
	case .Breakpoint:
		advance(p)
		emit_op(p, .Breakpoint)
		consume_eol(p, "Expect newline after 'breakpoint'.")
	case .Left_Brace:
		advance(p)
		begin_scope(p)
		block(p)
		end_scope(p)
	case .Semicolon, .Eol:
		advance(p) // empty statement
	case .Identifier:
		if check_next(p, .Equal) {
			advance(p)
			implicit_assignment_statement(p)
		} else if check_next(p, .Comma) && looks_like_destructuring(p) {
			advance(p)
			destructuring_assignment_statement(p)
		} else {
			expression_statement(p)
		}
	case:
		expression_statement(p)
	}
}

expression_statement :: proc(p: ^Parser) {
	expression(p)
	consume_eol(p, "Expect newline after expression.")
	emit_op(p, .Pop)
}

print_statement :: proc(p: ^Parser) {
	expression(p)
	consume_eol(p, "Expect newline after value.")
	emit_op(p, .Print)
}

raise_statement :: proc(p: ^Parser) {
	expression(p)
	consume_eol(p, "Expect newline after 'raise' expression.")
	emit_op(p, .Raise)
}

// -----------------------------------------------------------------------
// var / const / implicit / destructuring declarations

var_declaration :: proc(p: ^Parser) {
	consume(p, .Identifier, "Expect variable name.")
	name_tok := p.previous
	if match(p, .Equal) {
		expression(p)
	} else {
		emit_op(p, .Nil)
	}
	finish_declare(p, name_tok, false)
	consume_eol(p, "Expect newline after variable declaration.")
}

const_declaration :: proc(p: ^Parser) {
	consume(p, .Identifier, "Expect variable name.")
	name_tok := p.previous
	consume(p, .Equal, "Const variable must have an initializer.")
	expression(p)
	finish_declare(p, name_tok, true)
	consume_eol(p, "Expect newline after const declaration.")
}

// finish_declare handles the local-vs-global split every declaration
// form shares: a local needs no explicit store (the value the
// initializer left on the stack top *is* the local, by stack-position
// construction -- see add_local); a global needs an explicit Define
// opcode to both create the slot's value and mark it "defined" (so
// Op_Code.Get_Global can distinguish "never assigned" from "assigned nil").
@(private = "file")
finish_declare :: proc(p: ^Parser, name_tok: Token, is_const: bool) {
	c := p.current_compiler
	if c.scope_depth > 0 {
		add_local(p, name_tok)
		mark_initialised(p)
		if is_const {
			mark_local_const(p)
		}
		return
	}
	name := lexeme(name_tok)
	slot := global_slot(p, name)
	mark_global_declared(p, name)
	emit_op_byte(p, .Define_Global_Const if is_const else .Define_Global, u8(slot))
}

// implicit_assignment_statement handles bare `x = expr` at statement
// level for a name that isn't already a known local: it creates the
// binding (a new local inside a function, a new-or-existing global at
// top level) rather than erroring "undefined variable" the way a plain
// expression-statement assignment would. p.previous is the identifier,
// already consumed by statement()'s dispatch.
@(private = "file")
implicit_assignment_statement :: proc(p: ^Parser) {
	name_tok := p.previous
	name := lexeme(name_tok)
	c := p.current_compiler
	existing_local := resolve_local(p, c, name_tok)
	// Checked *before* consuming '=' or compiling the RHS: an
	// already-declared global named `total`, reassigned from inside a
	// nested scope (`for ... { total = total + 1 }`), must resolve as
	// an ordinary Set_Global -- not fall into the "not a local here, so
	// declare a new local" branch below, which would spawn a local that
	// *shadows* the global starting mid-statement, and whose own RHS
	// (`total + 1`) would then see that fresh, not-yet-initialised
	// local instead of the outer global it was actually meant to read.
	already_global := is_global_declared(p, name)

	consume(p, .Equal, "Expect '=' in assignment.")

	if existing_local != -1 {
		// Set_Local (like every Set_* opcode -- see expr.odin's
		// named_variable) leaves the assigned value on the stack, so
		// assignment can chain as an expression (`x = y = 1`). Used
		// here as a full statement, so that value needs discarding --
		// unlike the "new local"/global-define branches below, whose
		// value *becomes* the freshly-created binding itself and is
		// never a leftover to pop.
		expression(p)
		emit_op_byte(p, .Set_Local, u8(existing_local))
		emit_op(p, .Pop)
	} else if already_global {
		slot := global_slot(p, name)
		expression(p)
		emit_op_byte(p, .Set_Global, u8(slot))
		emit_op(p, .Pop) // Set_Global leaves a value too, same reasoning as Set_Local above
	} else if c.scope_depth > 0 {
		add_local(p, name_tok)
		expression(p)
		mark_initialised(p)
	} else {
		slot := global_slot(p, name)
		mark_global_declared(p, name)
		expression(p)
		emit_op_byte(p, .Define_Global, u8(slot))
	}
	consume_eol(p, "Expect newline after assignment.")
}

// looks_like_destructuring probes ahead (using snapshot/restore, see
// parser.odin) for `identifier (, identifier)* =` before committing to
// parsing this statement as a destructuring assignment -- otherwise
// falls through to an ordinary expression statement, so a name merely
// followed by a comma in some other context isn't misread.
@(private = "file")
looks_like_destructuring :: proc(p: ^Parser) -> bool {
	snap := snapshot_pos(p)
	defer restore_pos(p, snap)

	if !check(p, .Identifier) {
		return false
	}
	advance(p)
	for check(p, .Comma) {
		advance(p)
		if !check(p, .Identifier) {
			return false
		}
		advance(p)
	}
	return check(p, .Equal)
}

destructuring_assignment_statement :: proc(p: ^Parser) {
	names: [dynamic]Token
	append(&names, p.previous) // first identifier, already consumed
	for match(p, .Comma) {
		consume(p, .Identifier, "Expect variable name.")
		append(&names, p.previous)
	}
	consume(p, .Equal, "Expect '=' after destructuring targets.")

	// The right-hand side is a comma-separated expression list too --
	// `a, b = 1, 2` unpacks the literal pair, not just `1` followed by a
	// syntax error at the comma. A single expression (`a, b = f()`) is
	// unaffected: rhs_count stays 1, and Op_Unpack operates directly on
	// whatever that one expression evaluates to.
	expression(p)
	rhs_count := 1
	for match(p, .Comma) {
		expression(p)
		rhs_count += 1
	}
	if rhs_count > 1 {
		if rhs_count > 255 {
			error(p, "Too many values on the right-hand side of a destructuring assignment.")
		}
		emit_op_byte(p, .Create_Tuple, u8(rhs_count))
	}

	if len(names) > 255 {
		error(p, "Too many destructuring targets.")
	}
	emit_op_byte(p, .Unpack, u8(len(names)))

	c := p.current_compiler
	if c.scope_depth > 0 {
		// Op_Unpack already pushed the values in order -- for fresh
		// locals that's already their correct slot layout, same
		// reasoning as any other local declaration.
		for name in names {
			add_local(p, name)
			mark_initialised(p)
		}
	} else {
		slots := make([dynamic]int, 0, len(names))
		for name in names {
			n := lexeme(name)
			append(&slots, global_slot(p, n))
			mark_global_declared(p, n)
		}
		// Define_Global pops exactly one value each, so the pops must
		// run in the reverse of push order to match what Op_Unpack left
		// on the stack.
		for i := len(slots) - 1; i >= 0; i -= 1 {
			emit_op_byte(p, .Define_Global, u8(slots[i]))
		}
	}
	consume_eol(p, "Expect newline after destructuring assignment.")
}

// -----------------------------------------------------------------------
// Functions

function_declaration :: proc(p: ^Parser) {
	consume(p, .Identifier, "Expect function name.")
	name_tok := p.previous
	name := lexeme(name_tok)
	is_local := p.current_compiler.scope_depth > 0

	slot := 0
	if is_local {
		// Declared (and marked initialised) *before* the body compiles,
		// same as glox/clox -- so the function can call itself by name
		// for recursion.
		declare_variable(p)
		mark_initialised(p)
	} else {
		slot = global_slot(p, name)
		mark_global_declared(p, name)
	}

	init_function_compiler(p, .Function, name)
	compile_function(p) // pops back to this (enclosing) compiler; emits Op_Code.Closure here

	if !is_local {
		emit_op_byte(p, .Define_Global, u8(slot))
	}
}

// -----------------------------------------------------------------------
// Control flow

if_statement :: proc(p: ^Parser) {
	expression(p)
	consume(p, .Left_Brace, "Expect '{' after if condition.")

	then_jump := emit_jump(p, .Jump_If_False)
	emit_op(p, .Pop)
	begin_scope(p)
	block(p)
	end_scope(p)

	else_jump := emit_jump(p, .Jump)
	patch_jump(p, then_jump)
	emit_op(p, .Pop)

	if match(p, .Else) {
		if match(p, .If) {
			if_statement(p)
		} else {
			consume(p, .Left_Brace, "Expect '{' after 'else'.")
			begin_scope(p)
			block(p)
			end_scope(p)
		}
	}
	patch_jump(p, else_jump)
}

while_statement :: proc(p: ^Parser) {
	loop := push_loop(p)
	loop.start = len(current_chunk(p).code)

	expression(p)
	consume(p, .Left_Brace, "Expect '{' after while condition.")

	exit_jump := emit_jump(p, .Jump_If_False)
	emit_op(p, .Pop)
	begin_scope(p)
	block(p)
	end_scope(p)
	emit_loop(p, loop.start)

	patch_jump(p, exit_jump)
	emit_op(p, .Pop)
	for b in loop.breaks {
		patch_jump(p, b)
	}

	pop_loop(p)
}

// for_statement compiles the classic C-shaped `for init; cond; incr {
// body }`. The increment clause is compiled out of line and jumped over
// on the first pass, then run *after* the body via its own back-edge,
// with the loop's own back-edge retargeted to land on the increment
// instead of the condition -- the standard trick that turns "run
// increment before re-checking condition" into code that reads in
// natural source order without a special third jump kind.
for_statement :: proc(p: ^Parser) {
	begin_scope(p) // owns the init-variable's scope, if any

	loop := push_loop(p)

	if match(p, .Semicolon) {
		// no initializer
	} else if match(p, .Var) {
		consume(p, .Identifier, "Expect variable name.")
		name_tok := p.previous
		if match(p, .Equal) {
			expression(p)
		} else {
			emit_op(p, .Nil)
		}
		finish_declare(p, name_tok, false)
		consume(p, .Semicolon, "Expect ';' after loop initializer.")
	} else {
		expression(p)
		emit_op(p, .Pop)
		consume(p, .Semicolon, "Expect ';' after loop initializer.")
	}

	loop.start = len(current_chunk(p).code)
	exit_jump := -1
	if !check(p, .Semicolon) {
		expression(p)
		exit_jump = emit_jump(p, .Jump_If_False)
		emit_op(p, .Pop)
	}
	consume(p, .Semicolon, "Expect ';' after loop condition.")

	if !check(p, .Left_Brace) {
		body_jump := emit_jump(p, .Jump)
		increment_start := len(current_chunk(p).code)
		expression(p)
		emit_op(p, .Pop)
		emit_loop(p, loop.start)
		loop.start = increment_start
		patch_jump(p, body_jump)
	}

	consume(p, .Left_Brace, "Expect '{' before for body.")
	begin_scope(p)
	block(p)
	end_scope(p)
	emit_loop(p, loop.start)

	if exit_jump != -1 {
		patch_jump(p, exit_jump)
		emit_op(p, .Pop)
	}
	for b in loop.breaks {
		patch_jump(p, b)
	}

	pop_loop(p)
	end_scope(p)
}

// foreach_statement: `foreach x in iterable { body }`. Reserves two
// hidden locals -- the visible loop variable and `__iter`, which holds
// the iterable/iterator across iterations -- then emits the
// Foreach/Next/End_Foreach trio. See core/chunk.odin's Op_Code doc
// comment and the operand-layout notes inline below; both this compiler
// and the VM that reads this bytecode (Phase 4) are implemented by this
// port, so the exact encoding is this port's own choice as long as it's
// internally consistent, which these two emission sites (here and
// Phase 4's foreach handler) need to agree on.
foreach_statement :: proc(p: ^Parser) {
	begin_scope(p)
	consume(p, .Identifier, "Expect loop variable name.")
	add_local(p, p.previous)
	mark_initialised(p)
	var_slot := u8(p.current_compiler.local_count - 1)

	consume(p, .In, "Expect 'in' after foreach variable.")
	expression(p) // the iterable -- becomes __iter's initial value

	add_local(p, synthetic_token(.Identifier, "__iter", p.previous.line))
	mark_initialised(p)
	iter_slot := u8(p.current_compiler.local_count - 1)

	consume(p, .Left_Brace, "Expect '{' before foreach body.")

	loop := push_loop(p)
	loop.is_foreach = true

	// Op_Foreach operands: 1-byte var_slot, 1-byte iter_slot, 2-byte
	// forward jump (taken once the iterable is exhausted -- patched
	// below, once End_Foreach's position is known).
	emit_op(p, .Foreach)
	emit_byte(p, var_slot)
	emit_byte(p, iter_slot)
	end_jump := len(current_chunk(p).code)
	emit_byte(p, 0xff)
	emit_byte(p, 0xff)

	loop.start = len(current_chunk(p).code)
	begin_scope(p)
	block(p)
	end_scope(p)

	for c in loop.continues {
		patch_jump(p, c)
	}

	// Op_Next operands: 2-byte back-jump (to loop.start, taken when
	// another value is available), then 1-byte iter_slot -- computed the
	// same way emit_loop computes its own back-jump, but "+3" rather
	// than "+2" since Op_Next has one more trailing operand byte
	// (iter_slot) after the jump pair that's still part of this same
	// instruction's total width.
	emit_op(p, .Next)
	back_offset := len(current_chunk(p).code) - loop.start + 3
	if back_offset > 0xffff {
		error(p, "Loop body too large.")
	}
	emit_byte(p, u8((back_offset >> 8) & 0xff))
	emit_byte(p, u8(back_offset & 0xff))
	emit_byte(p, iter_slot)

	emit_op(p, .End_Foreach)
	patch_jump(p, end_jump)
	for b in loop.breaks {
		patch_jump(p, b)
	}

	pop_loop(p)
	end_scope(p) // closes __iter and the loop variable's scope
}

@(private = "file")
push_loop :: proc(p: ^Parser) -> ^Loop {
	loop := new(Loop)
	loop.previous = p.current_compiler.loop
	loop.scope_depth = p.current_compiler.scope_depth
	p.current_compiler.loop = loop
	return loop
}

@(private = "file")
pop_loop :: proc(p: ^Parser) {
	p.current_compiler.loop = p.current_compiler.loop.previous
}

// -----------------------------------------------------------------------
// break / continue / return

break_statement :: proc(p: ^Parser) {
	loop := p.current_compiler.loop
	if loop == nil {
		error(p, "Can't use 'break' outside of a loop.")
		return
	}
	pop_locals_above(p, loop.scope_depth)
	cross_tries(p, loop.scope_depth)
	append(&loop.breaks, emit_jump(p, .Jump))
	consume_eol(p, "Expect newline after 'break'.")
}

continue_statement :: proc(p: ^Parser) {
	loop := p.current_compiler.loop
	if loop == nil {
		error(p, "Can't use 'continue' outside of a loop.")
		return
	}
	pop_locals_above(p, loop.scope_depth)
	cross_tries(p, loop.scope_depth)
	if loop.is_foreach {
		// A foreach's "increment" is Op_Next itself, which sits *after*
		// the body -- so continue forward-jumps to just before it,
		// rather than back-jumping to the top the way a while/for loop's
		// continue does.
		append(&loop.continues, emit_jump(p, .Jump))
	} else {
		emit_loop(p, loop.start)
	}
	consume_eol(p, "Expect newline after 'continue'.")
}

return_statement :: proc(p: ^Parser) {
	if p.current_compiler.type == .Script {
		error(p, "Can't return from top-level code.")
	}

	if check(p, .Eol) || check(p, .Eof) || check(p, .Semicolon) {
		if p.current_compiler.type == .Initializer {
			emit_op_byte(p, .Get_Local, 0) // implicit `return this`
		} else {
			emit_op(p, .Nil)
		}
	} else {
		if p.current_compiler.type == .Initializer {
			error(p, "Can't return a value from an initializer.")
		}
		expression(p)
	}
	consume_eol(p, "Expect newline after return value.")

	cross_tries(p, 0) // return always crosses every try still open in this function
	emit_op(p, .Return)
}

@(private = "file")
pop_locals_above :: proc(p: ^Parser, target_depth: int) {
	c := p.current_compiler
	for i := c.local_count - 1; i >= 0 && c.locals[i].depth > target_depth; i -= 1 {
		if c.locals[i].is_captured {
			emit_op(p, .Close_Upvalue)
		} else {
			emit_op(p, .Pop)
		}
	}
}

// cross_tries pops (Op_End_Try, a no-op-offset variant used purely for
// its handler-popping side effect) every try context entered at or
// after target_scope_depth -- see this file's header comment for what
// this does and doesn't do (handlers are correctly unwound; `finally`
// is not replayed).
@(private = "file")
cross_tries :: proc(p: ^Parser, target_scope_depth: int) {
	for t := p.current_compiler.tries; t != nil && t.scope_depth_at_entry >= target_scope_depth; t = t.previous {
		emit_op(p, .End_Try)
		emit_byte(p, 0)
		emit_byte(p, 0)
	}
}

// -----------------------------------------------------------------------
// try / except / finally
//
// Bytecode shape and the two invariants that matter most (End_Except
// must be immediately followed by the next clause's Except/Finally;
// Try's operand is patched exactly once, to the first clause) are
// documented in full in glox's docs/exception-handling.md -- read that
// before changing this code. Summary of what's below: `finally`'s
// source is compiled twice via snapshot/restore (see parser.odin) --
// once right after Op_Finally (the always-matching handler, followed by
// Op_Raise to propagate whatever wasn't otherwise handled) and once at
// the shared normal-completion landing point every non-exceptional exit
// (End_Try, each clause's own fallthrough) jumps to.

try_except_statement :: proc(p: ^Parser) {
	try_ctx := new(Try_Finally)
	try_ctx.scope_depth_at_entry = p.current_compiler.scope_depth
	try_ctx.previous = p.current_compiler.tries
	p.current_compiler.tries = try_ctx

	try_jump := emit_jump(p, .Try)

	consume(p, .Left_Brace, "Expect '{' after 'try'.")
	begin_scope(p)
	block(p)
	end_scope(p)

	normal_end_jump := emit_jump(p, .End_Try)
	patch_jump(p, try_jump) // Op_Try's operand -> the first clause, patched once

	clause_exit_jumps: [dynamic]int
	saw_except := false

	for check(p, .Except) {
		saw_except = true
		advance(p)
		consume(p, .Identifier, "Expect exception type name.")
		type_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(lexeme(p.previous)))
		emit_op_byte(p, .Except, type_const)

		begin_scope(p)
		if match(p, .As) {
			consume(p, .Identifier, "Expect exception binding name.")
			add_local(p, p.previous)
			mark_initialised(p)
		}
		consume(p, .Left_Brace, "Expect '{' after except clause.")
		block(p)
		end_scope(p)

		append(&clause_exit_jumps, emit_jump(p, .Jump))
		emit_op(p, .End_Except) // must be immediately followed by Except/Finally -- see docs/exception-handling.md
	}

	if !saw_except && !check(p, .Finally) {
		error(p, "Expect 'except' or 'finally' after try block.")
	}

	has_finally := match(p, .Finally)
	try_ctx.has_finally = has_finally

	if has_finally {
		consume(p, .Left_Brace, "Expect '{' after 'finally'.")
		try_ctx.finally_snapshot = snapshot_pos(p)

		emit_op(p, .Finally)
		begin_scope(p)
		block(p)
		end_scope(p)
		emit_op(p, .Raise) // nothing else handled it -- propagate
	}

	// Shared normal-completion landing point <A>.
	patch_jump(p, normal_end_jump)
	for j in clause_exit_jumps {
		patch_jump(p, j)
	}
	if has_finally {
		restore_pos(p, try_ctx.finally_snapshot)
		begin_scope(p)
		block(p)
		end_scope(p)
		// This replay re-parses the exact same token range the first
		// copy did, so it naturally advances back to the same closing
		// `}` and beyond -- no further position fixup needed.
	}

	p.current_compiler.tries = try_ctx.previous
}

// -----------------------------------------------------------------------
// Classes

class_declaration :: proc(p: ^Parser) {
	consume(p, .Identifier, "Expect class name.")
	name_tok := p.previous
	class_name := lexeme(name_tok)
	name_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(class_name))

	is_local := p.current_compiler.scope_depth > 0
	slot := 0
	if is_local {
		declare_variable(p)
		mark_initialised(p)
	} else {
		slot = global_slot(p, class_name)
		mark_global_declared(p, class_name)
	}

	emit_op_byte(p, .Class, name_const)
	if !is_local {
		emit_op_byte(p, .Define_Global, u8(slot))
	}

	class_ctx := new(Class_Compiler)
	class_ctx.enclosing = p.current_class
	p.current_class = class_ctx

	if match(p, .Less) {
		consume(p, .Identifier, "Expect superclass name.")
		if lexeme(p.previous) == class_name {
			error(p, "A class can't inherit from itself.")
		}
		named_variable(p, p.previous, false)

		begin_scope(p)
		add_local(p, synthetic_token(.Identifier, "super", p.previous.line))
		mark_initialised(p)

		named_variable(p, name_tok, false)
		emit_op(p, .Inherit)
		class_ctx.has_superclass = true
	}

	named_variable(p, name_tok, false) // class ref that Method/Static_Method/Class_Var attach to
	consume(p, .Left_Brace, "Expect '{' before class body.")
	for !check(p, .Right_Brace) && !check(p, .Eof) {
		// Unlike top-level declaration()/statement(), which both fold
		// this into their own dispatch, method() has no branch for a
		// bare separator -- and there legitimately is an Eol between
		// two methods (the one right after the first method's own `}`
		// is real: Right_Brace isn't in keep_eol's suppress-after set,
		// and the next real token is an identifier, not a closer, so
		// it isn't suppressed by the look-ahead rule either). Skipping
		// it here, rather than teaching method() to expect it, keeps
		// method() focused on "one member" and matches how blank lines
		// between members are already tolerated the same way.
		if match(p, .Eol) || match(p, .Semicolon) {
			continue
		}
		method(p)
	}
	consume(p, .Right_Brace, "Expect '}' after class body.")
	emit_op(p, .Pop) // drop the class reference

	if class_ctx.has_superclass {
		end_scope(p) // closes the synthetic `super` local
	}

	p.current_class = class_ctx.enclosing
}

@(private = "file")
method :: proc(p: ^Parser) {
	is_static := match(p, .Static)

	consume(p, .Identifier, "Expect method or field name.")
	name := lexeme(p.previous)
	name_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(name))

	if !check(p, .Left_Paren) {
		if !is_static {
			error(p, "Expect '(' after method name.")
			return
		}
		if match(p, .Equal) {
			expression(p)
		} else {
			emit_op(p, .Nil)
		}
		consume_eol(p, "Expect newline after class variable.")
		emit_op_byte(p, .Class_Var, name_const)
		return
	}

	if is_static && name == "init" {
		error(p, "'init' cannot be static.")
	}
	type := Function_Type.Initializer if name == "init" else Function_Type.Method

	init_function_compiler(p, type, name)
	compile_function(p)

	emit_op_byte(p, .Static_Method if is_static else .Method, name_const)
}

// -----------------------------------------------------------------------
// Imports

import_statement :: proc(p: ^Parser) {
	for {
		consume(p, .Identifier, "Expect module name.")
		module_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(lexeme(p.previous)))
		alias := lexeme(p.previous)
		alias_const := module_const

		if match(p, .As) {
			consume(p, .Identifier, "Expect alias after 'as'.")
			alias = lexeme(p.previous)
			alias_const = core.chunk_add_constant(current_chunk(p), core.make_string_value(alias))
		}

		emit_op_byte(p, .Import, module_const)
		emit_byte(p, alias_const)

		// Op_Import defines the alias's global itself at runtime (Phase
		// 4); the compiler only needs the slot to exist so later code
		// in this compilation unit (and, for the REPL, later lines) can
		// resolve the name.
		global_slot(p, alias)
		mark_global_declared(p, alias)

		if !match(p, .Comma) {
			break
		}
	}
	consume_eol(p, "Expect newline after import.")
}

from_import_statement :: proc(p: ^Parser) {
	consume(p, .Identifier, "Expect module name.")
	module_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(lexeme(p.previous)))
	consume(p, .Import, "Expect 'import' after module name.")

	if match(p, .Star) {
		emit_op_byte(p, .Import_From, module_const)
		emit_byte(p, 0) // 0 = import everything the module exports
		consume_eol(p, "Expect newline after import.")
		return
	}

	name_consts: [dynamic]u8
	for {
		consume(p, .Identifier, "Expect imported name.")
		name := lexeme(p.previous)
		append(&name_consts, core.chunk_add_constant(current_chunk(p), core.make_string_value(name)))
		global_slot(p, name)
		mark_global_declared(p, name)
		if !match(p, .Comma) {
			break
		}
	}
	if len(name_consts) > 255 {
		error(p, "Too many imported names.")
	}
	emit_op_byte(p, .Import_From, module_const)
	emit_byte(p, u8(len(name_consts)))
	for c in name_consts {
		emit_byte(p, c)
	}
	consume_eol(p, "Expect newline after import.")
}
