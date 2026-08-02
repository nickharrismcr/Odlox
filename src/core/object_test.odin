package core

import "core:testing"

@(test)
test_intern_string_returns_canonical_pointer :: proc(t: ^testing.T) {
	a := intern_string("abc")
	b := intern_string("abc")
	testing.expect_value(t, a, b)
	testing.expect_value(t, string_get(a), "abc")
}

@(test)
test_intern_string_distinguishes_different_content :: proc(t: ^testing.T) {
	testing.expect(t, intern_string("abc") != intern_string("abd"))
}

// -----------------------------------------------------------------------
// String_Object length split (STRING_INTERN_MAX_LEN) -- see
// docs/plans/string-interning-split.md for why long strings stopped
// being interned.

@(test)
test_make_string_value_interns_short_strings :: proc(t: ^testing.T) {
	short := "short string"
	testing.expect(t, len(short) <= STRING_INTERN_MAX_LEN)

	a := make_string_value(short)
	b := make_string_value(short)
	testing.expect_value(t, a.obj, b.obj) // same canonical pointer
	testing.expect(t, !as_string(a).collectible)
}

@(test)
test_make_string_value_does_not_intern_long_strings :: proc(t: ^testing.T) {
	long := "this string is deliberately longer than forty bytes to force the collectible path"
	testing.expect(t, len(long) > STRING_INTERN_MAX_LEN)

	a := make_string_value(long)
	b := make_string_value(long)
	testing.expect(t, as_string(a).collectible)
	testing.expect(t, as_string(b).collectible)
	// Equal content, but NOT deduplicated -- two distinct allocations,
	// unlike the interned (short) case above.
	testing.expect(t, a.obj != b.obj)
}

@(test)
test_long_strings_compare_equal_by_content_not_pointer :: proc(t: ^testing.T) {
	long := "this string is deliberately longer than forty bytes to force the collectible path"
	a := make_string_value(long)
	b := make_string_value(long)
	testing.expect(t, a.obj != b.obj) // different objects...
	testing.expect(t, values_equal(a, b, true)) // ...but still `==` equal
}

// -----------------------------------------------------------------------
// List_Object

@(test)
test_list_append_and_length :: proc(t: ^testing.T) {
	l := make_list_object(make([dynamic]Value))
	list_append(l, make_int_value(1))
	list_append(l, make_int_value(2))
	testing.expect_value(t, list_length(l), 2)
}

@(test)
test_list_index_supports_negative_indices :: proc(t: ^testing.T) {
	items := make([dynamic]Value)
	append(&items, make_int_value(10), make_int_value(20), make_int_value(30))
	l := make_list_object(items)

	v, ok := list_index(l, -1)
	testing.expect(t, ok)
	testing.expect_value(t, as_int(v), 30)

	_, out_of_range := list_index(l, -4)
	testing.expect(t, !out_of_range)
}

@(test)
test_list_remove_shifts_remaining_items :: proc(t: ^testing.T) {
	items := make([dynamic]Value)
	append(&items, make_int_value(1), make_int_value(2), make_int_value(3))
	l := make_list_object(items)

	list_remove(l, 1) // remove the middle element
	testing.expect_value(t, list_length(l), 2)
	v0, _ := list_index(l, 0)
	v1, _ := list_index(l, 1)
	testing.expect_value(t, as_int(v0), 1)
	testing.expect_value(t, as_int(v1), 3)
}

@(test)
test_list_contains :: proc(t: ^testing.T) {
	items := make([dynamic]Value)
	append(&items, make_int_value(5))
	l := make_list_object(items)

	testing.expect(t, list_contains(l, make_int_value(5)))
	testing.expect(t, !list_contains(l, make_int_value(6)))
}

// -----------------------------------------------------------------------
// Dict_Object

@(test)
test_dict_set_get_remove :: proc(t: ^testing.T) {
	d := make_dict_object()
	dict_set(d, intern_string("key"), make_int_value(1))

	v, ok := dict_get(d, intern_string("key"))
	testing.expect(t, ok)
	testing.expect_value(t, as_int(v), 1)

	removed, removed_ok := dict_remove(d, intern_string("key"))
	testing.expect(t, removed_ok)
	testing.expect_value(t, as_int(removed), 1)

	_, still_there := dict_get(d, intern_string("key"))
	testing.expect(t, !still_there)
}

@(test)
test_dict_get_missing_key :: proc(t: ^testing.T) {
	d := make_dict_object()
	_, ok := dict_get(d, intern_string("missing"))
	testing.expect(t, !ok)
}

// -----------------------------------------------------------------------
// Class_Object

@(test)
test_is_subclass_of_walks_super_chain :: proc(t: ^testing.T) {
	base := make_class_object("Base")
	mid := make_class_object("Mid")
	mid.super = base
	leaf := make_class_object("Leaf")
	leaf.super = mid

	testing.expect(t, is_subclass_of(leaf, base))
	testing.expect(t, is_subclass_of(leaf, mid))
	testing.expect(t, is_subclass_of(leaf, leaf)) // a class is its own subclass
	testing.expect(t, !is_subclass_of(base, leaf))
}

@(test)
test_unrelated_classes_are_not_subclasses :: proc(t: ^testing.T) {
	a := make_class_object("A")
	b := make_class_object("B")
	testing.expect(t, !is_subclass_of(a, b))
}

// -----------------------------------------------------------------------
// object_to_string dispatch

@(test)
test_object_to_string_for_class_and_instance :: proc(t: ^testing.T) {
	class := make_class_object("Point")
	testing.expect_value(t, object_to_string(&class.obj), "<class Point>")

	inst := make_instance_object(class)
	testing.expect_value(t, object_to_string(&inst.obj), "<instance Point>")
}

@(test)
test_object_to_string_for_string_includes_quotes :: proc(t: ^testing.T) {
	s := intern_string("hi")
	testing.expect_value(t, object_to_string(&s.obj), "\"hi\"")
}

@(test)
test_value_to_string_for_list :: proc(t: ^testing.T) {
	items := make([dynamic]Value)
	append(&items, make_int_value(1), make_int_value(2))
	v := make_object_value(&make_list_object(items).obj)
	testing.expect_value(t, value_to_string(v), "[ 1 , 2 ]")
}

@(test)
test_value_to_string_for_tuple_uses_parens :: proc(t: ^testing.T) {
	items := make([dynamic]Value)
	append(&items, make_int_value(1))
	v := make_object_value(&make_list_object(items, true).obj)
	testing.expect_value(t, value_to_string(v), "( 1 )")
}

// A list containing itself must not recurse forever -- the string_depth
// guard shared by list/dict to_string (see obj_list.odin) exists
// specifically for this.
@(test)
test_self_referential_list_does_not_recurse_forever :: proc(t: ^testing.T) {
	items := make([dynamic]Value)
	l := make_list_object(items)
	list_append(l, make_object_value(&l.obj))

	result := value_to_string(make_object_value(&l.obj))
	testing.expect(t, len(result) > 0) // didn't hang/crash; exact text isn't the point
}
