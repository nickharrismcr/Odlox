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
