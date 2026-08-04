package compiler

import "../core"

// AST-walking counterparts to expr.odin's prefix/infix Pratt functions --
// see emit.odin's header comment. Every resolution decision (which slot,
// local/upvalue/global, which opcode) already lives on the node courtesy
// of the Resolver (implementation phase 4); this only ever turns that
// into bytes.

emit_expr :: proc(em: ^Emitter, e: Expr) {
	if e == nil {
		return
	}
	switch v in e {
	case ^Expr_Literal:
		emit_literal(em, v)
	case ^Expr_Str_Call:
		emit_expr(em, v.inner)
		emit_op_em(em, .Str, v.token.line)
	case ^Expr_Tuple:
		for el in v.elements {
			emit_expr(em, el)
		}
		emit_op_byte_em(em, .Create_Tuple, u8(len(v.elements)), v.token.line)
	case ^Expr_Unary:
		emit_expr(em, v.operand)
		#partial switch v.op {
		case .Minus:
			emit_op_em(em, .Negate, v.token.line)
		case .Bang:
			emit_op_em(em, .Not, v.token.line)
		}
	case ^Expr_Binary:
		emit_binary(em, v)
	case ^Expr_Logical:
		emit_logical(em, v)
	case ^Expr_Conditional:
		emit_conditional(em, v)
	case ^Expr_Variable:
		emit_op_byte_em(em, get_op_for_ref(v.resolved.kind), u8(v.resolved.slot), v.token.line)
	case ^Expr_Assign:
		emit_assign(em, v)
	case ^Expr_This:
		emit_op_byte_em(em, get_op_for_ref(v.resolved.kind), u8(v.resolved.slot), v.token.line)
	case ^Expr_Super:
		emit_super(em, v)
	case ^Expr_Call:
		emit_expr(em, v.callee)
		for a in v.args {
			emit_expr(em, a)
		}
		emit_op_byte_em(em, .Call, u8(len(v.args)), v.token.line)
	case ^Expr_Property:
		emit_property(em, v)
	case ^Expr_Subscript:
		emit_subscript(em, v)
	case ^Expr_List:
		for el in v.elements {
			emit_expr(em, el)
		}
		emit_op_byte_em(em, .Create_List, u8(len(v.elements)), v.token.line)
	case ^Expr_Dict:
		for entry in v.entries {
			emit_expr(em, entry.key)
			emit_expr(em, entry.value)
		}
		emit_op_byte_em(em, .Create_Dict, u8(len(v.entries)), v.token.line)
	case ^Expr_Lambda:
		emit_function_decl(em, v.decl, "<lambda>")
	}
}

@(private = "file")
emit_literal :: proc(em: ^Emitter, v: ^Expr_Literal) {
	line := v.token.line
	switch v.kind {
	case .Int, .Float, .String:
		emit_constant_em(em, v.value, line)
	case .Bool:
		if core.as_bool(v.value) {
			emit_op_em(em, .True, line)
		} else {
			emit_op_em(em, .False, line)
		}
	case .Nil:
		emit_op_em(em, .Nil, line)
	}
}

// emit_binary compiles a left-associative infix operator -- both operands
// are already fully parsed subtrees by this point, so unlike binary()
// there's no precedence-climbing left to do, just emit left, right, op.
@(private = "file")
emit_binary :: proc(em: ^Emitter, v: ^Expr_Binary) {
	emit_expr(em, v.left)
	emit_expr(em, v.right)
	line := v.token.line
	#partial switch v.op {
	case .Plus:
		emit_op_em(em, .Add_Numeric, line)
	case .Plus_Plus:
		emit_op_em(em, .Add_Vector, line)
	case .Minus:
		emit_op_em(em, .Subtract, line)
	case .Star:
		emit_op_em(em, .Multiply, line)
	case .Slash:
		emit_op_em(em, .Divide, line)
	case .Percent:
		emit_op_em(em, .Modulus, line)
	case .Ampersand:
		emit_op_em(em, .Concat, line)
	case .Bang_Equal:
		emit_op_em(em, .Equal, line)
		emit_op_em(em, .Not, line)
	case .Equal_Equal:
		emit_op_em(em, .Equal, line)
	case .Greater:
		emit_op_em(em, .Greater, line)
	case .Greater_Equal:
		emit_op_em(em, .Less, line)
		emit_op_em(em, .Not, line)
	case .Less:
		emit_op_em(em, .Less, line)
	case .Less_Equal:
		emit_op_em(em, .Greater, line)
		emit_op_em(em, .Not, line)
	case .In:
		emit_op_em(em, .In, line)
	}
}

@(private = "file")
emit_logical :: proc(em: ^Emitter, v: ^Expr_Logical) {
	line := v.token.line
	emit_expr(em, v.left)
	if v.op == .And {
		end_jump := emit_jump_em(em, .Jump_If_False, line)
		emit_op_em(em, .Pop, line)
		emit_expr(em, v.right)
		patch_jump_em(em, end_jump, line)
	} else { // .Or
		else_jump := emit_jump_em(em, .Jump_If_False, line)
		end_jump := emit_jump_em(em, .Jump, line)
		patch_jump_em(em, else_jump, line)
		emit_op_em(em, .Pop, line)
		emit_expr(em, v.right)
		patch_jump_em(em, end_jump, line)
	}
}

