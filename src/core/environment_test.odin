package core

import "core:testing"

@(test)
test_init_globals_allocates_slots :: proc(t: ^testing.T) {
	env := make_environment("test")
	env_init_globals(env, 3)

	testing.expect_value(t, len(env.globals), 3)
	testing.expect_value(t, len(env.defined), 3)
	for i in 0 ..< 3 {
		testing.expect(t, !env.defined[i])
	}
}

@(test)
test_set_global_marks_defined :: proc(t: ^testing.T) {
	env := make_environment("test")
	env_init_globals(env, 1)
	env_set_global(env, 0, make_int_value(42))

	testing.expect(t, env.defined[0])
	testing.expect_value(t, as_int(env.globals[0]), 42)
}

// grow_globals must preserve values already stored on earlier lines --
// this is specifically what makes the REPL work (a global defined on
// line 1 must survive a later line's recompile-and-grow), unlike
// env_init_globals which always starts from a fresh, empty slice.
@(test)
test_grow_globals_preserves_existing_values :: proc(t: ^testing.T) {
	env := make_environment("repl")
	env_init_globals(env, 1)
	env_set_global(env, 0, make_int_value(1))

	env_grow_globals(env, 3)

	testing.expect_value(t, len(env.globals), 3)
	testing.expect(t, env.defined[0])
	testing.expect_value(t, as_int(env.globals[0]), 1)
	testing.expect(t, !env.defined[1])
	testing.expect(t, !env.defined[2])
}

@(test)
test_grow_globals_is_a_no_op_when_already_big_enough :: proc(t: ^testing.T) {
	env := make_environment("test")
	env_init_globals(env, 5)
	env_grow_globals(env, 2) // smaller than current -- must not shrink
	testing.expect_value(t, len(env.globals), 5)
}

@(test)
test_slot_for_name_and_name_for_slot_round_trip :: proc(t: ^testing.T) {
	env := make_environment("test")
	append(&env.global_names, "x", "y")

	testing.expect_value(t, env_slot_for_name(env, "y"), 1)
	testing.expect_value(t, env_slot_for_name(env, "missing"), -1)
	testing.expect_value(t, env_name_for_slot(env, 0), "x")
}

@(test)
test_var_get_set_by_canonical_string_key :: proc(t: ^testing.T) {
	env := make_environment("test")
	key := intern_string("greeting")
	env_set_var(env, key, make_string_value("hi"))

	v, ok := env_get_var(env, key)
	testing.expect(t, ok)
	testing.expect_value(t, string_get(as_string(v)), "hi")

	_, missing_ok := env_get_var(env, intern_string("nope"))
	testing.expect(t, !missing_ok)
}
