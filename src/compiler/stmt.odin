package compiler

import "../core"
import "core:fmt"

// Declarations, statements, and control flow. See functions.odin for
// function/method body compilation (shared with expr.odin's lambda) and
// compiler_state.odin for the scope/local/loop/try bookkeeping this file
// drives.
//
// break/continue/return crossing an enclosing `try` correctly *unwind
// exception handlers* (cross_tries, below -- so frame.handlers never
// holds a stale entry for a try no longer lexically in scope) AND
// replay that try's `finally` block on the way out, via the same
// deferred-trampoline design glox's own docs/exception-handling.md
// documents in full (read that before touching any of this): `finally`
// is parsed *last*, so a return/break/continue written inside the try
// body can't yet know whether cleanup code needs to run first -- it
// defers into Try_Finally.pending (a Trampoline_Site) instead of
// emitting its terminal instruction immediately, and
// try_except_statement resolves every pending site (compile_pending_
// trampolines) once it learns whether a finally exists. This was left
// unimplemented through Phase 4 deliberately (the doc comment here used
// to say so) since implementing it blind, with no VM yet to validate
// against, risked a subtly wrong result hard to notice without real test
// coverage -- the ported test suite's finally_return.lox/
// finally_break_continue.lox/finally_nested.lox fixtures are exactly
// that coverage, and drove this implementation.

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
	// Op_Str first, matching glox's own printStatement exactly -- not
	// just for the generic string conversion (display_string's job in
	// run.odin's Op_Print handler already covers that on its own) but
	// because Op_Str is also the toString() dispatch point (see
	// run.odin's Op_Str case). Missing this meant `print instance`
	// always showed the generic "<instance ClassName>" form even when
	// the class defined its own toString() -- found immediately after
	// wiring toString dispatch up in Op_Str itself: `str(x)` (which
	// compiles straight to Op_Str, see expr.odin's str_call) picked up
	// the new dispatch correctly, but `print x` on the exact same
	// instance still didn't, because it never went through Op_Str at
	// all before this fix.
	emit_op(p, .Str)
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
	implicit_assignment_core(p)
	consume_eol(p, "Expect newline after assignment.")
}

