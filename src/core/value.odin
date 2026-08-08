package core

import "core:fmt"

// Value: the tagged union every VM stack slot, local, global, and
// constant is. `data`, `obj`, and `vec` share one slot via a raw union
// (see Value_Payload below), giving a ~40-byte Value with no unsafe code
// at all. See docs/ARCHITECTURE.md's Value representation section for
// the full reasoning, including why Vec2/Vec3/Vec4 are inlined here
// (true copy semantics, no GC involvement) rather than heap-allocated
// like every other Object_Type.

Value_Type :: enum u8 {
	Nil,
	Bool,
	Int,
	Float,
	Obj,
	Vec2,
	Vec3,
	Vec4,
	Undefined, // VM-internal: an omitted default-parameter slot before its default runs
}

// Value_Payload is `#raw_union` (not a tagged Odin `union`): `data`,
// `obj`, and `vec` are never more than one meaningful for the same Value
// at once -- which one is valid is entirely determined by `Value.type`
// -- so they can overlap the same bytes with no discriminant of their
// own, the same way clox's `as` union does. `vec` is sized for a Vec4
// (the largest of the three); Vec2/Vec3 just leave the trailing lanes
// unused. This is the one field that makes Value_Payload (and so Value)
// bigger than a single register-width slot -- see value.odin's header
// comment.
Value_Payload :: struct #raw_union {
	data: u64, // int (bit pattern), f64 (bit pattern via transmute), or bool (0/1)
	obj:  ^Obj, // heap object pointer -- meaningful iff type is Obj
	vec:  [4]f64, // inline Vec2/Vec3/Vec4 components -- meaningful iff type is Vec2/Vec3/Vec4
}

Value :: struct {
	using payload: Value_Payload,
	type:          Value_Type,
	obj_type:      Object_Type, // cached concrete subtype; valid iff type == .Obj
	immutable:     bool,
}

NIL_VALUE :: Value{type = .Nil}
UNDEFINED_VALUE :: Value{type = .Undefined}

// -----------------------------------------------------------------------
// Constructors

make_bool_value :: proc(b: bool, immutable := false) -> Value {
	v: Value
	v.type = .Bool
	v.data = 1 if b else 0
	v.immutable = immutable
	return v
}

make_int_value :: proc(i: int, immutable := false) -> Value {
	v: Value
	v.type = .Int
	v.data = u64(i64(i))
	v.immutable = immutable
	return v
}

make_float_value :: proc(f: f64, immutable := false) -> Value {
	v: Value
	v.type = .Float
	v.data = transmute(u64)f
	v.immutable = immutable
	return v
}

// make_object_value wraps any heap object -- obj_type is read straight
// off the object being wrapped, so callers never have to (mis-)supply it
// separately from the pointer itself.
make_object_value :: proc(obj: ^Obj, immutable := false) -> Value {
	v: Value
	v.type = .Obj
	v.obj_type = obj.type
	v.obj = obj
	v.immutable = immutable
	return v
}

make_vec2_value :: proc(x, y: f64, immutable := false) -> Value {
	v: Value
	v.type = .Vec2
	v.vec = {x, y, 0, 0}
	v.immutable = immutable
	return v
}
make_vec3_value :: proc(x, y, z: f64, immutable := false) -> Value {
	v: Value
	v.type = .Vec3
	v.vec = {x, y, z, 0}
	v.immutable = immutable
	return v
}
make_vec4_value :: proc(x, y, z, w: f64, immutable := false) -> Value {
	v: Value
	v.type = .Vec4
	v.vec = {x, y, z, w}
	v.immutable = immutable
	return v
}

// -----------------------------------------------------------------------
// Predicates & accessors

