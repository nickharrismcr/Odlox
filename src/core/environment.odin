package core

import "core:fmt"

// Environment is the runtime home for one compilation unit's globals, in
// two tiers: globals/defined are slot-indexed for O(1) Get_Global/Set_Global,
// while vars is name-keyed (by canonical ^String_Object) for module-export
// lookup by name (`from mod import x`) where no compile-time slot exists.
// global_names maps slot -> name for error messages and exception-class
// resolution. No mutex: Environments are never shared across threads.
Environment :: struct {
	name:         string,
	vars:         map[^String_Object]Value,
	globals:      [dynamic]Value,
	defined:      [dynamic]bool,
	global_names: [dynamic]string,
}

make_environment :: proc(name: string) -> ^Environment {
	env := new(Environment)
	env.name = name
	return env
}

// env_name_for_slot returns the global variable name for a slot, for
// error messages.
env_name_for_slot :: proc(env: ^Environment, slot: int, allocator := context.allocator) -> string {
	if slot >= 0 && slot < len(env.global_names) {
		return env.global_names[slot]
	}
	return fmt.aprintf("#%d", slot, allocator = allocator)
}

// env_slot_for_name returns the global slot index for name, or -1 if
// not found -- works from inside any function in the compilation unit,
// not just the top-level script (see the struct doc comment).
env_slot_for_name :: proc(env: ^Environment, name: string) -> int {
	for n, i in env.global_names {
		if n == name {
			return i
		}
	}
	return -1
}

env_init_globals :: proc(env: ^Environment, count: int) {
	env.globals = make([dynamic]Value, count)
	env.defined = make([dynamic]bool, count)
}

// env_grow_globals extends the slot-indexed slices to hold at least
// count entries, preserving existing values -- used by the REPL so
// globals defined on earlier lines survive into later ones (unlike
// env_init_globals, which reallocates from scratch).
env_grow_globals :: proc(env: ^Environment, count: int) {
	if count <= len(env.globals) {
		return
	}
	resize(&env.globals, count)
	resize(&env.defined, count)
}

env_set_global :: proc(env: ^Environment, slot: int, value: Value) {
	env.globals[slot] = value
	env.defined[slot] = true
}

env_set_var :: proc(env: ^Environment, key: ^String_Object, value: Value) {
	env.vars[key] = value
}

env_get_var :: proc(env: ^Environment, key: ^String_Object) -> (Value, bool) {
	return env.vars[key]
}
