package vm

import "../core"
import "core:math"
import "core:strings"

// Numeric/string/vector binary operators. The compiler can't know an
// operand's runtime type (see expr.odin's binary doc comment in the
// compiler package), so each of these does its own type check/dispatch
// at the opcode level.

add_numeric :: proc(vm: ^VM) -> bool {
	b := pop(vm)
	a := pop(vm)
	if !core.is_number(a) || !core.is_number(b) {
		runtime_error(vm, "Operands must be numbers.")
		return false
	}
	if a.type == .Int && b.type == .Int {
		push(vm, core.make_int_value(core.as_int(a) + core.as_int(b)))
	} else {
		push(vm, core.make_float_value(core.as_float(a) + core.as_float(b)))
	}
	return true
}

// concat handles `&`: string+string or list+list only (not, e.g.,
// number-to-string coercion -- that's what Op_Str/`str(...)` is for).
concat :: proc(vm: ^VM) -> bool {
	b := pop(vm)
	a := pop(vm)
	if core.is_string(a) && core.is_string(b) {
		sa := core.string_get(core.as_string(a))
		sb := core.string_get(core.as_string(b))
		push(vm, core.make_string_value(strings.concatenate({sa, sb})))
		return true
	}
	if a.type == .Obj && a.obj_type == .List && b.type == .Obj && b.obj_type == .List {
		la, lb := core.as_list(a), core.as_list(b)
		items := make([dynamic]core.Value, 0, len(la.items) + len(lb.items))
		append(&items, ..la.items[:])
		append(&items, ..lb.items[:])
		result := core.make_list_object(items)
		gc_track(vm, &result.obj)
		push(vm, core.make_object_value(&result.obj))
		return true
	}
	runtime_error(vm, "Operands must be two strings or two lists.")
	return false
}

add_vector :: proc(vm: ^VM) -> bool {
	b := pop(vm)
	a := pop(vm)
	if a.type != b.type {
		runtime_error(vm, "Vector operands must be the same type.")
		return false
	}
	#partial switch a.type {
	case .Vec2:
		av, bv := core.as_vec2(a), core.as_vec2(b)
		push_vec2(vm, av.x + bv.x, av.y + bv.y)
	case .Vec3:
		av, bv := core.as_vec3(a), core.as_vec3(b)
		push_vec3(vm, av.x + bv.x, av.y + bv.y, av.z + bv.z)
	case .Vec4:
		av, bv := core.as_vec4(a), core.as_vec4(b)
		push_vec4(vm, av.x + bv.x, av.y + bv.y, av.z + bv.z, av.w + bv.w)
	case:
		runtime_error(vm, "Operands must be vectors.")
		return false
	}
	return true
}

push_vec2 :: proc(vm: ^VM, x, y: f64) {
	o := alloc_vec2(vm, x, y)
	push(vm, core.Value{type = .Vec2, obj_type = .Vec2, obj = &o.obj})
}
push_vec3 :: proc(vm: ^VM, x, y, z: f64) {
	o := alloc_vec3(vm, x, y, z)
	push(vm, core.Value{type = .Vec3, obj_type = .Vec3, obj = &o.obj})
}
push_vec4 :: proc(vm: ^VM, x, y, z, w: f64) {
	o := alloc_vec4(vm, x, y, z, w)
	push(vm, core.Value{type = .Vec4, obj_type = .Vec4, obj = &o.obj})
}

// string_multiply returns an empty string for count <= 0 rather than
// deferring to core:strings' own repeat(), which panics on a negative
// count -- that would crash the whole process on `"x" * -1` instead of
// just producing an empty string.
@(private = "file")
string_multiply :: proc(s: string, count: int) -> string {
	if count <= 0 {
		return ""
	}
	result, _ := strings.repeat(s, count)
	return result
}