is_nil :: proc(v: Value) -> bool { return v.type == .Nil }
is_bool :: proc(v: Value) -> bool { return v.type == .Bool }
is_int :: proc(v: Value) -> bool { return v.type == .Int }
is_float :: proc(v: Value) -> bool { return v.type == .Float }
is_number :: proc(v: Value) -> bool { return v.type == .Int || v.type == .Float }
is_obj :: proc(v: Value) -> bool { return v.type == .Obj }
is_vec2 :: proc(v: Value) -> bool { return v.type == .Vec2 }
is_vec3 :: proc(v: Value) -> bool { return v.type == .Vec3 }
is_vec4 :: proc(v: Value) -> bool { return v.type == .Vec4 }

// is_string reports whether v is a Value.Obj carrying a String_Object,
// checking the cached obj_type tag rather than dereferencing the object.
is_string :: proc(v: Value) -> bool {
	return v.type == .Obj && v.obj_type == .String
}

as_bool :: proc(v: Value) -> bool {
	return v.data != 0
}

as_int :: proc(v: Value) -> int {
	#partial switch v.type {
	case .Int:
		return int(cast(i64)v.data)
	case .Float:
		return int(transmute(f64)v.data)
	}
	return 0
}

as_float :: proc(v: Value) -> f64 {
	#partial switch v.type {
	case .Int:
		return f64(cast(i64)v.data)
	case .Float:
		return transmute(f64)v.data
	}
	return 0
}

as_string :: proc(v: Value) -> ^String_Object {
	return cast(^String_Object)v.obj
}
as_list :: proc(v: Value) -> ^List_Object {
	return cast(^List_Object)v.obj
}
as_dict :: proc(v: Value) -> ^Dict_Object {
	return cast(^Dict_Object)v.obj
}
as_float_array :: proc(v: Value) -> ^Float_Array_Object {
	return cast(^Float_Array_Object)v.obj
}
as_float_array_3d :: proc(v: Value) -> ^Float_Array_3D_Object {
	return cast(^Float_Array_3D_Object)v.obj
}
as_userdata :: proc(v: Value) -> ^Userdata_Object {
	return cast(^Userdata_Object)v.obj
}
as_function :: proc(v: Value) -> ^Function_Object {
	return cast(^Function_Object)v.obj
}
as_closure :: proc(v: Value) -> ^Closure_Object {
	return cast(^Closure_Object)v.obj
}
as_class :: proc(v: Value) -> ^Class_Object {
	return cast(^Class_Object)v.obj
}
as_instance :: proc(v: Value) -> ^Instance_Object {
	return cast(^Instance_Object)v.obj
}
as_module :: proc(v: Value) -> ^Module_Object {
	return cast(^Module_Object)v.obj
}
as_bound_method :: proc(v: Value) -> ^Bound_Method_Object {
	return cast(^Bound_Method_Object)v.obj
}
as_native :: proc(v: Value) -> ^Native_Object {
	return cast(^Native_Object)v.obj
}
as_file :: proc(v: Value) -> ^File_Object {
	return cast(^File_Object)v.obj
}
as_vec2 :: proc(v: Value) -> Vec2 {
	return {v.vec[0], v.vec[1]}
}
as_vec3 :: proc(v: Value) -> Vec3 {
	return {v.vec[0], v.vec[1], v.vec[2]}
}
as_vec4 :: proc(v: Value) -> Vec4 {
	return {v.vec[0], v.vec[1], v.vec[2], v.vec[3]}
}

// -----------------------------------------------------------------------
// Equality
//
// values_equal(a, b, types_must_match): types_must_match=false allows a
// numeric int/float cross-comparison (1 == 1.0); pass true at sites that
// need strict type-and-value equality (e.g. dict key lookups, switch/
// match dispatch, Chunk constant deduplication).

