package compiler

import "../core"

// Temporary alternate entry point for testing the Parse -> Resolve ->
// Emit pipeline (implementation phases 2-5 of docs/plans/compiler-ast-
// split.md) end to end before cutover (phase 8), which rewrites
// compile.odin's own Compile/Compile_Repl to call this pipeline instead
// of the old single-pass one -- at which point this file is deleted.
Compile_V2 :: proc(source: string, filename: string, environment: ^core.Environment) -> (fn: ^core.Function_Object, ok: bool) {
	scn := tokenize(source)
	p := Parser{scn = &scn, filename = filename}
	advance(&p)

	stmts: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration_ast(&p)
		if s != nil {
			append(&stmts, s)
		}
	}
	if p.had_error {
		return nil, false
	}

	globals, had_error := resolve_program(stmts[:])
	if had_error {
		return nil, false
	}

	return emit_program(stmts[:], filename, environment, globals, DebugSkipPeephole)
}

// Repl_State_V2/make_repl_state_v2/Compile_Repl_V2: implementation phase 7
// of docs/plans/compiler-ast-split.md, the new pipeline's counterpart to
// compile.odin's Repl_State/make_repl_state/Compile_Repl. Carries a REPL
// session's slot-assignment bookkeeping across separately-compiled lines,
// same shape as the original -- global *values* still live solely in
// `environment` (unchanged across the whole session); this only tracks
// each name's slot/declared-ness so a later line resolves a name the same
// way an earlier line left it.
Repl_State_V2 :: struct {
	globals:          map[string]int,
	globals_declared: map[string]bool,
	global_count:     int,
	environment:      ^core.Environment,
}

make_repl_state_v2 :: proc(environment: ^core.Environment) -> Repl_State_V2 {
	return Repl_State_V2{globals = make(map[string]int), globals_declared = make(map[string]bool), environment = environment}
}

// Compile_Repl_V2 compiles one REPL line against st. On success, the
// (possibly grown) slot tables are committed back into st; on failure, st
// is left untouched (resolve_program/emit_program only ever mutate the
// *copies* seeded into them, never st's own maps directly), so a bad line
// can't corrupt the session for subsequent ones -- matching Compile_Repl
// exactly.
Compile_Repl_V2 :: proc(source: string, st: ^Repl_State_V2) -> (fn: ^core.Function_Object, ok: bool) {
	scn := tokenize(source)
	p := Parser{scn = &scn, filename = "__repl__"}
	advance(&p)

	stmts: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration_ast(&p)
		if s != nil {
			append(&stmts, s)
		}
	}
	if p.had_error {
		return nil, false
	}

	seed := Repl_Seed {
		globals          = copy_string_int_map_v2(st.globals),
		globals_declared = copy_string_bool_map_v2(st.globals_declared),
		global_count     = st.global_count,
	}
	globals, had_error := resolve_program(stmts[:], &seed)
	if had_error {
		return nil, false
	}

	fn, ok = emit_program(stmts[:], "__repl__", st.environment, globals, DebugSkipPeephole)
	if ok {
		st.globals = globals.slots
		st.globals_declared = globals.declared
		st.global_count = globals.count
	}
	return
}

@(private = "file")
copy_string_int_map_v2 :: proc(m: map[string]int) -> map[string]int {
	out := make(map[string]int, len(m))
	for k, v in m {
		out[k] = v
	}
	return out
}

@(private = "file")
copy_string_bool_map_v2 :: proc(m: map[string]bool) -> map[string]bool {
	out := make(map[string]bool, len(m))
	for k, v in m {
		out[k] = v
	}
	return out
}
