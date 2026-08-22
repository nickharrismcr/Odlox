package compiler

import "../core"

// StrictTypes gates Phase 2's optional-type diagnostics from a warning
// (printed, never affecting `ok`) into a hard compile failure -- unused
// until Phase 4 adds the `--strict-types` flag that sets it (see main.odin)
// and the `if StrictTypes && len(diagnostics) > 0` check Phase 4 adds
// below. Declared now, default false, because Compile_Repl's diagnostic
// print is gated on it from Phase 2 onward (see Compile_Repl below) --
// cheaper to add that gate once here than to touch this call site twice.
// Same package-var pattern as DebugSkipPeephole.
StrictTypes: bool

// Top-level entry points. `Compile` is a fresh, one-shot compile (a
// script file, or a from-scratch module import); `Compile_Repl` differs
// only in seeding/committing the persistent Repl_State around it, so a
// name resolved on one REPL line stays resolved the same way on the
// next. Both run the same three-stage pipeline: parse to an AST
// (parser.odin/rules.odin/expr.odin/stmt.odin), resolve it in place
// (resolve.odin), then emit bytecode from the resolved tree (emit.odin/
// emit_expr.odin/emit_stmt.odin) -- see docs/plans/compiler-ast-split.md.

// Compile compiles source into a top-level Function_Object ready to be
// wrapped in a Closure_Object and run. filename is used for error
// messages and Chunk.filename; environment is the runtime home for this
// compilation unit's globals (fresh per script run, or the same
// Environment reused across import-caching/module boundaries -- see
// docs/ARCHITECTURE.md's Environment & globals section).
Compile :: proc(source: string, filename: string, environment: ^core.Environment) -> (fn: ^core.Function_Object, ok: bool) {
	scn := tokenize(source)
	defer destroy_scanner(&scn)

	p := Parser{scn = &scn, filename = filename}
	advance(&p)

	stmts: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration(&p)
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

	diagnostics := typecheck_program(stmts[:])
	print_type_diagnostics(diagnostics) // Phase 2: always warnings, never affects `ok`

	return emit_program(stmts[:], filename, environment, globals, DebugSkipPeephole)
}

// Repl_State carries a REPL session's slot-assignment bookkeeping across
// separately-compiled lines. The Environment it points at is the single
// source of truth for actual runtime *values* (see
// docs/ARCHITECTURE.md) -- this struct exists purely so each new line's
// resolve_program call starts with the same name -> slot mapping the
// previous line left off with, instead of reassigning slot 0 to whatever
// name happens to appear first on the new line.
Repl_State :: struct {
	globals:          map[string]int,
	globals_declared: map[string]bool,
	global_count:     int,
	environment:      ^core.Environment,
}

make_repl_state :: proc(environment: ^core.Environment) -> Repl_State {
	return Repl_State{globals = make(map[string]int), globals_declared = make(map[string]bool), environment = environment}
}

// Compile_Repl compiles one REPL line against st. On success, the
// (possibly grown) slot tables are committed back into st; on failure,
// st is left untouched -- resolve_program only ever mutates the *copy*
// seeded into it (see Repl_Seed), never st's own maps directly -- so a
// bad line can't corrupt the session for subsequent ones.
Compile_Repl :: proc(source: string, st: ^Repl_State) -> (fn: ^core.Function_Object, ok: bool) {
	scn := tokenize(source)
	defer destroy_scanner(&scn)

	p := Parser{scn = &scn, filename = "__repl__"}
	advance(&p)

	stmts: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration(&p)
		if s != nil {
			append(&stmts, s)
		}
	}
	if p.had_error {
		return nil, false
	}

	seed := Repl_Seed {
		globals          = copy_string_int_map(st.globals),
		globals_declared = copy_string_bool_map(st.globals_declared),
		global_count     = st.global_count,
	}
	globals, had_error := resolve_program(stmts[:], &seed)
	if had_error {
		return nil, false
	}

	diagnostics := typecheck_program(stmts[:])
	if StrictTypes {
		print_type_diagnostics(diagnostics)
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