@(private = "file")
emit_conditional :: proc(em: ^Emitter, v: ^Expr_Conditional) {
	line := v.token.line
	emit_expr(em, v.condition)
	then_jump := emit_jump_em(em, .Jump_If_False, line)
	emit_op_em(em, .Pop, line)
	emit_expr(em, v.then_branch)
	else_jump := emit_jump_em(em, .Jump, line)

	patch_jump_em(em, then_jump, line)
	emit_op_em(em, .Pop, line)
	emit_expr(em, v.else_branch)
	patch_jump_em(em, else_jump, line)
}

@(private = "file")
emit_assign :: proc(em: ^Emitter, v: ^Expr_Assign) {
	line := v.token.line
	slot := u8(v.resolved.slot)
	if v.is_compound {
		emit_op_byte_em(em, get_op_for_ref(v.resolved.kind), slot, line)
		emit_expr(em, v.value)
		emit_op_em(em, compound_op_code(v.compound_op), line)
		emit_op_byte_em(em, set_op_for_ref(v.resolved.kind), slot, line)
	} else {
		emit_expr(em, v.value)
		emit_op_byte_em(em, set_op_for_ref(v.resolved.kind), slot, line)
	}
}

@(private = "file")
emit_super :: proc(em: ^Emitter, v: ^Expr_Super) {
	line := v.token.line
	name_const := core.chunk_add_constant(current_chunk_em(em), core.make_interned_string_value(lexeme(v.method_name)))
	emit_op_byte_em(em, get_op_for_ref(v.this_ref.kind), u8(v.this_ref.slot), line)
	if v.has_args {
		for a in v.args {
			emit_expr(em, a)
		}
		emit_op_byte_em(em, get_op_for_ref(v.super_ref.kind), u8(v.super_ref.slot), line)
		emit_op_byte_em(em, .Super_Invoke, name_const, line)
		emit_byte_em(em, u8(len(v.args)), line)
	} else {
		emit_op_byte_em(em, get_op_for_ref(v.super_ref.kind), u8(v.super_ref.slot), line)
		emit_op_byte_em(em, .Get_Super, name_const, line)
	}
}

// emit_property covers all four forms dot() compiles today: plain
// `.name` read, `.name = value` write, `.name <op>= value` compound
// write, and `.name(args)` invoke.
@(private = "file")
emit_property :: proc(em: ^Emitter, v: ^Expr_Property) {
	line := v.token.line
	emit_expr(em, v.object)
	name_const := core.chunk_add_constant(current_chunk_em(em), core.make_interned_string_value(lexeme(v.name)))
	switch v.kind {
	case .Set:
		emit_expr(em, v.value)
		emit_op_byte_em(em, .Set_Property, name_const, line)
	case .Compound_Set:
		// Get_Property consumes the object reference on top of the stack,
		// but Set_Property needs it again afterward -- Dup keeps a copy
		// around for that second use, same as dot() today.
		emit_op_em(em, .Dup, line)
		emit_op_byte_em(em, .Get_Property, name_const, line)
		emit_property_cache_em(em, line)
		emit_expr(em, v.value)
		emit_op_em(em, compound_op_code(v.compound_op), line)
		emit_op_byte_em(em, .Set_Property, name_const, line)
	case .Invoke:
		for a in v.args {
			emit_expr(em, a)
		}
		emit_op_byte_em(em, .Invoke, name_const, line)
		emit_byte_em(em, u8(len(v.args)), line)
		emit_property_cache_em(em, line)
	case .Get:
		emit_op_byte_em(em, .Get_Property, name_const, line)
		emit_property_cache_em(em, line)
	}
}

// emit_subscript covers all four forms subscript()/finish_subscript()
// compile today: index read/write and slice read/write. An absent
// slice_start/slice_end (open bound) pushes Nil, same as emit_slice_end.
@(private = "file")
emit_subscript :: proc(em: ^Emitter, v: ^Expr_Subscript) {
	line := v.token.line
	emit_expr(em, v.object)
	if v.is_slice {
		if v.slice_start != nil {
			emit_expr(em, v.slice_start)
		} else {
			emit_op_em(em, .Nil, line)
		}
		if v.slice_end != nil {
			emit_expr(em, v.slice_end)
		} else {
			emit_op_em(em, .Nil, line)
		}
		if v.assign_value != nil {
			emit_expr(em, v.assign_value)
			emit_op_em(em, .Slice_Assign, line)
		} else {
			emit_op_em(em, .Slice, line)
		}
		return
	}
	emit_expr(em, v.index)
	if v.assign_value != nil {
		emit_expr(em, v.assign_value)
		emit_op_em(em, .Index_Assign, line)
	} else {
		emit_op_em(em, .Index, line)
	}
}
