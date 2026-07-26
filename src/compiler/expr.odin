package compiler

import "../core"
import "core:fmt"
import "core:strconv"

// All prefix/infix expression parse functions the rule table (rules.odin)
// dispatches to. Each one assumes p.previous is the token that triggered
// it (standard Pratt-parser convention) and, for an infix function, that
// the left operand's bytecode has already been emitted.

// -----------------------------------------------------------------------
// Literals

int_literal :: proc(p: ^Parser, can_assign: bool) {
	v, ok := strconv.parse_i64(lexeme(p.previous))
	if !ok {
		error(p, "Invalid integer literal.")
		return
	}
	emit_constant(p, core.make_int_value(int(v)))
}

float_literal :: proc(p: ^Parser, can_assign: bool) {
	v, ok := strconv.parse_f64(lexeme(p.previous))
	if !ok {
		error(p, "Invalid float literal.")
		return
	}
	emit_constant(p, core.make_float_value(v))
}

// string_literal strips the surrounding quote bytes every String token
// carries (real or scanner-synthesized -- see scanner.odin's scan_string).
string_literal :: proc(p: ^Parser, can_assign: bool) {
	text := lexeme(p.previous)
	emit_constant(p, core.make_string_value(text[1:len(text) - 1]))
}

literal :: proc(p: ^Parser, can_assign: bool) {
	#partial switch p.previous.type {
	case .False:
		emit_op(p, .False)
	case .True:
		emit_op(p, .True)
	case .Nil:
		emit_op(p, .Nil)
	}
}

// str_call compiles the reserved `str(expr)` form straight to Op_Code.Str
// -- also what string interpolation desugars into (scanner.odin).
str_call :: proc(p: ^Parser, can_assign: bool) {
	consume(p, .Left_Paren, "Expect '(' after 'str'.")
	expression(p)
	consume(p, .Right_Paren, "Expect ')' after expression.")
	emit_op(p, .Str)
}

// -----------------------------------------------------------------------
// Grouping, unary, binary

// grouping handles both `(expr)` and a tuple literal `(a, b, ...)` --
// the two are distinguished by whether a comma follows the first
// expression, matching how `,`-terminated forms read naturally as
// tuples rather than needing a separate leading marker.
grouping :: proc(p: ^Parser, can_assign: bool) {
	if match(p, .Right_Paren) {
		emit_op_byte(p, .Create_Tuple, 0)
		return
	}
	expression(p)
	count := 1
	for match(p, .Comma) {
		if check(p, .Right_Paren) {
			break // trailing comma
		}
		expression(p)
		count += 1
	}
	consume(p, .Right_Paren, "Expect ')' after expression.")
	if count > 1 {
		if count > 255 {
			error(p, "Can't have more than 255 items in a tuple literal.")
		}
		emit_op_byte(p, .Create_Tuple, u8(count))
	}
}

unary :: proc(p: ^Parser, can_assign: bool) {
	op_type := p.previous.type
	parse_precedence(p, .Unary)
	#partial switch op_type {
	case .Minus:
		emit_op(p, .Negate)
	case .Bang:
		emit_op(p, .Not)
	}
}

