package compiler

// Implementation phase 2 of docs/plans/compiler-ast-split.md: a second,
// AST-building precedence-climbing driver that coexists with parser.odin's
// original bytecode-emitting one for the duration of the migration. Odin
// packages share one flat namespace per directory, so nothing here can
// reuse expr.odin/stmt.odin's proc names until those originals are gone --
// every new-pipeline proc introduced across this refactor is suffixed
// `_ast` for now. At cutover (implementation phase 8), the old pipeline's
// files are deleted and every `_ast` suffix comes off in the same commit.
//
// Reuses parser.odin's token-stream driving (advance/check/match/consume/
// error*/synchronize) and Precedence enum unchanged -- neither depends on
// emission or AST-building, so there is nothing to fork.

Prefix_Fn_Ast :: #type proc(p: ^Parser, can_assign: bool) -> Expr
Infix_Fn_Ast :: #type proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr

Parse_Rule_Ast :: struct {
	prefix:     Prefix_Fn_Ast,
	infix:      Infix_Fn_Ast,
	precedence: Precedence,
}

expression_ast :: proc(p: ^Parser) -> Expr {
	return parse_precedence_ast(p, .Assignment)
}

parse_precedence_ast :: proc(p: ^Parser, precedence: Precedence) -> Expr {
	p.expr_depth += 1
	defer p.expr_depth -= 1
	if p.expr_depth > MAX_EXPR_DEPTH {
		error(p, "Expression nested too deeply.")
		skip_to_end_ast(p)
		return nil
	}

	advance(p)
	prefix := get_rule_ast(p.previous.type).prefix
	if prefix == nil {
		error(p, "Expect expression.")
		return nil
	}

	can_assign := precedence <= .Assignment
	left := prefix(p, can_assign)

	for precedence <= get_rule_ast(p.current.type).precedence {
		advance(p)
		infix := get_rule_ast(p.previous.type).infix
		left = infix(p, left, can_assign)
	}

	if can_assign && match(p, .Equal) {
		error(p, "Invalid assignment target.")
	}
	return left
}

@(private = "file")
skip_to_end_ast :: proc(p: ^Parser) {
	for p.current.type != .Eof {
		advance(p)
	}
}
