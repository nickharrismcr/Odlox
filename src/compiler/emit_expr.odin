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
// component -- x/y/z/w, plus r/g/b/a as Vec4's color-channel aliases
// (see properties.odin's get_vec_swizzle/vec_with_field_set). Purely a
// lexical check on the field name token, since the compiler can't know
// at compile time whether a given property target actually holds a
// vector -- see emit_swizzle_set's own doc comment for why that's fine.
@(private = "file")
is_swizzle_field_name :: proc(name: string) -> bool {
	switch name {
	case "x", "y", "z", "w", "r", "g", "b", "a":
		return true
	}
	return false
}

// emit_property covers all four forms dot() compiles today: plain
// `.name` read, `.name = value` write, `.name <op>= value` compound
// write, and `.name(args)` invoke. A `.Set`/`.Compound_Set` whose field
// name could be a vec swizzle component is routed to emit_swizzle_set
// instead -- see its own doc comment.
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
		emit_op_byte(em, .Set_Property, name_const, line)
	case .Compound_Set:
		// Get_Property consumes the object reference on top of the stack,
		// but Set_Property needs it again afterward -- Dup keeps a copy
		// around for that second use, same as dot() today.
		emit_op(em, .Dup, line)
		emit_op_byte(em, .Get_Property, name_const, line)
		emit_property_cache(em, line)
		emit_expr(em, v.value)
		emit_op(em, compound_op_code(v.compound_op), line)
		emit_op_byte(em, .Set_Property, name_const, line)
	case .Invoke:
		for a in v.args {
			emit_expr(em, a)
		}
		emit_op_byte(em, .Invoke, name_const, line)
		emit_byte(em, u8(len(v.args)), line)
		emit_property_cache(em, line)
	case .Get:
		emit_op_byte(em, .Get_Property, name_const, line)
		emit_property_cache(em, line)
	}
}

// emit_swizzle_set compiles `<target>.f = value` and `<target>.f <op>=
// value` where f could be a vector component name -- see
// core/chunk.odin's Set_*_Vec_Field family and properties.odin's
// swizzle_assign for why this needs dedicated codegen instead of the
// ordinary Get/Set_Property path: <target>'s current value is always an
// inline copy (see core/value.odin's Value representation), not a
// shared heap reference, so a plain Get-then-Set_Property sequence has
// nothing to write a mutated vector back into -- and unlike a *read*
// (`v.x`) or any *other* field name, which never need write-back at
// all, an assignment does.
//
// The runtime (swizzle_assign) doesn't need to know at compile time
// whether <target> actually holds a vector -- Lox is dynamically typed,
// and if it turns out to be an Instance/Class/Module with a field
// genuinely named "x" or similar (by far the most common real case --
// see the Expr_This case below), these opcodes fall back to an ordinary
// field-set with no write-back needed (see run.odin's Set_*_Vec_Field
// handlers). What the compiler *does* need to know statically is
// <target>'s own shape, to emit the matching write-back half: a bare
// variable or `this` (v.object is Expr_Variable/Expr_This, both
// resolved by the Resolver same as any other read of them -- they need
// identical treatment, since `this` resolves exactly like a Local) or
// exactly one property access -- however its own object expression got
// there; that part is emitted as an ordinary opaque expression and
// Dup'd, so `this.pos.x`, `get_thing().pos.x`, and `a.b.c.pos.x` are all
// equally supported, since only the *last* link needs the write-back
// treatment. Anything else as the target -- indexing
// (`list[i].x = ...`), or the vector itself being a call's direct
// result (`get_vec().x = ...`) -- has no assignable storage location
// the write-back opcodes could target, so it's a compile error rather
// than a silently-lost mutation.
//
// Compound assignment (`v.x += 1`) additionally needs v.f's *current*
// value before combining with the RHS -- read via an ordinary
// Get_Property "f" on the same receiver the write-back half already has
// in hand (correct for both a vector receiver, via get_vec_swizzle, and
// an Instance/Class/Module receiver with a real field "f"), exactly
// mirroring how the ordinary (non-swizzle) `.Compound_Set` case below
// reads-before-writing through a Dup'd receiver.
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
