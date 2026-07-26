package compiler

import "../core"

// Top-level entry points. `Compile` is a fresh, one-shot compile (a
// script file, or a from-scratch module import); `Compile_Repl` differs
// only in seeding/committing the persistent Repl_State around it, so a
// name resolved on one REPL line stays resolved the same way on the
// next.

// Compile compiles source into a top-level Function_Object ready to be
// wrapped in a Closure_Object and run. filename is used for error
// messages and Chunk.filename; environment is the runtime home for this
// compilation unit's globals (fresh per script run, or the same
// Environment reused across import-caching/module boundaries -- see
// docs/ARCHITECTURE.md's Environment & globals section).
Compile :: proc(source: string, filename: string, environment: ^core.Environment) -> (fn: ^core.Function_Object, ok: bool) {
	scn := tokenize(source)
	defer destroy_scanner(&scn)

	p := Parser{
		scn              = &scn,
		filename         = filename,
		globals          = make(map[string]int),
		globals_declared = make(map[string]bool),
		skip_peephole    = DebugSkipPeephole,
	}

	init_root_compiler(&p, environment)
	advance(&p)
	for !match(&p, .Eof) {
		declaration(&p)
	}
	finished := end_compiler(&p)

	return finished.function, !p.had_error
}

// Repl_State carries a REPL session's slot-assignment bookkeeping across
// separately-compiled lines. The Environment it points at is the single
// source of truth for actual runtime *values* (see
// docs/ARCHITECTURE.md) -- this struct exists purely so each new line's
// Parser starts with the same name -> slot mapping the previous line
// left off with, instead of reassigning slot 0 to whatever name happens
// to appear first on the new line.
Repl_State :: struct {
	globals:          map[string]int,
	globals_declared: map[string]bool,
	global_count:     int,
	environment:      ^core.Environment,
}

make_repl_state :: proc(environment: ^core.Environment) -> Repl_State {
	return Repl_State{
		globals          = make(map[string]int),
		globals_declared = make(map[string]bool),
		environment      = environment,
	}
}

// Compile_Repl compiles one REPL line against st. On success, the
// (possibly grown) slot tables are committed back into st; on failure,
// st is left untouched, so a bad line can't corrupt the session for
// subsequent ones.
Compile_Repl :: proc(source: string, st: ^Repl_State) -> (fn: ^core.Function_Object, ok: bool) {
	scn := tokenize(source)
	defer destroy_scanner(&scn)

	p := Parser{
		scn              = &scn,
		filename         = "__repl__",
		globals          = copy_string_int_map(st.globals),
		globals_declared = copy_string_bool_map(st.globals_declared),
		global_count     = st.global_count,
		skip_peephole    = DebugSkipPeephole,
	}
	// Rebuild global_names_by_slot in slot order from the snapshotted
	// map -- see global_slot's own comment on why this parallel slice
	// exists (map iteration order isn't slot order).
	rebuild_names_by_slot(&p, st.globals)

	init_root_compiler(&p, st.environment)
	advance(&p)
	for !match(&p, .Eof) {
		declaration(&p)
	}
	finished := end_compiler(&p)

	if !p.had_error {
		st.globals = p.globals
		st.globals_declared = p.globals_declared
		st.global_count = p.global_count
	}

	return finished.function, !p.had_error
}

@(private = "file")
copy_string_int_map :: proc(m: map[string]int) -> map[string]int {
	out := make(map[string]int, len(m))
	for k, v in m {
		out[k] = v
	}
	return out
}

@(private = "file")
copy_string_bool_map :: proc(m: map[string]bool) -> map[string]bool {
	out := make(map[string]bool, len(m))
	for k, v in m {
		out[k] = v
	}
	return out
}

@(private = "file")
rebuild_names_by_slot :: proc(p: ^Parser, globals: map[string]int) {
	names := make([dynamic]string, len(globals))
	for name, slot in globals {
		names[slot] = name
	}
	p.global_names_by_slot = names
}
