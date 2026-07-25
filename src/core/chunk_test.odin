package core

import "core:slice"
import "core:testing"

@(test)
test_write_op_and_byte_track_lines :: proc(t: ^testing.T) {
	c := new_chunk("test.lox")
	chunk_write_op(c, .Constant, 1)
	chunk_write_byte(c, 0, 1)
	chunk_write_op(c, .Return, 2)

	testing.expect_value(t, len(c.code), 3)
	testing.expect_value(t, c.code[0], u8(Op_Code.Constant))
	testing.expect_value(t, c.code[1], u8(0))
	testing.expect_value(t, c.code[2], u8(Op_Code.Return))
	testing.expect(t, slice.equal(c.lines[:], []int{1, 1, 2}))
}

// Plain values (ints, floats, strings, bools) should be deduplicated:
// the same literal appearing twice in one chunk shares one constant-pool
// slot, exactly like glox.
@(test)
test_add_constant_dedups_plain_values :: proc(t: ^testing.T) {
	c := new_chunk("test.lox")
	i1 := chunk_add_constant(c, make_int_value(7))
	i2 := chunk_add_constant(c, make_int_value(7))
	i3 := chunk_add_constant(c, make_int_value(8))

	testing.expect_value(t, i1, i2)
	testing.expect(t, i1 != i3)
	testing.expect_value(t, len(c.constants), 2)
}

// Two occurrences of what would otherwise look like "the same constant"
// for a Function object must NOT be deduplicated: each one has to
// become its own distinct Closure_Object at runtime when OP_CLOSURE
// runs (e.g. a lambda literal appearing twice, or recompiled via the
// finally-replay mechanism) -- see chunk.odin's is_dedupable_constant.
@(test)
test_add_constant_never_dedups_functions :: proc(t: ^testing.T) {
	c := new_chunk("test.lox")
	env := make_environment("test")
	f1 := make_object_value(&make_function_object("test.lox", env).obj)
	f2 := make_object_value(&make_function_object("test.lox", env).obj)

	i1 := chunk_add_constant(c, f1)
	i2 := chunk_add_constant(c, f2)

	testing.expect(t, i1 != i2)
	testing.expect_value(t, len(c.constants), 2)
}

@(test)
test_slot_for_name_looks_up_global_names :: proc(t: ^testing.T) {
	c := new_chunk("test.lox")
	append(&c.global_names, "a", "b", "c")

	testing.expect_value(t, chunk_slot_for_name(c, "b"), 1)
	testing.expect_value(t, chunk_slot_for_name(c, "missing"), -1)
}