// binary compiles a left-associative infix operator: everything at
// strictly higher precedence than this operator's own is folded into
// the right operand first (`+1` from the enum below its own level).
//
// The compiler can't know an operand's runtime type, so `+`/`++` pick
// *which* opcode to emit (Add_Numeric vs. Add_Vector) rather than
// deciding the actual arithmetic -- each opcode does its own runtime
// type check/dispatch (Phase 4). `<=`/`>=` have no opcode of their own;
// they compile as the flipped strict comparison plus Not, exactly like
// `!=` compiles as Equal+Not.
binary :: proc(p: ^Parser, can_assign: bool) {
	op_type := p.previous.type
	rule := get_rule(op_type)
	parse_precedence(p, Precedence(int(rule.precedence) + 1))

	#partial switch op_type {
	case .Plus:
		emit_op(p, .Add_Numeric)
	case .Plus_Plus:
		emit_op(p, .Add_Vector)
	case .Minus:
		emit_op(p, .Subtract)
	case .Star:
		emit_op(p, .Multiply)
	case .Slash:
		emit_op(p, .Divide)
	case .Percent:
		emit_op(p, .Modulus)
	case .Ampersand:
		emit_op(p, .Concat)
	case .Bang_Equal:
		emit_op(p, .Equal)
		emit_op(p, .Not)
	case .Equal_Equal:
		emit_op(p, .Equal)
	case .Greater:
		emit_op(p, .Greater)
	case .Greater_Equal:
		emit_op(p, .Less)
		emit_op(p, .Not)
	case .Less:
		emit_op(p, .Less)
	case .Less_Equal:
		emit_op(p, .Greater)
		emit_op(p, .Not)
	case .In:
		emit_op(p, .In)
	}
}

// -----------------------------------------------------------------------
// Short-circuiting and/or, ternary

and_ :: proc(p: ^Parser, can_assign: bool) {
	end_jump := emit_jump(p, .Jump_If_False)
	emit_op(p, .Pop)
	parse_precedence(p, .And)
	patch_jump(p, end_jump)
}

or_ :: proc(p: ^Parser, can_assign: bool) {
	else_jump := emit_jump(p, .Jump_If_False)
	end_jump := emit_jump(p, .Jump)
	patch_jump(p, else_jump)
	emit_op(p, .Pop)
	parse_precedence(p, .Or)
	patch_jump(p, end_jump)
}

// conditional compiles `cond ? then : else` as an infix operator on the
// already-parsed condition. The false branch parses at Conditional
// (not Assignment) precedence so `a ? b : c ? d : e` chains
// right-associatively rather than the outer `?:` swallowing the whole
// rest of the expression.
conditional :: proc(p: ^Parser, can_assign: bool) {
	then_jump := emit_jump(p, .Jump_If_False)
	emit_op(p, .Pop)
	parse_precedence(p, .Assignment)
	else_jump := emit_jump(p, .Jump)

	consume(p, .Colon, "Expect ':' after '?' branch.")
	patch_jump(p, then_jump)
	emit_op(p, .Pop)
	parse_precedence(p, .Conditional)
	patch_jump(p, else_jump)
}

// -----------------------------------------------------------------------
// Variables, assignment, compound assignment

variable :: proc(p: ^Parser, can_assign: bool) {
	named_variable(p, p.previous, can_assign)
}

// named_variable resolves name (local/upvalue/global -- see
// resolve_variable) and, if this reference is in assignable position,
// handles plain assignment and compound assignment (+= etc.) --
// otherwise it's a read.
named_variable :: proc(p: ^Parser, name: Token, can_assign: bool) {
	// name's own lexeme is captured up front, not re-derived from `name`
	// later in this proc: name is a Token value that (empirically, in
	// this compiler's build) does not stay stable across a subsequent
	// advance(p) call in the same frame -- the compound-assignment
	// branch below saw name.type flip from Identifier to Plus_Equal
	// after its own advance(p) despite name being passed by value, which
	// meant the "Cannot assign to const 'a'" message came out as
	// "Cannot assign to const '+='" instead. Grabbing the string once,
	// immediately, sidesteps whatever is going on there.
	name_lexeme := lexeme(name)
	arg, get_op, set_op := resolve_variable(p, name)
	is_const_local := get_op == .Get_Local && p.current_compiler.locals[arg].is_const

	if can_assign && match(p, .Equal) {
		if is_const_local {
			error(p, fmt.tprintf("Cannot assign to const '%s'.", name_lexeme))
		}
		expression(p)
		emit_op_byte(p, set_op, u8(arg))
		return
	}
	if can_assign {
		if op, ok := compound_assign_op(p.current.type); ok {
			advance(p) // consume the += / -= / *= / /= / %= token
			if is_const_local {
				error(p, fmt.tprintf("Cannot assign to const '%s'.", name_lexeme))
			}
			emit_op_byte(p, get_op, u8(arg))
			expression(p)
			emit_op(p, op)
			emit_op_byte(p, set_op, u8(arg))
			return
		}
	}
	emit_op_byte(p, get_op, u8(arg))
}

