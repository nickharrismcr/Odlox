package compiler

import "../core"

// Shared function-body compilation: parameters (including `*rest`
// variadic and `name = expr` defaults) and the `{ block }` body. Used by
// declared functions (stmt.odin's function_declaration), anonymous
// lambdas (expr.odin's lambda), and class methods (stmt.odin's method) --
// all three just differ in what happens *around* the call (how the
// resulting closure gets bound, if at all), not in how the function
// itself compiles.

// compile_function assumes init_function_compiler has just been called
// (so p.current_compiler is the new nested Compiler) and the parser is
// sitting right before the parameter list's `(`. It compiles the whole
// function, pops back to the enclosing compiler, and emits Op_Code.Closure
// there -- so by the time this returns, the closure is the top-of-stack
// value in the *caller's* context, same as any other expression result.
compile_function :: proc(p: ^Parser) {
	compile_function_body(p)
	finished := end_compiler(p)
	emit_closure(p, finished)
}

@(private = "file")
compile_function_body :: proc(p: ^Parser) {
	begin_scope(p)
	consume(p, .Left_Paren, "Expect '(' after function name.")

	fn := p.current_compiler.function
	min_arity := 0
	saw_default := false

	if !check(p, .Right_Paren) {
		for {
			if match(p, .Star) {
				consume(p, .Identifier, "Expect rest parameter name.")
				declare_variable(p)
				mark_initialised(p)
				fn.arity += 1
				fn.is_variadic = true
				break // *rest must be the last parameter
			}

			consume(p, .Identifier, "Expect parameter name.")
			declare_variable(p)
			mark_initialised(p)
			slot := u8(p.current_compiler.local_count - 1)
			fn.arity += 1

			if match(p, .Equal) {
				saw_default = true
				// Prologue guard: only run the default expression if
				// the caller actually omitted this argument (the VM
				// pads an omitted optional param with a
				// Value.Undefined sentinel before the body starts).
				jump := emit_jump_if_defined(p, slot)
				expression(p)
				emit_op_byte(p, .Set_Local, slot)
				emit_op(p, .Pop)
				patch_jump(p, jump)
			} else if saw_default {
				error(p, "Non-default parameter can't follow a default parameter.")
			} else {
				min_arity += 1
			}

			if !match(p, .Comma) {
				break
			}
		}
	}
	match(p, .Eol) // allow EOL before ')' (e.g. a trailing comma's own line)
	consume(p, .Right_Paren, "Expect ')' after parameters.")
	fn.min_arity = min_arity

	// A `{` on its own line after the parameter list -- e.g.
	//   func f()
	//   { ... }
	// -- is valid: the scanner's Eol-suppression rule only looks at the
	// *previous* token (see scanner.odin's keep_eol), and Right_Paren
	// isn't in its suppress set, so this Eol survives into the token
	// stream and must be tolerated here explicitly rather than left for
	// consume(p, .Left_Brace, ...) to choke on.
	match(p, .Eol)
	consume(p, .Left_Brace, "Expect '{' before function body.")
	block(p)
}

@(private = "file")
emit_jump_if_defined :: proc(p: ^Parser, slot: u8) -> int {
	emit_op(p, .Jump_If_Defined)
	emit_byte(p, slot)
	emit_byte(p, 0xff)
	emit_byte(p, 0xff)
	return len(current_chunk(p).code) - 2
}

@(private = "file")
emit_closure :: proc(p: ^Parser, finished: ^Compiler) {
	fn := finished.function
	const_idx := core.chunk_add_constant(current_chunk(p), core.make_object_value(&fn.obj))
	emit_op_byte(p, .Closure, const_idx)
	for i in 0 ..< fn.upvalue_count {
		emit_byte(p, 1 if finished.upvalues[i].is_local else 0)
		emit_byte(p, finished.upvalues[i].index)
	}
}
