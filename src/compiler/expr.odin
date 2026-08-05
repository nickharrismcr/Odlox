package compiler

import "../core"
import "core:strconv"

// All prefix/infix expression parse functions the rule table (rules.odin)
// dispatches to. Each one assumes p.previous is the token that triggered
// it (standard Pratt-parser convention) and builds/returns an AST node --
// see docs/plans/compiler-ast-split.md. Validity checks that need more
// than a token comparison (`this`/`super` outside a class, const
// reassignment) are deliberately NOT done here -- they're the Resolver's
// job (resolve.odin), which is also where `Var_Ref`/`declared_slot`
// fields left zero-valued below get filled in.

// -----------------------------------------------------------------------
// Literals

int_literal :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	v, ok := strconv.parse_i64(lexeme(tok))
	if !ok {
		error(p, "Invalid integer literal.")
	}
	return new_clone(Expr_Literal{base = Node_Base{token = tok}, kind = .Int, value = core.make_int_value(int(v))})
}

float_literal :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	v, ok := strconv.parse_f64(lexeme(tok))
	if !ok {
		error(p, "Invalid float literal.")
	}
	return new_clone(Expr_Literal{base = Node_Base{token = tok}, kind = .Float, value = core.make_float_value(v)})
}

string_literal :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	text := lexeme(tok)
	return new_clone(
		Expr_Literal{base = Node_Base{token = tok}, kind = .String, value = core.make_string_value(text[1:len(text) - 1])},
	)
}

literal :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	#partial switch tok.type {
	case .False:
		return new_clone(Expr_Literal{base = Node_Base{token = tok}, kind = .Bool, value = core.make_bool_value(false)})
	case .True:
		return new_clone(Expr_Literal{base = Node_Base{token = tok}, kind = .Bool, value = core.make_bool_value(true)})
	}
	return new_clone(Expr_Literal{base = Node_Base{token = tok}, kind = .Nil, value = core.NIL_VALUE})
}

// str_call is the reserved `str(expr)` form -- Op_Code.Str, not an
// ordinary call (no callee, no argument-count checking).
str_call :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	consume(p, .Left_Paren, "Expect '(' after 'str'.")
	inner := expression(p)
	consume(p, .Right_Paren, "Expect ')' after expression.")
	return new_clone(Expr_Str_Call{base = Node_Base{token = tok}, inner = inner})
}

// -----------------------------------------------------------------------
// Grouping, unary, binary

// parenthesized handles both `(expr)` and a tuple literal
// `(a, b, ...)`, distinguished by whether a comma follows the first
// expression -- matching grouping()'s own behavior. Plain `(expr)`
// produces no node at all: the inner expression is returned directly.
parenthesized :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	if match(p, .Right_Paren) {
		return new_clone(Expr_Tuple{base = Node_Base{token = tok}})
	}
	elements: [dynamic]Expr
	append(&elements, expression(p))
	for match(p, .Comma) {
		if check(p, .Right_Paren) {
			break // trailing comma
		}
		append(&elements, expression(p))
	}
	consume(p, .Right_Paren, "Expect ')' after expression.")
	if len(elements) > 1 {
		if len(elements) > 255 {
			error(p, "Can't have more than 255 items in a tuple literal.")
		}
		return new_clone(Expr_Tuple{base = Node_Base{token = tok}, elements = elements[:]})
	}
	return elements[0]
}

unary :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	operand := parse_precedence(p, .Unary)
	return new_clone(Expr_Unary{base = Node_Base{token = tok}, op = tok.type, operand = operand})
}

// binary compiles a left-associative infix operator: everything at
// strictly higher precedence than this operator's own folds into the
// right operand first, matching binary()'s own precedence-climbing.
binary :: proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr {
	tok := p.previous
	rule := get_rule(tok.type)
	right := parse_precedence(p, Precedence(int(rule.precedence) + 1))
	return new_clone(Expr_Binary{base = Node_Base{token = tok}, op = tok.type, left = left, right = right})
}

// -----------------------------------------------------------------------
// Short-circuiting and/or, ternary

and_ :: proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr {
	tok := p.previous
	right := parse_precedence(p, .And)
	return new_clone(Expr_Logical{base = Node_Base{token = tok}, op = .And, left = left, right = right})
}

