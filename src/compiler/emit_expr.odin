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
		emit_op(em, .Str, v.token.line)
	case ^Expr_Tuple:
		for el in v.elements {
			emit_expr(em, el)
		}
		emit_op_byte(em, .Create_Tuple, u8(len(v.elements)), v.token.line)
	case ^Expr_Unary:
		emit_expr(em, v.operand)
		#partial switch v.op {
		case .Minus:
			emit_op(em, .Negate, v.token.line)
		case .Bang:
			emit_op(em, .Not, v.token.line)
		}
	case ^Expr_Binary:
		emit_binary(em, v)
	case ^Expr_Logical:
		emit_logical(em, v)
	case ^Expr_Conditional:
		emit_conditional(em, v)
	case ^Expr_Variable:
		emit_op_byte(em, get_op_for_ref(v.resolved.kind), u8(v.resolved.slot), v.token.line)
	case ^Expr_Assign:
		emit_assign(em, v)
	case ^Expr_This:
		emit_op_byte(em, get_op_for_ref(v.resolved.kind), u8(v.resolved.slot), v.token.line)
	case ^Expr_Super:
		emit_super(em, v)
	case ^Expr_Call:
		emit_expr(em, v.callee)
		for a in v.args {
			emit_expr(em, a)
		}
		emit_op_byte(em, .Call, u8(len(v.args)), v.token.line)
	case ^Expr_Property:
		emit_property(em, v)
	case ^Expr_Subscript:
		emit_subscript(em, v)
	case ^Expr_List:
		for el in v.elements {
			emit_expr(em, el)
		}
		emit_op_byte(em, .Create_List, u8(len(v.elements)), v.token.line)
	case ^Expr_Dict:
		for entry in v.entries {
			emit_expr(em, entry.key)
			emit_expr(em, entry.value)
		}
		emit_op_byte(em, .Create_Dict, u8(len(v.entries)), v.token.line)
	case ^Expr_Lambda:
		emit_function_decl(em, v.decl, "<lambda>")
	}
}

@(private = "file")
emit_literal :: proc(em: ^Emitter, v: ^Expr_Literal) {
	line := v.token.line
	switch v.kind {
	case .Int, .Float, .String:
		emit_constant(em, v.value, line)
	case .Bool:
		if core.as_bool(v.value) {
			emit_op(em, .True, line)
		} else {
			emit_op(em, .False, line)
		}
	case .Nil:
		emit_op(em, .Nil, line)
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
		emit_op(em, .Add_Numeric, line)
	case .Plus_Plus:
		emit_op(em, .Add_Vector, line)
	case .Minus:
		emit_op(em, .Subtract, line)
	case .Star:
		emit_op(em, .Multiply, line)
	case .Slash:
		emit_op(em, .Divide, line)
	case .Percent:
		emit_op(em, .Modulus, line)
	case .Ampersand:
		emit_op(em, .Concat, line)
	case .Bang_Equal:
		emit_op(em, .Equal, line)
		emit_op(em, .Not, line)
	case .Equal_Equal:
		emit_op(em, .Equal, line)
	case .Greater:
		emit_op(em, .Greater, line)
	case .Greater_Equal:
		emit_op(em, .Less, line)
		emit_op(em, .Not, line)
	case .Less:
		emit_op(em, .Less, line)
	case .Less_Equal:
		emit_op(em, .Greater, line)
		emit_op(em, .Not, line)
	case .In:
		emit_op(em, .In, line)
	}
}

@(private = "file")
emit_logical :: proc(em: ^Emitter, v: ^Expr_Logical) {
	line := v.token.line
	emit_expr(em, v.left)
	if v.op == .And {
		end_jump := emit_jump(em, .Jump_If_False, line)
		emit_op(em, .Pop, line)
		emit_expr(em, v.right)
		patch_jump(em, end_jump, line)
	} else { // .Or
		else_jump := emit_jump(em, .Jump_If_False, line)
		end_jump := emit_jump(em, .Jump, line)
		patch_jump(em, else_jump, line)
		emit_op(em, .Pop, line)
		emit_expr(em, v.right)
		patch_jump(em, end_jump, line)
	}
}

