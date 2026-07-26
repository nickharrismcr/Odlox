package compiler

// The Pratt parse-rule table: for every token kind, what to do when it's
// seen where a prefix (start-of-expression) form is expected, what to do
// when it's seen as an infix (continuing an expression already parsed),
// and at what precedence the infix form binds. A switch rather than a
// `[Token_Type]Parse_Rule` array literal, purely so each case can be
// read next to a short note on *why* that token parses the way it does
// where that's not obvious from the name alone; the actual prefix/infix
// procs live in expr.odin (most of them) and stmt.odin (`func`, since a
// lambda's body looks a lot like a statement-level function).
get_rule :: proc(type: Token_Type) -> Parse_Rule {
	#partial switch type {
	case .Left_Paren:
		// Prefix: grouping `(expr)` or a tuple `(a, b, ...)` (grouping
		// itself decides which, based on a trailing comma). Infix: a
		// call on whatever expression precedes it.
		return {grouping, call, .Call}
	case .Left_Bracket:
		return {list_literal, subscript, .Call}
	case .Left_Brace:
		return {dict_literal, nil, .None}
	case .Dot:
		return {nil, dot, .Call}

	case .Minus:
		return {unary, binary, .Term}
	case .Plus:
		return {nil, binary, .Term}
	case .Plus_Plus:
		// Vector in-place-shaped addition (`a ++ b`) -- Op_Code.Add_Vector,
		// distinct from the numeric `+` (Op_Code.Add_Numeric): the
		// compiler can't know an operand's runtime type, so `+`/`++`
		// pick *which* opcode to emit, and each opcode does its own
		// runtime type check/dispatch (Phase 4).
		return {nil, binary, .Term}
	case .Star:
		return {nil, binary, .Factor}
	case .Slash:
		return {nil, binary, .Factor}
	case .Percent:
		return {nil, binary, .Factor}
	case .Ampersand:
		return {nil, binary, .Term} // string/list concatenation
	case .Bang:
		return {unary, nil, .None}
	case .Bang_Equal:
		return {nil, binary, .Equality}
	case .Equal_Equal:
		return {nil, binary, .Equality}
	case .Greater:
		return {nil, binary, .Comparison}
	case .Greater_Equal:
		return {nil, binary, .Comparison}
	case .Less:
		return {nil, binary, .Comparison}
	case .Less_Equal:
		return {nil, binary, .Comparison}
	case .In:
		// Matches glox's own rule table exactly (compile.go:
		// `TOKEN_IN: {prefix: nil, infix: binary, prec: PREC_EQUALITY}`).
		// Was never wired up on this port's side at all -- the `In`
		// opcode and its VM implementation (do_in, run.odin) already
		// existed, but with no rule table entry `in` used as an
		// expression (`"x" in s`) fell through to `variable`'s dispatch
		// as a bare identifier read and failed to parse. foreach's own
		// `consume(p, .In, ...)` is unaffected -- it never goes through
		// the Pratt parser for this token.
		return {nil, binary, .Equality}
	case .Question:
		return {nil, conditional, .Conditional}
	case .And:
		return {nil, and_, .And}
	case .Or:
		return {nil, or_, .Or}

	case .Identifier:
		return {variable, nil, .None}
	case .String:
		return {string_literal, nil, .None}
	case .Int:
		return {int_literal, nil, .None}
	case .Float:
		return {float_literal, nil, .None}
	case .Str:
		// The reserved `str(expr)` form -- compiles straight to
		// Op_Code.Str, the same opcode string interpolation desugars
		// into (see scanner.odin's scan_string). Not an ordinary call.
		return {str_call, nil, .None}

	case .False, .True, .Nil:
		return {literal, nil, .None}
	case .This:
		return {this_, nil, .None}
	case .Super:
		return {super_, nil, .None}
	case .Func:
		return {lambda, nil, .None}
	}
	return {nil, nil, .None}
}