or_ :: proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr {
	tok := p.previous
	right := parse_precedence(p, .Or)
	return new_clone(Expr_Logical{base = Node_Base{token = tok}, op = .Or, left = left, right = right})
}

// conditional compiles `cond ? then : else` as an infix operator on
// the already-parsed condition. The else branch parses at Conditional
// (not Assignment) precedence so `a ? b : c ? d : e` chains
// right-associatively, matching conditional()'s own precedence choice.
conditional :: proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr {
	tok := p.previous
	then_branch := parse_precedence(p, .Assignment)
	consume(p, .Colon, "Expect ':' after '?' branch.")
	else_branch := parse_precedence(p, .Conditional)
	return new_clone(
		Expr_Conditional{base = Node_Base{token = tok}, condition = left, then_branch = then_branch, else_branch = else_branch},
	)
}

// -----------------------------------------------------------------------
// Variables, assignment, compound assignment

variable :: proc(p: ^Parser, can_assign: bool) -> Expr {
	// Snapshotted to a local first, not passed as `p.previous` directly:
	// named_variable's own value-branch calls expression(p), which
	// advances p.previous well past this identifier before the Expr_Assign
	// is built. Passing p.previous straight through observed that later
	// value instead of the one at this call site.
	name := p.previous
	return named_variable(p, name, can_assign)
}

// named_variable builds a read (Expr_Variable) or, if this reference
// is in assignable position, a plain or compound assignment (Expr_Assign)
// -- resolution (local/upvalue/global) and const-reassignment checking
// are the Resolver's job, not the parser's, so `resolved` is left
// zero-valued (.Unresolved) here.
named_variable :: proc(p: ^Parser, name: Token, can_assign: bool) -> Expr {
	if can_assign && match(p, .Equal) {
		value := expression(p)
		return new_clone(Expr_Assign{base = Node_Base{token = name}, name = name, is_compound = false, value = value})
	}
	if can_assign {
		if op, ok := compound_assign_token(p.current.type); ok {
			advance(p) // consume the += / -= / *= / /= / %= token
			value := expression(p)
			return new_clone(
				Expr_Assign{base = Node_Base{token = name}, name = name, is_compound = true, compound_op = op, value = value},
			)
		}
	}
	return new_clone(Expr_Variable{base = Node_Base{token = name}, name = name})
}

@(private = "file")
compound_assign_token :: proc(t: Token_Type) -> (Token_Type, bool) {
	#partial switch t {
	case .Plus_Equal, .Minus_Equal, .Star_Equal, .Slash_Equal, .Percent_Equal:
		return t, true
	}
	return .Error, false
}

// -----------------------------------------------------------------------
// this / super

// The "outside a class"/"no superclass" checks are the Resolver's job
// (resolve.odin) -- this/super only build nodes here.
this_ :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	return new_clone(Expr_This{base = Node_Base{token = tok}})
}

super_ :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	consume(p, .Dot, "Expect '.' after 'super'.")
	consume(p, .Identifier, "Expect superclass method name.")
	method_name := p.previous
	if match(p, .Left_Paren) {
		args := argument_list(p)
		return new_clone(Expr_Super{base = Node_Base{token = tok}, method_name = method_name, has_args = true, args = args})
	}
	return new_clone(Expr_Super{base = Node_Base{token = tok}, method_name = method_name})
}

// -----------------------------------------------------------------------
// Calls, property access

call :: proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr {
	tok := p.previous
	args := argument_list(p)
	return new_clone(Expr_Call{base = Node_Base{token = tok}, callee = left, args = args})
}

argument_list :: proc(p: ^Parser) -> []Expr {
	args: [dynamic]Expr
	if !check(p, .Right_Paren) {
		for {
			arg := expression(p)
			if len(args) == 255 {
				error(p, "Can't have more than 255 arguments.")
			}
			append(&args, arg)
			if !match(p, .Comma) {
				break
			}
		}
	}
	consume(p, .Right_Paren, "Expect ')' after arguments.")
	return args[:]
}