@(private = "file")
compound_assign_op :: proc(t: Token_Type) -> (core.Op_Code, bool) {
	#partial switch t {
	case .Plus_Equal:
		return .Add_Numeric, true
	case .Minus_Equal:
		return .Subtract, true
	case .Star_Equal:
		return .Multiply, true
	case .Slash_Equal:
		return .Divide, true
	case .Percent_Equal:
		return .Modulus, true
	}
	return .Noop, false
}

// -----------------------------------------------------------------------
// this / super

this_ :: proc(p: ^Parser, can_assign: bool) {
	if p.current_class == nil {
		error(p, "Can't use 'this' outside of a class.")
		return
	}
	named_variable(p, p.previous, false) // read-only: `this` can't be an assignment target
}

super_ :: proc(p: ^Parser, can_assign: bool) {
	if p.current_class == nil {
		error(p, "Can't use 'super' outside of a class.")
	} else if !p.current_class.has_superclass {
		error(p, "Can't use 'super' in a class with no superclass.")
	}

	consume(p, .Dot, "Expect '.' after 'super'.")
	consume(p, .Identifier, "Expect superclass method name.")
	name_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(lexeme(p.previous)))

	push_named(p, "this")
	if match(p, .Left_Paren) {
		arg_count := argument_list(p)
		push_named(p, "super")
		emit_op_byte(p, .Super_Invoke, name_const)
		emit_byte(p, arg_count)
	} else {
		push_named(p, "super")
		emit_op_byte(p, .Get_Super, name_const)
	}
}

// push_named emits a Get for the local/upvalue named `name` (always
// `this`/`super`, both declared as synthetic locals during class/method
// compilation -- see stmt.odin's class_declaration and
// compiler_state.odin's init_function_compiler).
@(private = "file")
push_named :: proc(p: ^Parser, name: string) {
	arg, get_op, _ := resolve_variable(p, synthetic_token(.Identifier, name, p.previous.line))
	emit_op_byte(p, get_op, u8(arg))
}

// -----------------------------------------------------------------------
// Calls, property access

call :: proc(p: ^Parser, can_assign: bool) {
	arg_count := argument_list(p)
	emit_op_byte(p, .Call, arg_count)
}

argument_list :: proc(p: ^Parser) -> u8 {
	count := 0
	if !check(p, .Right_Paren) {
		for {
			expression(p)
			if count == 255 {
				error(p, "Can't have more than 255 arguments.")
			}
			count += 1
			if !match(p, .Comma) {
				break
			}
		}
	}
	consume(p, .Right_Paren, "Expect ')' after arguments.")
	return u8(count)
}

// dot compiles `.name`, `.name = expr`, `.name <compound>= expr`, and
// `.name(args)` (a method invoke, via Op_Code.Invoke rather than a
// separate Get_Property+Call -- the VM's fast path for the common case).
dot :: proc(p: ^Parser, can_assign: bool) {
	consume(p, .Identifier, "Expect property name after '.'.")
	name_const := core.chunk_add_constant(current_chunk(p), core.make_string_value(lexeme(p.previous)))

	if can_assign && match(p, .Equal) {
		expression(p)
		emit_op_byte(p, .Set_Property, name_const)
		return
	}
	if can_assign {
		if op, ok := compound_assign_op(p.current.type); ok {
			advance(p)
			// Get_Property consumes the object reference on top of the
			// stack, but Set_Property needs it again afterward -- Dup
			// keeps a copy around for that second use.
			emit_op(p, .Dup)
			emit_op_byte(p, .Get_Property, name_const)
			expression(p)
			emit_op(p, op)
			emit_op_byte(p, .Set_Property, name_const)
			return
		}
	}
	if match(p, .Left_Paren) {
		arg_count := argument_list(p)
		emit_op_byte(p, .Invoke, name_const)
		emit_byte(p, arg_count)
		return
	}
	emit_op_byte(p, .Get_Property, name_const)
}

