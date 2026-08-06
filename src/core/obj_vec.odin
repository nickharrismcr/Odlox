package core

// Vec2/Vec3/Vec4: small fixed-size numeric value types, inlined directly
// into Value's payload (see value.odin's Value_Payload) rather than
// heap-allocated -- true copy semantics, no GC involvement at all. These
// three structs exist only as a convenient by-value return/parameter
// shape for as_vec2/3/4 and native code; the actual storage is just
// Value_Payload.vec, a raw [4]f64. Arithmetic itself (`+`, swizzle field
// access) is a VM opcode concern, not part of this file.

Vec2 :: struct {
	x, y: f64,
}

Vec3 :: struct {
	x, y, z: f64,
}

Vec4 :: struct {
	x, y, z, w: f64,
}