// numeric_binop implements Subtract/Multiply/Divide/Modulus -- Add has
// its own proc (add_numeric) since it's hot enough to warrant the
// compile-time peephole fusion (Add_Nn/Incr_Const_N) that specifically
// targets it.
numeric_binop :: proc(vm: ^VM, op: core.Op_Code) -> bool {
	b := pop(vm)
	a := pop(vm)
	// Vector subtraction: unlike `+`, which is split into a numeric-only
	// Add_Numeric and a vector-only Add_Vector (`++`) at the compiler
	// level (see compiler/expr.odin's binary doc comment), `-` has no
	// separate vector token, so it stays one operator here that
	// dispatches on runtime operand type.
	if op == .Subtract {
		a_is_vec := a.type == .Vec2 || a.type == .Vec3 || a.type == .Vec4
		b_is_vec := b.type == .Vec2 || b.type == .Vec3 || b.type == .Vec4
		if a_is_vec || b_is_vec {
			if a.type != b.type {
				runtime_error(vm, "Vector operands must be the same type.")
				return false
			}
			#partial switch a.type {
			case .Vec2:
				av, bv := core.as_vec2(a), core.as_vec2(b)
				push_vec2(vm, av.x - bv.x, av.y - bv.y)
			case .Vec3:
				av, bv := core.as_vec3(a), core.as_vec3(b)
				push_vec3(vm, av.x - bv.x, av.y - bv.y, av.z - bv.z)
			case .Vec4:
				av, bv := core.as_vec4(a), core.as_vec4(b)
				push_vec4(vm, av.x - bv.x, av.y - bv.y, av.z - bv.z, av.w - bv.w)
			}
			return true
		}
	}
	// String*int / int*string repetition is checked before the general
	// "operands must be numbers" check below.
	if op == .Multiply {
		if core.is_string(a) && b.type == .Int {
			push(vm, core.make_string_value(string_multiply(core.string_get(core.as_string(a)), core.as_int(b))))
			return true
		}
		if a.type == .Int && core.is_string(b) {
			push(vm, core.make_string_value(string_multiply(core.string_get(core.as_string(b)), core.as_int(a))))
			return true
		}
	}
	if !core.is_number(a) || !core.is_number(b) {
		runtime_error(vm, "Operands must be numbers.")
		return false
	}
	if a.type == .Int && b.type == .Int {
		ai, bi := core.as_int(a), core.as_int(b)
		#partial switch op {
		case .Subtract:
			push(vm, core.make_int_value(ai - bi))
		case .Multiply:
			push(vm, core.make_int_value(ai * bi))
		case .Divide:
			if bi == 0 {
				runtime_error(vm, "Division by zero.")
				return false
			}
			push(vm, core.make_int_value(ai / bi))
		case .Modulus:
			if bi == 0 {
				// Deliberately the same "Division by zero" message used
				// for int division by zero above, rather than a separate
				// "Modulus by zero".
				runtime_error(vm, "Division by zero.")
				return false
			}
			push(vm, core.make_int_value(ai % bi))
		}
		return true
	}
	af, bf := core.as_float(a), core.as_float(b)
	#partial switch op {
	case .Subtract:
		push(vm, core.make_float_value(af - bf))
	case .Multiply:
		push(vm, core.make_float_value(af * bf))
	case .Divide:
		push(vm, core.make_float_value(af / bf))
	case .Modulus:
		push(vm, core.make_float_value(math.mod(af, bf)))
	}
	return true
}

negate :: proc(vm: ^VM) -> bool {
	v := pop(vm)
	#partial switch v.type {
	case .Int:
		push(vm, core.make_int_value(-core.as_int(v)))
	case .Float:
		push(vm, core.make_float_value(-core.as_float(v)))
	case:
		runtime_error(vm, "Operand must be a number.")
		return false
	}
	return true
}

// less_than/greater_than implement Op_Less/Op_Greater: numeric compare,
// or -- if both sides are strings -- lexicographic compare. `<=`/`>=`/
// `!=` have no opcodes of their own (see compiler/expr.odin's binary);
// they compile as one of these plus Not.
compare :: proc(vm: ^VM, op: core.Op_Code) -> bool {
	b := pop(vm)
	a := pop(vm)
	if core.is_number(a) && core.is_number(b) {
		af, bf := core.as_float(a), core.as_float(b)
		result := af < bf if op == .Less else af > bf
		push(vm, core.make_bool_value(result))
		return true
	}
	if core.is_string(a) && core.is_string(b) {
		sa := core.string_get(core.as_string(a))
		sb := core.string_get(core.as_string(b))
		result := sa < sb if op == .Less else sa > sb
		push(vm, core.make_bool_value(result))
		return true
	}
	runtime_error(vm, "Operands must be two numbers or two strings.")
	return false
}
