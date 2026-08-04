package compiler

// AST-building counterpart to rules.odin's get_rule -- see v2_parser.odin's
// header comment for why this exists as a parallel file during migration.
//
// `.Func` is deliberately left unmapped for now (falls through to the
// nil/nil/.None default below): a lambda's body needs statement-level AST
// parsing (declaration_ast/statement_ast), which lands in implementation
// phase 3, not phase 2. lambda_ast and this case both arrive together.
get_rule_ast :: proc(type: Token_Type) -> Parse_Rule_Ast {
	#partial switch type {
	case .Left_Paren:
		return {parenthesized_ast, call_ast, .Call}
	case .Left_Bracket:
		return {list_literal_ast, subscript_ast, .Call}
	case .Left_Brace:
		return {dict_literal_ast, nil, .None}
	case .Dot:
		return {nil, dot_ast, .Call}

	case .Minus:
		return {unary_ast, binary_ast, .Term}
	case .Plus:
		return {nil, binary_ast, .Term}
	case .Plus_Plus:
		return {nil, binary_ast, .Term}
	case .Star:
		return {nil, binary_ast, .Factor}
	case .Slash:
		return {nil, binary_ast, .Factor}
	case .Percent:
		return {nil, binary_ast, .Factor}
	case .Ampersand:
		return {nil, binary_ast, .Term}
	case .Bang:
		return {unary_ast, nil, .None}
	case .Bang_Equal:
		return {nil, binary_ast, .Equality}
	case .Equal_Equal:
		return {nil, binary_ast, .Equality}
	case .Greater:
		return {nil, binary_ast, .Comparison}
	case .Greater_Equal:
		return {nil, binary_ast, .Comparison}
	case .Less:
		return {nil, binary_ast, .Comparison}
	case .Less_Equal:
		return {nil, binary_ast, .Comparison}
	case .In:
		return {nil, binary_ast, .Equality}
	case .Question:
		return {nil, conditional_ast, .Conditional}
	case .And:
		return {nil, and_ast, .And}
	case .Or:
		return {nil, or_ast, .Or}

	case .Identifier:
		return {variable_ast, nil, .None}
	case .String:
		return {string_literal_ast, nil, .None}
	case .Int:
		return {int_literal_ast, nil, .None}
	case .Float:
		return {float_literal_ast, nil, .None}
	case .Str:
		return {str_call_ast, nil, .None}

	case .False, .True, .Nil:
		return {literal_ast, nil, .None}
	case .This:
		return {this_ast, nil, .None}
	case .Super:
		return {super_ast, nil, .None}
	}
	return {nil, nil, .None}
}