// -----------------------------------------------------------------------
// Indexing & slicing
//
// Stack convention (this port's own choice, since both compiler and VM
// are implemented here): the indexed/sliced object is already on the
// stack (its own expression compiled before subscript() ever runs, as
// the infix operator's left operand); subscript then pushes start
// (Nil if the bound before `:` was omitted) and, for a slice, end
// (Nil if the bound after `:` was omitted) on top of it, in that order.

subscript :: proc(p: ^Parser, can_assign: bool) {
	if match(p, .Colon) {
		emit_op(p, .Nil) // open start bound
		emit_slice_end(p)
		finish_subscript(p, can_assign, true)
		return
	}

	expression(p) // single index, or a slice's start bound
	if match(p, .Colon) {
		emit_slice_end(p)
		finish_subscript(p, can_assign, true)
		return
	}
	consume(p, .Right_Bracket, "Expect ']' after index.")
	finish_subscript(p, can_assign, false)
}

@(private = "file")
emit_slice_end :: proc(p: ^Parser) {
	if check(p, .Right_Bracket) {
		emit_op(p, .Nil) // open end bound
	} else {
		expression(p)
	}
	consume(p, .Right_Bracket, "Expect ']' after slice.")
}

@(private = "file")
finish_subscript :: proc(p: ^Parser, can_assign: bool, is_slice: bool) {
	if can_assign && match(p, .Equal) {
		expression(p)
		emit_op(p, .Slice_Assign if is_slice else .Index_Assign)
		return
	}
	emit_op(p, .Slice if is_slice else .Index)
}

// -----------------------------------------------------------------------
// Collection literals

list_literal :: proc(p: ^Parser, can_assign: bool) {
	count := 0
	if !check(p, .Right_Bracket) {
		for {
			expression(p)
			count += 1
			if !match(p, .Comma) {
				break
			}
			if check(p, .Right_Bracket) {
				break // trailing comma
			}
		}
	}
	consume(p, .Right_Bracket, "Expect ']' after list elements.")
	if count > 255 {
		error(p, "Can't have more than 255 items in a list literal.")
	}
	emit_op_byte(p, .Create_List, u8(count))
}

// dict_literal emits key-expr, value-expr pairs -- keys are ordinary
// expressions at compile time; whether a given key Value is usable
// (i.e. a string) is a runtime check (Phase 4's Op_Code.Create_Dict
// handler), same as core.Dict_Object requiring string keys.
dict_literal :: proc(p: ^Parser, can_assign: bool) {
	count := 0
	if !check(p, .Right_Brace) {
		for {
			expression(p)
			consume(p, .Colon, "Expect ':' after dict key.")
			expression(p)
			count += 1
			if !match(p, .Comma) {
				break
			}
			if check(p, .Right_Brace) {
				break
			}
		}
	}
	consume(p, .Right_Brace, "Expect '}' after dict elements.")
	if count > 255 {
		error(p, "Can't have more than 255 pairs in a dict literal.")
	}
	emit_op_byte(p, .Create_Dict, u8(count))
}

// -----------------------------------------------------------------------
// Lambdas

// lambda compiles `func(params) { body }` used as an expression -- the
// closure it produces is left as this expression's value. Declared
// functions (stmt.odin's function_declaration) and class methods
// (stmt.odin's method) share the same underlying compile_function
// (functions.odin); only what surrounds the call differs.
lambda :: proc(p: ^Parser, can_assign: bool) {
	init_function_compiler(p, .Function, "<lambda>")
	compile_function(p)
}
