package core

// Vec2/Vec3/Vec4: small fixed-size numeric objects, still heap-allocated
// (too big to fit in Value's 8-byte payload alongside int/float/bool --
// see value.odin) but a natural candidate later for a dedicated
// free-list allocator given how allocation-heavy vector-arithmetic loops
// tend to be (see docs/ARCHITECTURE.md's Performance section). Arithmetic
// itself (`+`, in-place `++=`, swizzle field access) is a VM opcode
// concern, not part of the object model -- only the plain data shape and
// constructors live here.

Vec2_Object :: struct {
	using obj: Obj,
	x, y:      f64,
}

make_vec2_object :: proc(x, y: f64) -> ^Vec2_Object {
	o := new(Vec2_Object)
	o.obj.type = .Vec2
	o.x, o.y = x, y
	return o
}

Vec3_Object :: struct {
	using obj: Obj,
	x, y, z:   f64,
}

make_vec3_object :: proc(x, y, z: f64) -> ^Vec3_Object {
	o := new(Vec3_Object)
	o.obj.type = .Vec3
	o.x, o.y, o.z = x, y, z
	return o
}

Vec4_Object :: struct {
	using obj:  Obj,
	x, y, z, w: f64,
}

make_vec4_object :: proc(x, y, z, w: f64) -> ^Vec4_Object {
	o := new(Vec4_Object)
	o.obj.type = .Vec4
	o.x, o.y, o.z, o.w = x, y, z, w
	return o
}