// dot covers all four forms dot() compiles today: plain `.name` read,
// `.name = expr` write, `.name <compound>= expr` compound write, and
// `.name(args)` invoke.
dot :: proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr {
	tok := p.previous
	consume(p, .Identifier, "Expect property name after '.'.")
	name := p.previous

	if can_assign && match(p, .Equal) {
		value := expression(p)
		return new_clone(Expr_Property{base = Node_Base{token = tok}, object = left, name = name, kind = .Set, value = value})
	}
	if can_assign {
		if op, ok := compound_assign_token(p.current.type); ok {
			advance(p)
			value := expression(p)
			return new_clone(
				Expr_Property{
					base = Node_Base{token = tok},
					object = left,
					name = name,
					kind = .Compound_Set,
					compound_op = op,
					value = value,
				},
			)
		}
	}
	if match(p, .Left_Paren) {
		args := argument_list(p)
		return new_clone(
			Expr_Property{base = Node_Base{token = tok}, object = left, name = name, kind = .Invoke, args = args},
		)
	}
	return new_clone(Expr_Property{base = Node_Base{token = tok}, object = left, name = name, kind = .Get})
}

// -----------------------------------------------------------------------
// Indexing & slicing

subscript :: proc(p: ^Parser, left: Expr, can_assign: bool) -> Expr {
	tok := p.previous
	if match(p, .Colon) {
		end := slice_end(p)
		return finish_subscript(p, tok, left, can_assign, true, nil, end)
	}

	first := expression(p) // single index, or a slice's start bound
	if match(p, .Colon) {
		end := slice_end(p)
		return finish_subscript(p, tok, left, can_assign, true, first, end)
	}
	consume(p, .Right_Bracket, "Expect ']' after index.")
	return finish_subscript(p, tok, left, can_assign, false, first, nil)
}

@(private = "file")
slice_end :: proc(p: ^Parser) -> Expr {
	if check(p, .Right_Bracket) {
		consume(p, .Right_Bracket, "Expect ']' after slice.")
		return nil // open end bound
	}
	e := expression(p)
	consume(p, .Right_Bracket, "Expect ']' after slice.")
	return e
}

@(private = "file")
finish_subscript :: proc(
	p: ^Parser,
	tok: Token,
	object: Expr,
	can_assign: bool,
	is_slice: bool,
	start_or_index: Expr,
	end: Expr,
) -> Expr {
	node := Expr_Subscript{base = Node_Base{token = tok}, object = object, is_slice = is_slice}
	if is_slice {
		node.slice_start = start_or_index
		node.slice_end = end
	} else {
		node.index = start_or_index
	}
	if can_assign && match(p, .Equal) {
		node.assign_value = expression(p)
	}
	return new_clone(node)
}

// -----------------------------------------------------------------------
// Collection literals

list_literal :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	elements: [dynamic]Expr
	if !check(p, .Right_Bracket) {
		for {
			append(&elements, expression(p))
			if !match(p, .Comma) {
				break
			}
			if check(p, .Right_Bracket) {
				break // trailing comma
			}
		}
	}
	consume(p, .Right_Bracket, "Expect ']' after list elements.")
	if len(elements) > 255 {
		error(p, "Can't have more than 255 items in a list literal.")
	}
	return new_clone(Expr_List{base = Node_Base{token = tok}, elements = elements[:]})
}

dict_literal :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous
	entries: [dynamic]Dict_Entry
	if !check(p, .Right_Brace) {
		for {
			key := expression(p)
			consume(p, .Colon, "Expect ':' after dict key.")
			value := expression(p)
			append(&entries, Dict_Entry{key = key, value = value})
			if !match(p, .Comma) {
				break
			}
			if check(p, .Right_Brace) {
				break
			}
		}
	}
	consume(p, .Right_Brace, "Expect '}' after dict elements.")
	if len(entries) > 255 {
		error(p, "Can't have more than 255 pairs in a dict literal.")
	}
	return new_clone(Expr_Dict{base = Node_Base{token = tok}, entries = entries[:]})
}

// -----------------------------------------------------------------------
// Lambdas

// lambda compiles `func(params) { body }` used as an expression --
// declared functions (stmt.odin's function_declaration) and class
// methods (stmt.odin's method) share the same parse_function_decl
// (functions.odin); only what surrounds the call differs.
lambda :: proc(p: ^Parser, can_assign: bool) -> Expr {
	tok := p.previous // 'func' token
	decl := parse_function_decl(p, .Function, synthetic_token(.Identifier, "<lambda>", tok.line))
	return new_clone(Expr_Lambda{base = Node_Base{token = tok}, decl = decl})
}