// implicit_assignment_core is implicit_assignment_statement's body minus
// the trailing terminator, shared with for_statement's own bare
// (non-`var`) init clause -- `for (i = 0; ...)` needs this exact same
// "first mention creates a binding rather than emitting a Set_Global
// against a slot nothing ever Defined" semantics, but ends in `;` rather
// than an Eol/newline, so it can't call implicit_assignment_statement
// directly. Real bug, found via break_unbraced.lox: for_statement's own
// init-clause "else" branch called plain expression(p) unconditionally,
// which routes `i = 0` through expr.odin's named_variable -- a bare
// Set_Global with no preceding Define_Global, since global_slot alone
// doesn't mark a slot defined -- and failed at runtime with "Undefined
// variable 'i'." on the very first iteration.
@(private = "file")
implicit_assignment_core :: proc(p: ^Parser) {
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
	// Same reasoning again, one tier further out: a name captured from
	// an *enclosing* function (`n = n + 1` inside a closure returned by
	// make_counter()) is an upvalue, not a local of *this* function --
	// resolve_local alone can't see it (only resolve_upvalue walks the
	// enclosing-compiler chain). Checked only when existing_local
	// missed, since resolve_upvalue would otherwise needlessly capture
	// a same-named outer variable that a local of this scope already
	// shadows.
	existing_upvalue := -1
	if existing_local == -1 {
		existing_upvalue = resolve_upvalue(p, c, name_tok)
	}

	consume(p, .Equal, "Expect '=' in assignment.")

	if existing_local != -1 {
		// Set_Local (like every Set_* opcode -- see expr.odin's
		// named_variable) leaves the assigned value on the stack, so
		// assignment can chain as an expression (`x = y = 1`). Used
		// here as a full statement, so that value needs discarding --
		// unlike the "new local"/global-define branches below, whose
		// value *becomes* the freshly-created binding itself and is
		// never a leftover to pop.
		// const check: expr.odin's named_variable (the Pratt-parser path
		// for `x = 1` used as a sub-expression) already rejects const
		// locals, but bare `x = 1` as a full statement is dispatched here
		// instead (see statement()'s .Identifier case) and skipped that
		// check entirely -- `const a = 5` followed by a statement-level
		// `a = 6` silently reassigned it (returned 6, no error) until this
		// fix, since this branch went straight to Set_Local with no
		// is_const test of its own.
		if c.locals[existing_local].is_const {
			error(p, fmt.tprintf("Cannot assign to const '%s'.", name))
		}
		expression(p)
		emit_op_byte(p, .Set_Local, u8(existing_local))
		emit_op(p, .Pop)
	} else if existing_upvalue != -1 {
		expression(p)
		emit_op_byte(p, .Set_Upvalue, u8(existing_upvalue))
		emit_op(p, .Pop) // Set_Upvalue leaves a value too, same reasoning as Set_Local above
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
	parse_condition(p)

	then_jump := emit_jump(p, .Jump_If_False)
	emit_op(p, .Pop)
	// statement(p), not a hardcoded block: a braced `{ ... }` body still
	// goes through statement()'s own .Left_Brace case (identical
	// begin_scope/block/end_scope to what used to be inlined here), but
	// this also accepts a bare unbraced single statement -- needed for
	// `if (cond) break`/`if (n < 2) return n` in the ported test suite,
	// which previously couldn't even compile (Expect '{' after if
	// condition). See parse_condition's own doc comment for why the
	// parens themselves are optional rather than made mandatory to
	// match glox exactly.
	// The match(p, .Eol) immediately before each statement(p) call below
	// is load-bearing, not cosmetic: statement()'s own dispatch has a
	// `case .Semicolon, .Eol: advance(p)` "empty statement" case, so
	// without skipping a stray Eol here first, `if (cond)\n{ body }`
	// would have that Eol consumed AS the entire then/else body (a
	// silent no-op), leaving `{ body }` to be parsed afterward as a
	// completely separate, unconditional statement -- the block would
	// run regardless of cond, with no compile error. Confirmed by direct
	// repro: `if (false)\n{ print "x" }` printed "x" anyway before this
	// fix. Same reasoning applies to while/foreach's body below.
	match(p, .Eol)
	statement(p)

	else_jump := emit_jump(p, .Jump)
	patch_jump(p, then_jump)
	emit_op(p, .Pop)

	// `else if` falls out for free: statement()'s own dispatch has a
	// .If case that calls back into if_statement, so no special-casing
	// is needed here the way the old brace-only version needed one.
	if match(p, .Else) {
		match(p, .Eol)
		statement(p)
	}
	patch_jump(p, else_jump)
}

// parse_condition compiles a control-flow header's condition
// expression, tolerating an optional wrapping `(...)`. glox's own
// grammar requires the parens unconditionally (`p.consume(TOKEN_LEFT_PAREN,
// "Expect '(' after if.")`, no bare form at all) -- this port initially
// accepted only the bare form, which meant every `if (cond)`/`while (cond)`
// fixture in the ported test suite failed to compile. Made optional
// rather than mandatory specifically to stay backward compatible with
// the bare style this compiler's own test suite (compile_test.odin,
// vm_test.odin) and every hand-written example already use -- flipping
// to "mandatory" would have matched glox exactly but broken everything
// already passing for no real benefit.
@(private = "file")
parse_condition :: proc(p: ^Parser) {
	has_paren := match(p, .Left_Paren)
	expression(p)
	if has_paren {
		consume(p, .Right_Paren, "Expect ')' after condition.")
	}
}

while_statement :: proc(p: ^Parser) {
	loop := push_loop(p)
	loop.start = len(current_chunk(p).code)

	parse_condition(p)

	exit_jump := emit_jump(p, .Jump_If_False)
	emit_op(p, .Pop)
	match(p, .Eol) // see if_statement's doc comment: same Eol-before-body hazard
	statement(p)
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
// has_paren tracks whether `(` was seen so the matching `)` can be
// required/consumed at the right spot -- optional, not mandatory (see
// parse_condition's doc comment for why), which for `for` specifically
// means the body is *not* extended to accept a bare unbraced statement
// the way if/while/foreach's bodies now do: without parens, there's no
// unambiguous way to tell where an omittable increment clause ends and
// an unbraced body begins (glox's own grammar sidesteps this by making
// the parens -- and therefore the closing `)` as an unambiguous
// delimiter -- mandatory). No fixture in the ported test suite needs
// an unbraced `for` body, so this keeps the existing brace-required
// body exactly as it was and only adds the optional paren wrapping
// around the header.
for_statement :: proc(p: ^Parser) {
	begin_scope(p) // owns the init-variable's scope, if any

	loop := push_loop(p)

	has_paren := match(p, .Left_Paren)

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
	} else if check(p, .Identifier) && check_next(p, .Equal) {
		// Bare `i = 0` (no `var`) as the init clause -- same
		// first-mention-creates-a-binding handling statement()'s own
		// .Identifier dispatch case gives this at ordinary statement
		// level (implicit_assignment_core's own doc comment has the
		// full story on why plain expression(p) below isn't enough).
		advance(p)
		implicit_assignment_core(p)
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

	// The increment clause is present unless the next token closes the
	// header: `)` if parens were opened, `{` (the body) otherwise.
	has_increment := !check(p, .Right_Paren) if has_paren else !check(p, .Left_Brace)
	if has_increment {
		body_jump := emit_jump(p, .Jump)
		increment_start := len(current_chunk(p).code)
		expression(p)
		emit_op(p, .Pop)
		emit_loop(p, loop.start)
		loop.start = increment_start
		patch_jump(p, body_jump)
	}

	if has_paren {
		consume(p, .Right_Paren, "Expect ')' after for clauses.")
	}
	// `for (...)\n{` -- same Eol-before-brace tolerance as if/while/foreach
	// and every clause boundary in try/except/finally. Found via
	// closure_list.lox, which places the body's `{` on the line after a
	// parenthesized for-header; this proc's own doc comment previously
	// (wrongly) claimed no fixture in the suite needed this.
	match(p, .Eol)
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

// foreach_statement: `foreach [(]  [var]  x in iterable  [)]  body`. The
// parens and the `var` keyword are both optional (see parse_condition's
// doc comment on if_statement for why odlox makes glox's mandatory
// parens optional instead); body goes through statement(p) so both a
// `{ block }` and a bare single statement work. Reserves two hidden
// locals -- the visible loop variable and `__iter`, which holds the
// iterable/iterator across iterations -- then emits the Foreach/Next/
// End_Foreach trio. See core/chunk.odin's Op_Code doc comment and the
// operand-layout notes inline below; both this compiler and the VM
// that reads this bytecode (Phase 4) are implemented by this port, so
// the exact encoding is this port's own choice as long as it's
// internally consistent, which these two emission sites (here and
// Phase 4's foreach handler) need to agree on.
foreach_statement :: proc(p: ^Parser) {
	begin_scope(p)
	has_paren := match(p, .Left_Paren)
	match(p, .Var) // `foreach (var x in y)` -- optional, same as glox's own p.match(TOKEN_VAR)
	consume(p, .Identifier, "Expect loop variable name.")
	// A local's compile-time slot must correspond to an actual runtime
	// stack push (see add_local/finish_declare elsewhere) -- but the
	// loop variable has no initializer expression of its own (Op_Foreach/
	// Op_Next fill it in directly, every iteration); without this
	// explicit Nil push, its slot would silently alias whatever
	// `expression(p)` (the iterable, below) pushes instead, and __iter's
	// own slot would end up one past the end of anything actually
	// written -- reading uninitialised stack garbage at runtime. Found
	// the hard way: this exact bug crashed every real foreach loop
	// during Phase 4's first end-to-end test run.
	emit_op(p, .Nil)
	add_local(p, p.previous)
	mark_initialised(p)
	var_slot := u8(p.current_compiler.local_count - 1)

	consume(p, .In, "Expect 'in' after foreach variable.")
	expression(p) // the iterable -- becomes __iter's initial value

	add_local(p, synthetic_token(.Identifier, "__iter", p.previous.line))
	mark_initialised(p)
	iter_slot := u8(p.current_compiler.local_count - 1)

	if has_paren {
		consume(p, .Right_Paren, "Expect ')' after iterable.")
	}

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
	match(p, .Eol) // see if_statement's doc comment: same Eol-before-body hazard
	statement(p)

	for c in loop.continues {
		patch_jump(p, c)
	}

	// Op_Next operands: 2-byte back-jump (to loop.start, taken when
	// another value is available), then var_slot and iter_slot -- the
	// VM needs both here, not just iter_slot, since Op_Next is what
	// actually stores each newly-yielded value into the loop variable
	// on every iteration after the first (Op_Foreach only handles the
	// very first one). Computed the same way emit_loop computes its own
	// back-jump, but "+4" rather than "+2" since Op_Next has two more
	// trailing operand bytes (var_slot, iter_slot) after the jump pair
	// that are still part of this same instruction's total width.
	emit_op(p, .Next)
	back_offset := len(current_chunk(p).code) - loop.start + 4
	if back_offset > 0xffff {
		error(p, "Loop body too large.")
	}
	emit_byte(p, u8((back_offset >> 8) & 0xff))
	emit_byte(p, u8(back_offset & 0xff))
	emit_byte(p, var_slot)
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
		error(p, "Cannot use break outside loop.") // matches glox's own wording (compile.go)
		return
	}
	pop_locals_above(p, loop.scope_depth)
	emit_crossing_jump(p, loop.scope_depth, .Break, loop)
	consume_eol(p, "Expect newline after 'break'.")
}

continue_statement :: proc(p: ^Parser) {
	loop := p.current_compiler.loop
	if loop == nil {
		error(p, "Cannot use continue outside loop.") // matches glox's own wording (compile.go)
		return
	}
	pop_locals_above(p, loop.scope_depth)
	// A foreach's "increment" is Op_Next itself, which sits *after* the
	// body -- so continue forward-jumps to just before it, rather than
	// back-jumping to the top the way a while/for loop's continue does.
	// (emit_crossing_jump's Continue finalize checks loop.is_foreach
	// itself, once it actually emits the jump/loop instruction.)
	emit_crossing_jump(p, loop.scope_depth, .Continue, loop)
	consume_eol(p, "Expect newline after 'continue'.")
}

return_statement :: proc(p: ^Parser) {
	if p.current_compiler.type == .Script {
		error(p, "Can't return from top-level code.")
	}

	// Right_Brace included alongside Eol/Eof/Semicolon -- a bare `return`
	// as a one-line block's last statement (`func g() { return }`, no `;`
	// separating it from the `}`) has nothing after it but the block's
	// own closing brace, which consume_eol below already treats as an
	// implied terminator (matching glox's checkStatementEnd exactly);
	// this check just needed to agree with it. Without Right_Brace here,
	// this fell into the "has a value" branch below and tried to parse
	// `}` as the start of an expression -- "Expect expression." -- found
	// via oneline_blocks.lox.
	if check(p, .Eol) || check(p, .Eof) || check(p, .Semicolon) || check(p, .Right_Brace) {
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

	// Collect every enclosing try, innermost first -- a return crosses
	// all of them unconditionally, up to the function boundary (unlike
	// break/continue, which only cross as far as the target loop). No
	// Op_End_Try needed here the way break/continue's cross_tries emits
	// one per crossing: Op_Return already tears down the whole frame
	// (see run.odin), which discards frame.handlers wholesale -- popping
	// them one at a time first would be redundant, not incorrect, but
	// glox's own returnStatement (compile.go) skips it for exactly this
	// reason and this port matches that.
	chain: [dynamic]^Try_Finally
	for t := p.current_compiler.tries; t != nil; t = t.previous {
		append(&chain, t)
	}
	if len(chain) == 0 {
		emit_op(p, .Return)
		return
	}

	// Anchor the return value in a synthetic local before any enclosing
	// (not-yet-parsed) finally block can declare locals of its own that
	// might otherwise reuse this slot number.
	add_local(p, synthetic_token(.Identifier, "__retval", p.previous.line))
	retval_slot := p.current_compiler.local_count - 1
	mark_initialised(p)

	site := Trampoline_Site {
		jump_offset             = emit_jump(p, .Jump),
		remaining               = chain[1:],
		local_count_at_crossing = p.current_compiler.local_count,
		retval_slot             = retval_slot,
		kind                    = .Return,
	}
	append(&chain[0].pending, site)
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
// after target_scope_depth, so frame.handlers never holds a stale entry
// for a try no longer lexically in scope -- and returns all of them,
// innermost first, so the caller (emit_crossing_jump) can defer a
// finally replay through each one, in order.
//
// Deliberately not filtered by has_finally: for a try the break/continue
// is directly inside (not yet closed), has_finally isn't known yet --
// `finally` is the last thing try_except_statement parses, so its own
// still-being-compiled body can't know whether one follows.
// compile_pending_trampolines resolves this correctly once each try
// actually closes and has_finally becomes known.
@(private = "file")
cross_tries :: proc(p: ^Parser, target_scope_depth: int) -> [dynamic]^Try_Finally {
	crossed: [dynamic]^Try_Finally
	for t := p.current_compiler.tries; t != nil && t.scope_depth_at_entry >= target_scope_depth; t = t.previous {
		emit_op(p, .End_Try)
		emit_byte(p, 0)
		emit_byte(p, 0)
		append(&crossed, t)
	}
	return crossed
}

// local_count_at_depth returns how many of the current function's locals
// have depth <= boundary_scope_depth -- i.e. the local count (and so the
// runtime stack height relative to the frame's own slots) that remains
// once every local declared inside a loop body has been popped, mirroring
// the depth check break/continue's own pop_locals_above already uses.
@(private = "file")
local_count_at_depth :: proc(p: ^Parser, boundary_scope_depth: int) -> int {
	c := p.current_compiler
	n := c.local_count
	for n > 0 && c.locals[n - 1].depth > boundary_scope_depth {
		n -= 1
	}
	return n
}

// emit_crossing_jump emits whatever jump takes a break/continue across
// any try/finally blocks it crosses on the way out to loop_scope_depth:
// if none have a finally clause (in fact none are even open at all --
// the common case), the real terminal jump/loop-back-edge is emitted
// immediately; otherwise a deferred trampoline site is queued on the
// innermost crossed try so its finally runs first, chaining outward
// through the rest before the real break/continue jump finally emits.
@(private = "file")
emit_crossing_jump :: proc(p: ^Parser, loop_scope_depth: int, kind: Trampoline_Kind, loop: ^Loop) {
	crossed := cross_tries(p, loop_scope_depth)
	if len(crossed) == 0 {
		finalize_break_or_continue(p, kind, loop)
		return
	}
	site := Trampoline_Site {
		jump_offset             = emit_jump(p, .Jump),
		remaining               = crossed[1:],
		local_count_at_crossing = local_count_at_depth(p, loop_scope_depth),
		retval_slot             = -1,
		kind                    = kind,
		loop                    = loop,
	}
	append(&crossed[0].pending, site)
}

// finalize_break_or_continue emits the real terminal instruction for a
// Break/Continue Trampoline_Kind -- shared between emit_crossing_jump's
// no-crossing fast path and compile_pending_trampolines' end-of-chain
// case, so both stay in sync with continue's foreach-vs-loop distinction.
@(private = "file")
finalize_break_or_continue :: proc(p: ^Parser, kind: Trampoline_Kind, loop: ^Loop) {
	switch kind {
	case .Break:
		append(&loop.breaks, emit_jump(p, .Jump))
	case .Continue:
		if loop.is_foreach {
			append(&loop.continues, emit_jump(p, .Jump))
		} else {
			emit_loop(p, loop.start)
		}
	case .Return:
		emit_op(p, .Return) // reached only via compile_pending_trampolines; return's own site carries no loop
	}
}

// compile_trampolines_after_normal_path compiles try_ctx's pending
// break/continue/return trampolines (see compile_pending_trampolines),
// placed immediately after the normal-completion path in the bytecode
// stream. That adjacency means normal completion would otherwise fall
// straight through into them, so -- when there's anything to skip --
// this wraps them in an unconditional jump the normal path takes to
// land just past all of them, at the true end of the whole
// try/except/finally statement.
@(private = "file")
compile_trampolines_after_normal_path :: proc(p: ^Parser, try_ctx: ^Try_Finally) {
	if len(try_ctx.pending) == 0 {
		return
	}
	skip := emit_jump(p, .Jump)
	compile_pending_trampolines(p, try_ctx)
	patch_jump(p, skip)
}

// compile_pending_trampolines resolves every break/continue/return that
// deferred into try_ctx while its body was being compiled (see
// Try_Finally/Trampoline_Site), chaining onward into any further outer
// try/finally the same jump also needs to cross.
//
// Runs unconditionally, whether or not try_ctx ended up with a finally
// clause -- return/break/continue must defer into the innermost
// enclosing try *before* that try has parsed far enough to know whether
// a `finally` follows its except clauses (single-pass parser, `finally`
// is the last thing consumed), so every enclosing try collects deferred
// sites regardless. If try_ctx has no finally, there's nothing to
// replay -- the jump just passes straight through to the next hop (or
// the real terminal instruction) with no bytecode of its own.
@(private = "file")
compile_pending_trampolines :: proc(p: ^Parser, try_ctx: ^Try_Finally) {
	for site in try_ctx.pending {
		patch_jump(p, site.jump_offset)

		if try_ctx.has_finally {
			c := p.current_compiler
			saved_count := c.local_count
			saved_depth := c.scope_depth

			// Reserve slots up to local_count_at_crossing so this
			// replay's own locals can't alias whatever's still live
			// higher on the real runtime stack (e.g. a pending return's
			// anchored __retval) -- see Trampoline_Site's doc comment.
			for i := c.local_count; i < site.local_count_at_crossing; i += 1 {
				c.locals[i] = Local{depth = c.scope_depth}
			}
			c.local_count = site.local_count_at_crossing

			saved_tries := c.tries
			c.tries = try_ctx.previous // control flow inside finally sees only outer trys

			restore_pos(p, try_ctx.finally_snapshot)
			begin_scope(p)
			block(p)
			end_scope(p)

			c.tries = saved_tries
			c.local_count = saved_count
			c.scope_depth = saved_depth

			if site.retval_slot >= 0 {
				emit_op_byte(p, .Get_Local, u8(site.retval_slot))
			}
		}

		if len(site.remaining) > 0 {
			next := site.remaining[0]
			new_site := Trampoline_Site {
				jump_offset             = emit_jump(p, .Jump),
				remaining               = site.remaining[1:],
				local_count_at_crossing = site.local_count_at_crossing,
				retval_slot             = site.retval_slot,
				kind                    = site.kind,
				loop                    = site.loop,
			}
			append(&next.pending, new_site)
		} else {
			finalize_break_or_continue(p, site.kind, site.loop)
		}
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

	match(p, .Eol) // `try\n{` -- same tolerance as every other brace in this construct
	consume(p, .Left_Brace, "Expect '{' after 'try'.")
	begin_scope(p)
	block(p)
	end_scope(p)

	normal_end_jump := emit_jump(p, .End_Try)
	patch_jump(p, try_jump) // Op_Try's operand -> the first clause, patched once

	clause_exit_jumps: [dynamic]int
	saw_except := false

	// Real bug, found via the ported test suite's own finally_bare_ns.lox
	// (`}` and `finally`/`except` on separate lines -- a real, common
	// style, and byte-identical to finally_bare.lox otherwise): block()
	// leaves the parser positioned right after the try body's `}`, and
	// unlike inside a class body (stmt.odin's class_declaration has its
	// own explicit "Eol between two methods" branch for exactly this
	// reason) or a function's `)`/`{` gap (functions.odin's compile_function_body),
	// nothing here tolerated an Eol sitting between that `}` and the
	// `except`/`finally` keyword that's supposed to follow it -- the
	// scanner keeps that Eol (Right_Brace isn't in keep_eol's suppress
	// set), so `check(p, .Except)`/`check(p, .Finally)` saw an Eol
	// instead and this whole try/except/finally construct failed to
	// parse. Skipped consistently at every point a clause boundary is
	// checked, not just the first: between the try body and the first
	// except clause, between successive except clauses, and before the
	// finally check.
	match(p, .Eol)
	for check(p, .Except) {
		saw_except = true
		advance(p)
		consume(p, .Identifier, "Expect exception type name.")
		type_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(lexeme(p.previous)))
		emit_op(p, .Except)
		emit_byte(p, type_const)
		// Except's own 2-byte skip offset -- a deliberate improvement
		// over glox's byte-pattern scan for "the next clause" (see
		// vm/exceptions.odin's header comment for why that's fragile
		// once a clause body can itself contain a nested try): this
		// port's Op_Except is self-describing, so the VM never has to
		// scan bytecode looking for End_Except at all. Patched below,
		// after the clause body, exactly like any other jump.
		skip_jump := len(current_chunk(p).code)
		emit_byte(p, 0xff)
		emit_byte(p, 0xff)

		begin_scope(p)
		if match(p, .As) {
			consume(p, .Identifier, "Expect exception binding name.")
			add_local(p, p.previous)
			mark_initialised(p)
		}
		// Same Eol-tolerance-before-brace need as functions.odin's
		// compile_function_body: `except Exception as e\n{` (found in
		// the same fixture as the try-body-to-clause gap fixed above) --
		// found once porting the .lox standard library kept turning up
		// this exact class of gap, spot by spot, wherever this compiler
		// requires a `{` immediately after something with no tolerance
		// for it landing on the next line instead.
		match(p, .Eol)
		consume(p, .Left_Brace, "Expect '{' after except clause.")
		block(p)
		end_scope(p)

		append(&clause_exit_jumps, emit_jump(p, .Jump))
		emit_op(p, .End_Except)
		patch_jump(p, skip_jump)
		match(p, .Eol)
	}

	if !saw_except && !check(p, .Finally) {
		error(p, "Expect 'except' or 'finally' after try block.")
	}

	has_finally := match(p, .Finally)
	try_ctx.has_finally = has_finally

	if has_finally {
		match(p, .Eol) // `finally\n{` -- same tolerance as except's own clause body above
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
	compile_trampolines_after_normal_path(p, try_ctx)
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
		// Unlike declaration() at the top level (see this file's
		// declaration() proc), this loop had no panic_mode check of
		// its own -- a malformed method whose error path leaves
		// panic_mode set without consuming a token (e.g. consume()
		// failing on `.Left_Brace` for a method body) meant this
		// loop's condition (still not Right_Brace/Eof) stayed true
		// forever and called method() again on the exact same token,
		// looping without ever making progress. Found via a genuinely
		// hung `odlox` process (not a wrong compile) on a method
		// declared with its `{` on the following line -- reproduces
		// with any malformed method, same root cause as the
		// already-fixed "Eol between methods" bug above: an error
		// path inside method() that returns without the token
		// advancing. synchronize() is the same recovery declaration()
		// already uses; safe to reuse here since it always advances
		// at least one token before returning, so it can't loop
		// forever either.
		if p.panic_mode {
			synchronize(p)
		}
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
		// Not consume_eol: the scanner's own Eol-suppression heuristic
		// (scanner.odin's keep_eol) treats `*` purely as a token type,
		// with no way to know this one is `from mod import *`'s wildcard
		// marker rather than the multiplication operator -- which
		// legitimately continues onto the next line (`x = a *\nb`), so
		// `Star` is in keep_eol's suppress-after set. That means the Eol
		// that would normally follow `from mod import *` on its own line
		// is never even scanned into the token stream here at all --
		// requiring one via consume_eol always failed with "Expect
		// newline after import.", since there was structurally nothing
		// for it to match. Nothing can legally follow `*` in this
		// grammar position anyway (unlike real multiplication), so no
		// terminator check is needed here at all; the next token just
		// starts the next statement normally.
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
