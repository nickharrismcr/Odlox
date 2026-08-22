package compiler

// Type_Expr's own recursive-descent grammar, called directly wherever a
// type is expected (params, var decls, return types -- see functions.odin/
// stmt.odin) rather than going through the Pratt table in rules.odin: it
// isn't an expression precedence level, just a small self-contained shape.
//
//   type_expr → IDENTIFIER ( "[" type_expr ( "," type_expr )* "]" )? "?"?

parse_type_expr :: proc(p: ^Parser) -> ^Type_Expr {
	consume(p, .Identifier, "Expect type name.")
	name_tok := p.previous

	result := new_clone(Type_Expr{base = Node_Base{token = name_tok}, kind = .Named, name = name_tok})

	if match(p, .Left_Bracket) {
		result.kind = .Generic
		args: [dynamic]^Type_Expr
		append(&args, parse_type_expr(p))
		for match(p, .Comma) {
			append(&args, parse_type_expr(p))
		}
		consume(p, .Right_Bracket, "Expect ']' after type arguments.")
		result.args = args[:]
	}

	if match(p, .Question) {
		result = new_clone(Type_Expr{base = Node_Base{token = result.token}, kind = .Nilable, name = name_tok, inner = result})
	}

	return result
}
