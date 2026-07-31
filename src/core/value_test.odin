package core

// Unit tests for Value's layout and equality semantics -- the narrow,
// fast-running gate for the tagged-union design described in
// docs/ARCHITECTURE.md, before the compiler/VM (Phases 3-4) exist to
// exercise it indirectly through real scripts.

import "core:testing"

// Pins down the whole point of the #raw_union design: Value must be 16
// bytes, matching clox, not the 32 bytes the reference implementation's Go interface-based
// Value costs. If this regresses (e.g. a field gets added without
// checking alignment/size first), it should fail loudly here rather
// than silently show up later as "the VM is slower than expected".
@(test)
test_value_is_sixteen_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Value), 16)
}

@(test)
test_int_roundtrip :: proc(t: ^testing.T) {
	v := make_int_value(42)
	testing.expect(t, is_int(v))
	testing.expect(t, is_number(v))
	testing.expect_value(t, as_int(v), 42)
}

@(test)
test_negative_int_roundtrip :: proc(t: ^testing.T) {
	// Exercises the u64(i64(i)) bit-pattern round-trip for a negative
	// value specifically -- the case where a naive `u64(i)` conversion
	// (without going through i64 first) could misbehave.
	v := make_int_value(-7)
	testing.expect_value(t, as_int(v), -7)
}

@(test)
test_float_roundtrip :: proc(t: ^testing.T) {
	v := make_float_value(3.5)
	testing.expect(t, is_float(v))
	testing.expect_value(t, as_float(v), 3.5)
}

@(test)
test_bool_roundtrip :: proc(t: ^testing.T) {
	testing.expect_value(t, as_bool(make_bool_value(true)), true)
	testing.expect_value(t, as_bool(make_bool_value(false)), false)
}

@(test)
test_immutable_flag_is_independent_of_value :: proc(t: ^testing.T) {
	v := make_int_value(1, true)
	testing.expect(t, v.immutable)
	testing.expect_value(t, as_int(v), 1)
}

// -----------------------------------------------------------------------
// Equality

@(test)
test_int_equal_int :: proc(t: ^testing.T) {
	testing.expect(t, values_equal(make_int_value(3), make_int_value(3), true))
	testing.expect(t, !values_equal(make_int_value(3), make_int_value(4), true))
}

// The `types_must_match` parameter is the whole reason this signature
// takes three arguments instead of two: `1 == 1.0` should hold when
// comparing for the language's own `==` operator, but not when comparing
// for something stricter (dict key identity, Chunk constant dedup).
@(test)
test_int_float_cross_equality_depends_on_types_must_match :: proc(t: ^testing.T) {
	i := make_int_value(1)
	f := make_float_value(1.0)
	testing.expect(t, values_equal(i, f, false))
	testing.expect(t, !values_equal(i, f, true))
}

@(test)
test_nil_equals_nil_only :: proc(t: ^testing.T) {
	testing.expect(t, values_equal(NIL_VALUE, NIL_VALUE, true))
	testing.expect(t, !values_equal(NIL_VALUE, make_bool_value(false), true))
}

// Two strings with equal content must be the *same* interned object --
// this is the whole basis for values_equal's string fast path (pointer
// comparison, no byte-by-byte scan) being correct at all.
@(test)
test_equal_strings_intern_to_same_pointer :: proc(t: ^testing.T) {
	a := make_string_value("hello")
	b := make_string_value("hello")
	testing.expect_value(t, a.obj, b.obj)
	testing.expect(t, values_equal(a, b, true))
}

@(test)
test_different_strings_are_not_equal :: proc(t: ^testing.T) {
	a := make_string_value("hello")
	b := make_string_value("world")
	testing.expect(t, a.obj != b.obj)
	testing.expect(t, !values_equal(a, b, true))
}

// Deliberate improvement over the reference implementation (see value.odin's
// objects_equal doc comment): two distinct list objects with equal contents
// compare equal by structure, not by the reference implementation's
// stringify-and-compare fallback.
@(test)
test_lists_compare_structurally :: proc(t: ^testing.T) {
	items_a := make([dynamic]Value)
	append(&items_a, make_int_value(1), make_int_value(2))
	items_b := make([dynamic]Value)
	append(&items_b, make_int_value(1), make_int_value(2))

	a := make_object_value(&make_list_object(items_a).obj)
	b := make_object_value(&make_list_object(items_b).obj)

	testing.expect(t, a.obj != b.obj) // genuinely different objects
	testing.expect(t, values_equal(a, b, true)) // but equal contents
}

@(test)
test_lists_with_different_contents_are_not_equal :: proc(t: ^testing.T) {
	items_a := make([dynamic]Value)
	append(&items_a, make_int_value(1))
	items_b := make([dynamic]Value)
	append(&items_b, make_int_value(2))

	a := make_object_value(&make_list_object(items_a).obj)
	b := make_object_value(&make_list_object(items_b).obj)

	testing.expect(t, !values_equal(a, b, true))
}

@(test)
test_tuple_and_list_with_same_items_are_not_equal :: proc(t: ^testing.T) {
	items_a := make([dynamic]Value)
	append(&items_a, make_int_value(1))
	items_b := make([dynamic]Value)
	append(&items_b, make_int_value(1))

	list := make_object_value(&make_list_object(items_a, false).obj)
	tuple := make_object_value(&make_list_object(items_b, true).obj)

	testing.expect(t, !values_equal(list, tuple, true))
}

@(test)
test_vec2_equality_is_by_value_not_identity :: proc(t: ^testing.T) {
	a := make_vec2_value(1, 2)
	b := make_vec2_value(1, 2)
	c := make_vec2_value(1, 3)

	testing.expect(t, a.obj != b.obj)
	testing.expect(t, values_equal(a, b, true))
	testing.expect(t, !values_equal(a, c, true))
}

// -----------------------------------------------------------------------
// obj_type caching

// Confirms make_object_value/make_vecN_value always set obj_type from
// the object actually being wrapped -- the cached tag every hot-loop
// discrimination site (Phase 4) trusts instead of dereferencing the
// object.
@(test)
test_obj_type_is_cached_on_construction :: proc(t: ^testing.T) {
	s := make_string_value("x")
	testing.expect_value(t, s.obj_type, Object_Type.String)

	v := make_vec3_value(0, 0, 0)
	testing.expect_value(t, v.obj_type, Object_Type.Vec3)
}
