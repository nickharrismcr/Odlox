package core

import "core:slice"
import "core:testing"

// bc_cache.odin's own unit-level tests: hand-built Chunk/Function_Object
// trees (this package can't reach the compiler package -- core sits
// below it -- so a real compiled program is exercised separately, in
// compiler/bc_cache_test.odin). These focus on the format itself: a
// direct round trip through function_serialise/function_deserialise,
// and each of the documented "not one of our files"/"stale schema"/
// "corrupt body" decode-error cases (see Bc_Decode_Error's own doc
// comment) never panicking, always coming back as a clean error.

@(test)
test_bc_cache_roundtrips_hand_built_chunk :: proc(t: ^testing.T) {
	env := make_environment("test")

	inner := make_function_object("test.lox", env)
	inner.name = intern_string("inner")
	inner.arity = 1
	inner.min_arity = 1
	inner.upvalue_count = 1
	chunk_write_op(inner.chunk, .Get_Upvalue, 1)
	chunk_write_byte(inner.chunk, 0, 1)
	chunk_write_op(inner.chunk, .Return, 1)

	outer := make_function_object("test.lox", env)
	outer.name = intern_string("outer")
	outer.arity = 2
	outer.min_arity = 1
	outer.is_variadic = true
	append(&outer.chunk.global_names, "a", "b")
	outer.chunk.global_count = 2
	chunk_add_property_cache(outer.chunk)
	chunk_add_property_cache(outer.chunk)

	int_idx := chunk_add_constant(outer.chunk, make_int_value(-5))
	big_idx := chunk_add_constant(outer.chunk, make_int_value(4294967296)) // beyond u32 -- see below
	float_idx := chunk_add_constant(outer.chunk, make_float_value(3.14159))
	str_idx := chunk_add_constant(outer.chunk, make_string_value("hello, cache"))
	fn_idx := chunk_add_constant(outer.chunk, make_object_value(&inner.obj))
	chunk_write_op(outer.chunk, .Constant, 1)
	chunk_write_byte(outer.chunk, int_idx, 1)
	chunk_write_op(outer.chunk, .Constant, 1)
	chunk_write_byte(outer.chunk, big_idx, 1)
	chunk_write_op(outer.chunk, .Constant, 1)
	chunk_write_byte(outer.chunk, float_idx, 1)
	chunk_write_op(outer.chunk, .Constant, 1)
	chunk_write_byte(outer.chunk, str_idx, 1)
	chunk_write_op(outer.chunk, .Closure, 1)
	chunk_write_byte(outer.chunk, fn_idx, 1)

	data, enc_ok := function_serialise(outer)
	testing.expect(t, enc_ok)
	if !enc_ok {
		return
	}
	defer delete(data)

	decoded, err := function_deserialise(data)
	testing.expect_value(t, err, Bc_Decode_Error.None)
	if err != .None {
		return
	}

	testing.expect_value(t, decoded.arity, outer.arity)
	testing.expect_value(t, decoded.min_arity, outer.min_arity)
	testing.expect_value(t, decoded.is_variadic, outer.is_variadic)
	testing.expect_value(t, decoded.upvalue_count, outer.upvalue_count)
	testing.expect_value(t, string_get(decoded.name), "outer")
	testing.expect(t, decoded.environment == nil) // never wired by function_deserialise itself

	dc := decoded.chunk
	testing.expect(t, slice.equal(dc.code[:], outer.chunk.code[:]))
	testing.expect(t, slice.equal(dc.lines[:], outer.chunk.lines[:]))
	testing.expect_value(t, dc.filename, "test.lox")
	testing.expect_value(t, dc.global_count, 2)
	testing.expect(t, slice.equal(dc.global_names[:], outer.chunk.global_names[:]))
	// property_caches: length preserved, contents reset (never serialized
	// -- class/method are live runtime state, see chunk.odin's doc comment).
	testing.expect_value(t, len(dc.property_caches), 2)
	testing.expect(t, dc.property_caches[0].class == nil)
	testing.expect(t, dc.property_caches[1].class == nil)
	// local_vars: debug-only, deliberately omitted -- decodes empty.
	testing.expect_value(t, len(dc.local_vars), 0)

	testing.expect_value(t, len(dc.constants), 5)
	testing.expect_value(t, as_int(dc.constants[0]), -5)
	// The int constant round-trips its full width, not truncated to
	// 32 bits the way glox's own bc_cache.go does -- a regression here
	// would look exactly like that known, acknowledged glox bug
	// reappearing (see bc_cache.odin's own doc comment).
	testing.expect_value(t, as_int(dc.constants[1]), 4294967296)
	testing.expect_value(t, as_float(dc.constants[2]), 3.14159)
	testing.expect_value(t, string_get(as_string(dc.constants[3])), "hello, cache")

	nested := as_function(dc.constants[4])
	testing.expect_value(t, string_get(nested.name), "inner")
	testing.expect_value(t, nested.arity, 1)
	testing.expect_value(t, nested.upvalue_count, 1)
	testing.expect(t, nested.environment == nil)
	testing.expect(t, slice.equal(nested.chunk.code[:], inner.chunk.code[:]))
}