@(private = "file")
emit_conditional :: proc(em: ^Emitter, v: ^Expr_Conditional) {
	line := v.token.line
	emit_expr(em, v.condition)
	then_jump := emit_jump(em, .Jump_If_False, line)
	emit_op(em, .Pop, line)
	emit_expr(em, v.then_branch)
	else_jump := emit_jump(em, .Jump, line)

	patch_jump(em, then_jump, line)
	emit_op(em, .Pop, line)
	emit_expr(em, v.else_branch)
	patch_jump(em, else_jump, line)
}

@(private = "file")
emit_assign :: proc(em: ^Emitter, v: ^Expr_Assign) {
	line := v.token.line
	slot := u8(v.resolved.slot)
	if v.is_compound {
		emit_op_byte(em, get_op_for_ref(v.resolved.kind), slot, line)
		emit_expr(em, v.value)
		emit_op(em, compound_op_code(v.compound_op), line)
		emit_op_byte(em, set_op_for_ref(v.resolved.kind), slot, line)
	} else {
		emit_expr(em, v.value)
		emit_op_byte(em, set_op_for_ref(v.resolved.kind), slot, line)
	}
}

@(private = "file")
emit_super :: proc(em: ^Emitter, v: ^Expr_Super) {
	line := v.token.line
	name_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(v.method_name)))
	emit_op_byte(em, get_op_for_ref(v.this_ref.kind), u8(v.this_ref.slot), line)
	if v.has_args {
		for a in v.args {
			emit_expr(em, a)
		}
		emit_op_byte(em, get_op_for_ref(v.super_ref.kind), u8(v.super_ref.slot), line)
		emit_op_byte(em, .Super_Invoke, name_const, line)
		emit_byte(em, u8(len(v.args)), line)
	} else {
		emit_op_byte(em, get_op_for_ref(v.super_ref.kind), u8(v.super_ref.slot), line)
		emit_op_byte(em, .Get_Super, name_const, line)
	}
}

// is_swizzle_field_name reports whether name could name a vec2/3/4
// component: x/y/z/w, plus r/g/b/a as Vec4's color-channel aliases. Purely
// a lexical check, since the compiler can't know at compile time whether a
// property target actually holds a vector. Package-private: resolve.odin's
// discover_field_slots needs the same exclusion so `this.x = ...` inside
// init never gets baked into a field slot, letting swizzle write-back
// still run for it.
@(private)
is_swizzle_field_name :: proc(name: string) -> bool {
	switch name {
	case "x", "y", "z", "w", "r", "g", "b", "a":
		return true
	}
	return false
}

// emit_property covers all four forms: plain `.name` read, `.name = value`
// write, `.name <op>= value` compound write, and `.name(args)` invoke. A
// `.Set`/`.Compound_Set` field name that could be a vec swizzle component
// routes to emit_swizzle_set instead. v.field_slot >= 0 means this is a
// `this.name` access to a compile-time-discovered field slot -- emit
// Get_Field_Slot/Set_Field_Slot instead of Get_Property/Set_Property;
// never true for .Invoke.
@(private = "file")
emit_property :: proc(em: ^Emitter, v: ^Expr_Property) {
	line := v.token.line
	name_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(v.name)))

	if is_swizzle_field_name(lexeme(v.name)) {
		#partial switch v.kind {
		case .Set, .Compound_Set:
			emit_swizzle_set(em, v, name_const, line)
			return
		}
	}

	emit_expr(em, v.object)
	switch v.kind {
	case .Set:
		emit_expr(em, v.value)
		if v.field_slot >= 0 {
			emit_op_byte(em, .Set_Field_Slot, u8(v.field_slot), line)
			emit_byte(em, name_const, line)
		} else {
			emit_op_byte(em, .Set_Property, name_const, line)
		}
	case .Compound_Set:
		// Get_Property/Get_Field_Slot consumes the object reference on top
		// of the stack, but Set_Property/Set_Field_Slot needs it again
		// afterward -- Dup keeps a copy around for that second use, same as
		// dot() today.
		emit_op(em, .Dup, line)
		if v.field_slot >= 0 {
			emit_op_byte(em, .Get_Field_Slot, u8(v.field_slot), line)
			emit_byte(em, name_const, line)
		} else {
			emit_op_byte(em, .Get_Property, name_const, line)
		}
		emit_property_cache(em, line)
		emit_expr(em, v.value)
		emit_op(em, compound_op_code(v.compound_op), line)
		if v.field_slot >= 0 {
			emit_op_byte(em, .Set_Field_Slot, u8(v.field_slot), line)
			emit_byte(em, name_const, line)
		} else {
			emit_op_byte(em, .Set_Property, name_const, line)
		}
	case .Invoke:
		for a in v.args {
			emit_expr(em, a)
		}
		emit_op_byte(em, .Invoke, name_const, line)
		emit_byte(em, u8(len(v.args)), line)
		emit_property_cache(em, line)
	case .Get:
		if v.field_slot >= 0 {
			emit_op_byte(em, .Get_Field_Slot, u8(v.field_slot), line)
			emit_byte(em, name_const, line)
		} else {
			emit_op_byte(em, .Get_Property, name_const, line)
		}
		emit_property_cache(em, line)
	}
}

