package compiler

// The Pratt (operator-precedence) parser core: token-stream driving,
// error recovery, and the precedence-climbing expression driver. This
// file deliberately has no knowledge of *what* any given token compiles
// to -- that's the per-token Parse_Rule table (rules.odin) and the
// individual prefix/infix functions (expr.odin/stmt.odin). Single-pass,
// no AST: every parse function that recognizes a construct emits its
// bytecode directly, via the emit_* helpers in compiler_state.odin.

import "core:fmt"

Parser :: struct {
	scn:              ^Scanner,
	filename:         string,
	current, previous: Token,
	had_error:         bool,
	panic_mode:        bool,

	current_compiler: ^Compiler,
	current_class:    ^Class_Compiler,

	// Global slot assignment for this whole compilation unit -- see
	// compiler_state.odin's global_slot. globals_declared distinguishes
	// "explicitly declared via var/const/import/implicit-assignment"
	// from "merely referenced" (forward references are allowed: a name
	// gets a slot on first *mention*, not first *declaration*).
	globals:             map[string]int,
	globals_declared:    map[string]bool,
	global_count:        int,
	global_names_by_slot: [dynamic]string,

	// Recursion-depth guards against runaway nesting -- Odin's own call
	// stack would overflow on sufficiently pathological input otherwise,
	// which can't be recovered from the way an ordinary parse error can.
	expr_depth: int,
	stmt_depth: int,

	// Snapshotted from the package-level DebugSkipPeephole (see
	// compiler_state.odin) once, when this Parser is constructed --
	// end_compiler reads this field, not the global, so one compile's
	// peephole behavior can't be affected by another compile
	// concurrently flipping the global mid-run (two compiles running on
	// different threads, one toggling the flag around itself, could
	// otherwise interleave with a completely unrelated compile that
	// never touches the flag at all). This makes each compile's
	// behavior a stable snapshot taken at its own start, not shared
	// mutable state.
	skip_peephole: bool,
}

MAX_EXPR_DEPTH :: 1000
MAX_STMT_DEPTH :: 1000

// -----------------------------------------------------------------------
// Token-stream driving

advance :: proc(p: ^Parser) {
	p.previous = p.current
	for {
		p.current = next_token(p.scn)
		if p.current.type != .Error {
			break
		}
		error_at_current(p, lexeme(p.current))
	}
}

check :: proc(p: ^Parser, type: Token_Type) -> bool {
	return p.current.type == type
}

// check_next peeks one token past `current` without consuming anything
// -- used to distinguish e.g. `identifier =` (implicit declaration) from
// `identifier ,` (destructuring target) before committing to a parse path.
check_next :: proc(p: ^Parser, type: Token_Type) -> bool {
	return peek_token(p.scn).type == type
}

match :: proc(p: ^Parser, type: Token_Type) -> bool {
	if !check(p, type) {
		return false
	}
	advance(p)
	return true
}

consume :: proc(p: ^Parser, type: Token_Type, message: string) {
	if p.current.type == type {
		advance(p)
		return
	}
	error_at_current(p, message)
}

// consume_eol accepts any of: an explicit Eol, an explicit Semicolon
// (always a valid alternative statement terminator, not just inside a
// `for(...)` header), being right at Eof (a script's last line commonly
// has no trailing newline of its own left to consume -- see
// scanner.odin's trailing-Eol handling), or -- checked, not consumed,
// since the caller's own block() loop needs to see it -- sitting right
// at a closing `}`. That last case matters for a one-line block body
// like `{ print 1 }`: there is no Eol token between `1` and `}` at all
// (they're on the same physical line), so the `}` itself has to count
// as an implicit terminator, the same way it would in most brace-
// delimited languages, or every block body would be forced onto
// multiple lines.
consume_eol :: proc(p: ^Parser, message: string) {
	if match(p, .Eol) || match(p, .Semicolon) || check(p, .Eof) || check(p, .Right_Brace) {
		return
	}
	error_at_current(p, message)
}