@(test)
test_bc_cache_deserialise_rejects_bad_magic :: proc(t: ^testing.T) {
	garbage := []u8{'X', 'X', 'X', 'X', 1, 0, 0, 0, 0, 0}
	_, err := function_deserialise(garbage)
	testing.expect_value(t, err, Bc_Decode_Error.Bad_Magic)
}

@(test)
test_bc_cache_deserialise_rejects_wrong_version :: proc(t: ^testing.T) {
	buf := []u8{'O', 'L', 'X', 'C', 0xFF, 0xFF} // magic ok, version 0xFFFF -- not BC_CACHE_VERSION
	_, err := function_deserialise(buf)
	testing.expect_value(t, err, Bc_Decode_Error.Bad_Version)
}

@(test)
test_bc_cache_deserialise_rejects_truncated_data :: proc(t: ^testing.T) {
	env := make_environment("test")
	fn := make_function_object("test.lox", env)
	chunk_write_op(fn.chunk, .Return, 1)
	data, enc_ok := function_serialise(fn)
	testing.expect(t, enc_ok)
	defer delete(data)

	// Cut the buffer off partway through the body -- must fail cleanly,
	// not panic or hang, regardless of where the cut lands (glox's own
	// documented bc_cache.go weakness is a stale/malformed cache causing
	// a hang or OOM panic instead of a clean decode failure like this).
	for cut := 6; cut < len(data); cut += 3 {
		_, err := function_deserialise(data[:cut])
		testing.expectf(t, err == .Malformed, "expected Malformed at cut=%d, got %v", cut, err)
	}
}

@(test)
test_bc_cache_deserialise_rejects_garbage_property_cache_count :: proc(t: ^testing.T) {
	env := make_environment("test")
	fn := make_function_object("test.lox", env)
	chunk_write_op(fn.chunk, .Return, 1)
	data, enc_ok := function_serialise(fn)
	testing.expect(t, enc_ok)
	defer delete(data)

	// The property_cache_count field is the last thing chunk_serialise
	// writes -- overwrite it (the trailing 4 bytes) with an enormous
	// value, simulating exactly the kind of corruption glox's own
	// documented OOM-panic bug is triggered by. Must be rejected before
	// any allocation is attempted (see BC_CACHE_MAX_PROPERTY_CACHES),
	// not merely "eventually" fail.
	corrupted := slice.clone(data)
	defer delete(corrupted)
	n := len(corrupted)
	corrupted[n - 4] = 0xFF
	corrupted[n - 3] = 0xFF
	corrupted[n - 2] = 0xFF
	corrupted[n - 1] = 0xFF

	_, err := function_deserialise(corrupted)
	testing.expect_value(t, err, Bc_Decode_Error.Malformed)
}