// emit_swizzle_set compiles `<target>.f = value` and `<target>.f <op>=
// value` where f could be a vector component name (core/chunk.odin's
// Set_*_Vec_Field family). A vector value is an inline copy, not a heap
// reference, so plain Get-then-Set_Property has nothing to write the
// mutation back into; the opcodes fall back to an ordinary field-set if
// <target> isn't a vector. <target> must be a bare variable, `this`, or
// one property access -- indexing or a call result is a compile error.
@(private = "file")
emit_swizzle_set :: proc(em: ^Emitter, v: ^Expr_Property, field_name_const: u8, line: int) {
	is_compound := v.kind == .Compound_Set

	// emit_new_value emits whatever should end up as the top-of-stack
	// scalar to write into the swizzle field: just the RHS for a plain
	// `.Set`, or (current field value <op> RHS) for `.Compound_Set` --
	// current_value_op, if is_compound, must already have pushed the
	// receiver's current whole value (so Get_Property can read the old
	// field value off it) and leaves nothing else behind.
	emit_new_value :: proc(em: ^Emitter, v: ^Expr_Property, field_name_const: u8, is_compound: bool, line: int) {
		if is_compound {
			emit_op_byte(em, .Get_Property, field_name_const, line)
			emit_property_cache(em, line)
			emit_expr(em, v.value)
			emit_op(em, compound_op_code(v.compound_op), line)
		} else {
			emit_expr(em, v.value)
		}
	}

	#partial switch obj in v.object {
	case ^Expr_Variable, ^Expr_This:
		resolved: Var_Ref
		#partial switch o in obj {
		case ^Expr_Variable: resolved = o.resolved
		case ^Expr_This: resolved = o.resolved
		}
		if is_compound {
			emit_op_byte(em, get_op_for_ref(resolved.kind), u8(resolved.slot), line)
		}
		emit_new_value(em, v, field_name_const, is_compound, line)
		op := set_vec_field_op_for_ref(resolved.kind)
		emit_op_byte(em, op, u8(resolved.slot), line)
		emit_byte(em, field_name_const, line)
	case ^Expr_Property:
		if obj.kind != .Get {
			emit_error(em, line, "cannot assign to a vector component of this expression -- store it in a variable first.")
			return
		}
		outer_name_const := core.chunk_add_constant(current_chunk(em), core.make_interned_string_value(lexeme(obj.name)))
		emit_expr(em, obj.object)
		emit_op(em, .Dup, line)
		emit_op_byte(em, .Get_Property, outer_name_const, line)
		emit_property_cache(em, line)
		if is_compound {
			emit_op(em, .Dup, line)
		}
		emit_new_value(em, v, field_name_const, is_compound, line)
		emit_op_byte(em, .Set_Property_Vec_Field, outer_name_const, line)
		emit_byte(em, field_name_const, line)
	case:
		emit_error(em, line, "cannot assign to a vector component of this expression -- store it in a variable first.")
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
			emit_op(em, .Nil, line)
		}
		if v.slice_end != nil {
			emit_expr(em, v.slice_end)
		} else {
			emit_op(em, .Nil, line)
		}
		if v.assign_value != nil {
			emit_expr(em, v.assign_value)
			emit_op(em, .Slice_Assign, line)
		} else {
			emit_op(em, .Slice, line)
		}
		return
	}
	emit_expr(em, v.index)
	if v.assign_value != nil {
		emit_expr(em, v.assign_value)
		emit_op(em, .Index_Assign, line)
	} else {
		emit_op(em, .Index, line)
	}
}