values_equal :: proc(a, b: Value, types_must_match: bool) -> bool {
	#partial switch a.type {
	case .Bool:
		return b.type == .Bool && a.data == b.data
	case .Int:
		#partial switch b.type {
		case .Int:
			return a.data == b.data
		case .Float:
			if types_must_match {
				return false
			}
			return f64(cast(i64)a.data) == transmute(f64)b.data
		}
		return false
	case .Float:
		#partial switch b.type {
		case .Int:
			if types_must_match {
				return false
			}
			return transmute(f64)a.data == f64(cast(i64)b.data)
		case .Float:
			return a.data == b.data
		}
		return false
	case .Nil:
		return b.type == .Nil
	case .Obj:
		if b.type != .Obj || a.obj_type != b.obj_type {
			return false
		}
		return objects_equal(a.obj, b.obj)
	case .Vec2:
		if b.type != .Vec2 {
			return false
		}
		av, bv := as_vec2(a), as_vec2(b)
		return av.x == bv.x && av.y == bv.y
	case .Vec3:
		if b.type != .Vec3 {
			return false
		}
		av, bv := as_vec3(a), as_vec3(b)
		return av.x == bv.x && av.y == bv.y && av.z == bv.z
	case .Vec4:
		if b.type != .Vec4 {
			return false
		}
		av, bv := as_vec4(a), as_vec4(b)
		return av.x == bv.x && av.y == bv.y && av.z == bv.z && av.w == bv.w
	}
	return false
}

// objects_equal implements object-kind equality for two Values already
// confirmed to share an Object_Type. Strings compare by content
// (`s1.chars == s2.chars` is Odin's native string equality -- a real
// byte comparison, not a pointer compare): for interned (short, see
// obj_string.odin's STRING_INTERN_MAX_LEN) strings this is equivalent to
// a pointer compare since interning guarantees equal content <=> equal
// pointer, but it's also correct on its own for two collectible (long)
// strings that happen to share content without sharing an allocation.
// Lists/dicts get real recursive structural equality; every other kind
// (functions, closures, classes, instances, modules, natives, files,
// iterators, bound methods) is reference/identity equality, matching
// Lox's normal "same object" semantics for those.
@(private = "file")
objects_equal :: proc(a, b: ^Obj) -> bool {
	if a == b {
		return true
	}
	#partial switch a.type {
	case .String:
		s1 := cast(^String_Object)a
		s2 := cast(^String_Object)b
		return s1.chars == s2.chars
	case .List:
		l1 := cast(^List_Object)a
		l2 := cast(^List_Object)b
		if l1.is_tuple != l2.is_tuple || len(l1.items) != len(l2.items) {
			return false
		}
		for item, i in l1.items {
			if !values_equal(item, l2.items[i], true) {
				return false
			}
		}
		return true
	case .Dict:
		d1 := cast(^Dict_Object)a
		d2 := cast(^Dict_Object)b
		if len(d1.items) != len(d2.items) {
			return false
		}
		for k, v in d1.items {
			v2, ok := d2.items[k]
			if !ok || !values_equal(v, v2, true) {
				return false
			}
		}
		return true
	}
	return false
}

// -----------------------------------------------------------------------
// String conversion

value_to_string :: proc(v: Value, allocator := context.allocator) -> string {
	#partial switch v.type {
	case .Nil:
		return "nil"
	case .Undefined:
		return "<undefined>"
	case .Bool:
		return "true" if v.data != 0 else "false"
	case .Int:
		return fmt.aprintf("%d", as_int(v), allocator = allocator)
	case .Float:
		return fmt.aprintf("%v", as_float(v), allocator = allocator)
	case .Obj:
		return object_to_string(v.obj, allocator)
	case .Vec2:
		vv := as_vec2(v)
		return fmt.aprintf("vec2(%v, %v)", vv.x, vv.y, allocator = allocator)
	case .Vec3:
		vv := as_vec3(v)
		return fmt.aprintf("vec3(%v, %v, %v)", vv.x, vv.y, vv.z, allocator = allocator)
	case .Vec4:
		vv := as_vec4(v)
		return fmt.aprintf("vec4(%v, %v, %v, %v)", vv.x, vv.y, vv.z, vv.w, allocator = allocator)
	}
	return "<unknown>"
}