// snapshot_pos/restore_pos let the parser rewind and re-parse a range of
// already-scanned tokens -- safe because the whole token stream is
// materialized up front (scanner.odin), so replaying is side-effect-free.
// Used by try/finally compilation (stmt.odin) to compile a `finally`
// block's source twice (once for the normal-completion landing point,
// once for the always-matching re-raise handler) without duplicating
// bytecode by hand, which would require relocating every local/upvalue
// operand baked into it.
snapshot_pos :: proc(p: ^Parser) -> Parser_Snapshot {
	return Parser_Snapshot{current = p.current, previous = p.previous, token_idx = p.scn.token_idx}
}

restore_pos :: proc(p: ^Parser, snap: Parser_Snapshot) {
	p.current = snap.current
	p.previous = snap.previous
	p.scn.token_idx = snap.token_idx
}

// -----------------------------------------------------------------------
// Error reporting: classic panic-mode. error_at sets had_error and
// prints the first error in a cascade (panic_mode suppresses the rest
// until synchronize() finds a statement boundary to resume at).

error_at_current :: proc(p: ^Parser, message: string) {
	error_at(p, p.current, message)
}

error :: proc(p: ^Parser, message: string) {
	error_at(p, p.previous, message)
}

@(private = "file")
error_at :: proc(p: ^Parser, tok: Token, message: string) {
	if p.panic_mode {
		return
	}
	p.panic_mode = true
	p.had_error = true

	// Compile errors print to stdout (fmt.printfln), not stderr -- kept
	// consistent with how main.odin reports Runtime_Error from run_file,
	// and with what the test harness's output-capturing helpers expect.
	if tok.type == .Eof {
		fmt.printfln("[line %d] Error at end: %s", tok.line, message)
	} else if tok.type == .Error {
		fmt.printfln("[line %d] Error: %s", tok.line, message)
	} else {
		fmt.printfln("[line %d] Error at '%s': %s", tok.line, lexeme(tok), message)
	}
}

// synchronize skips tokens until a likely statement boundary (previous
// token was a terminator, or the current one starts a new declaration),
// so one syntax error doesn't cascade into a wall of bogus follow-on
// errors from the same bad parse state.
synchronize :: proc(p: ^Parser) {
	p.panic_mode = false

	for p.current.type != .Eof {
		if p.previous.type == .Semicolon || p.previous.type == .Eol {
			return
		}
		#partial switch p.current.type {
		case .Class, .Func, .For, .If, .While, .Print, .Return, .Var, .Const, .Import:
			return
		}
		advance(p)
	}
}

// -----------------------------------------------------------------------
// Precedence-climbing expression driver

Precedence :: enum {
	None,
	Assignment, // =
	Conditional, // ?:
	Or, // or
	And, // and
	Equality, // == !=
	Comparison, // < > <= >=
	Term, // + - &
	Factor, // * / %
	Unary, // ! -
	Call, // . () []
	Primary,
}

Parse_Fn :: #type proc(p: ^Parser, can_assign: bool)

Parse_Rule :: struct {
	prefix, infix: Parse_Fn,
	precedence:    Precedence,
}

expression :: proc(p: ^Parser) {
	parse_precedence(p, .Assignment)
}

parse_precedence :: proc(p: ^Parser, precedence: Precedence) {
	p.expr_depth += 1
	defer p.expr_depth -= 1
	if p.expr_depth > MAX_EXPR_DEPTH {
		error(p, "Expression nested too deeply.")
		skip_to_end(p)
		return
	}

	advance(p)
	prefix := get_rule(p.previous.type).prefix
	if prefix == nil {
		error(p, "Expect expression.")
		return
	}

	can_assign := precedence <= .Assignment
	prefix(p, can_assign)

	for precedence <= get_rule(p.current.type).precedence {
		advance(p)
		infix := get_rule(p.previous.type).infix
		infix(p, can_assign)
	}

	if can_assign && match(p, .Equal) {
		error(p, "Invalid assignment target.")
	}
}

// skip_to_end jumps straight to the trailing Eof -- used by the
// recursion-depth guards above (a genuine Odin-stack-overflow risk can't
// be recovered from the way an ordinary parse error can; there's no
// well-defined "next statement" to synchronize to from arbitrarily deep
// inside a runaway expression).
@(private = "file")
skip_to_end :: proc(p: ^Parser) {
	for p.current.type != .Eof {
		advance(p)
	}
}
