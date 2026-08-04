package compiler

import "../core"
import "core:fmt"

// Implementation phase 5 of docs/plans/compiler-ast-split.md: the
// Emitter's shared primitives and function/chunk lifecycle -- the AST-
// walking counterpart to compiler_state.odin's emission half (the
// scope/local/upvalue/global half moved to resolve.odin in phase 4).
// emit_expr.odin/emit_stmt.odin hold the per-node-kind walk.
//
// Everything here reads slot numbers/resolutions the Resolver already
// computed (Var_Ref.kind/slot, declared_slot, Local_Exit, etc. -- all on
// the AST already) rather than re-deriving them, per the plan doc's own
// framing: "the Emitter reads pre-computed slot info during its bytecode
// walk, plus does the jump/patch backpatching."
//
// Scope explicitly excludes try/finally *crossing* -- a return/break/
// continue whose target is outside an enclosing try. emit_stmt.odin's
// break/continue/return procs emit the ordinary (no crossing) terminal
// instruction directly; implementation phase 6 adds the ancestor-try walk
// on top without disturbing this.

// -----------------------------------------------------------------------
// Types

// Emit_Func is one per function currently being emitted, chained to its
// lexically enclosing one via `enclosing` -- same nested-compiler shape
// Compiler used, just without the scope/local/upvalue bookkeeping (that
// already happened in the Resolver; this only needs the *results*).
Emit_Func :: struct {
	enclosing:   ^Emit_Func,
	function:    ^core.Function_Object,
	environment: ^core.Environment,
	fn_type:     Function_Type,
	loop:        ^Loop, // current loop context (compiler_state.odin's shape, reused), for break/continue jump-patching
	local_debug: map[int]int, // local slot -> index into chunk.local_vars, for end_ip patching (best-effort debug info; no test depends on its exact contents)
}

Emitter :: struct {
	current:       ^Emit_Func,
	filename:      string,
	globals:       Global_Table, // from resolve_program -- published onto the top-level chunk once, in end_function_emit
	skip_peephole: bool,
	had_error:     bool,
}

emit_error :: proc(em: ^Emitter, line: int, message: string) {
	em.had_error = true
	fmt.printfln("[line %d] Error: %s", line, message)
}

// -----------------------------------------------------------------------
// Entry point

emit_program :: proc(
	stmts: []Stmt,
	filename: string,
	environment: ^core.Environment,
	globals: Global_Table,
	skip_peephole: bool,
) -> (
	fn: ^core.Function_Object,
	ok: bool,
) {
	em := new(Emitter)
	em.filename = filename
	em.globals = globals
	em.skip_peephole = skip_peephole

	begin_root_emit(em, environment)
	emit_stmt_list(em, stmts)
	finished := end_function_emit(em, 0)

	return finished.function, !em.had_error
}

// -----------------------------------------------------------------------
// Function/chunk lifecycle

current_chunk_em :: proc(em: ^Emitter) -> ^core.Chunk {
	return em.current.function.chunk
}

@(private = "file")
begin_root_emit :: proc(em: ^Emitter, environment: ^core.Environment) {
	f := new(Emit_Func)
	f.function = core.make_function_object(em.filename, environment)
	f.environment = environment
	f.fn_type = .Script
	f.local_debug = make(map[int]int)
	em.current = f
}

@(private = "file")
begin_function_emit :: proc(em: ^Emitter, fn_type: Function_Type, name: string) {
	f := new(Emit_Func)
	f.enclosing = em.current
	f.environment = em.current.environment
	f.fn_type = fn_type
	f.local_debug = make(map[int]int)
	fn := core.make_function_object(em.filename, f.environment)
	fn.name = core.intern_string(name)
	f.function = fn
	em.current = f
}

// end_function_emit finalizes the current function: emits the implicit
// return, runs the compile-time peephole pass, publishes the global name
// table (top-level chunk only), and pops back to the enclosing Emit_Func.
// Mirrors end_compiler exactly, reading em.globals (the Resolver's
// output) instead of live Parser fields.
@(private = "file")
end_function_emit :: proc(em: ^Emitter, line: int) -> ^Emit_Func {
	emit_return_em(em, line)
	finished := em.current
	fn := finished.function

	if finished.enclosing == nil {
		fn.chunk.global_count = em.globals.count
		for name in em.globals.names_by_slot {
			append(&fn.chunk.global_names, name)
		}
		if fn.environment != nil {
			clear(&fn.environment.global_names)
			for name in em.globals.names_by_slot {
				append(&fn.environment.global_names, name)
			}
		}
	}

	if !em.skip_peephole {
		peephole_optimise_em(fn.chunk)
	}

	em.current = finished.enclosing
	return finished
}

// emit_function_decl is the AST-walking counterpart to functions.odin's
// compile_function/compile_function_body/emit_closure combined -- shared
// by declared functions (emit_stmt.odin's Stmt_Function_Decl), lambdas
// (emit_expr.odin's Expr_Lambda), and class methods (emit_stmt.odin's
// Stmt_Class_Decl), exactly as the original is shared by all three.
// Reads param.declared_slot directly (the Resolver already assigned it)
// rather than declaring locals itself.
emit_function_decl :: proc(em: ^Emitter, decl: ^Function_Decl, name: string) {
	begin_function_emit(em, decl.fn_type, name)
	line := decl.token.line

	fn := em.current.function
	min_arity := 0
	for param in decl.params {
		if param.is_rest {
			fn.arity += 1
			fn.is_variadic = true
			continue
		}
		fn.arity += 1
		if param.default != nil {
			// Prologue guard: only run the default expression if the
			// caller actually omitted this argument (the VM pads an
			// omitted optional param with a Value.Undefined sentinel
			// before the body starts), matching compile_function_body.
			slot := u8(param.declared_slot)
			jump := emit_jump_if_defined_em(em, slot, line)
			emit_expr(em, param.default)
			emit_op_byte_em(em, .Set_Local, slot, line)
			emit_op_em(em, .Pop, line)
			patch_jump_em(em, jump, line)
		} else {
			min_arity += 1
		}
	}
	fn.min_arity = min_arity

	emit_stmt_list(em, decl.body)

	// Pops back to the enclosing Emit_Func -- current_chunk_em(em) below
	// now refers to the *caller's* chunk, matching how compile_function
	// emits Op_Code.Closure in the enclosing context after end_compiler.
	finished := end_function_emit(em, line)
	const_idx := core.chunk_add_constant(current_chunk_em(em), core.make_object_value(&finished.function.obj))
	emit_op_byte_em(em, .Closure, const_idx, line)
	for uv in decl.upvalues {
		emit_byte_em(em, 1 if uv.is_local else 0, line)
		emit_byte_em(em, uv.index, line)
	}
}

@(private = "file")
emit_jump_if_defined_em :: proc(em: ^Emitter, slot: u8, line: int) -> int {
	emit_op_em(em, .Jump_If_Defined, line)
	emit_byte_em(em, slot, line)
	emit_byte_em(em, 0xff, line)
	emit_byte_em(em, 0xff, line)
	return len(current_chunk_em(em).code) - 2
}

// -----------------------------------------------------------------------
// Local debug info -- best-effort; core/chunk_test.odin,
// debug/disassemble.odin, and debug/inspect.odin are the only consumers,
// none of them asserted on by compile_test.odin's own suite.

open_local_debug :: proc(em: ^Emitter, name: string, slot: int) {
	chunk := current_chunk_em(em)
	append(&chunk.local_vars, core.Local_Var_Info{name = name, start_ip = len(chunk.code), end_ip = -1, slot = slot})
	em.current.local_debug[slot] = len(chunk.local_vars) - 1
}

close_local_debug :: proc(em: ^Emitter, slot: int) {
	chunk := current_chunk_em(em)
	if idx, ok := em.current.local_debug[slot]; ok {
		chunk.local_vars[idx].end_ip = len(chunk.code)
		delete_key(&em.current.local_debug, slot)
	}
}

// -----------------------------------------------------------------------
// Bytecode emission primitives -- same shapes as compiler_state.odin's,
// taking an explicit line (from the triggering AST node's own token)
// instead of reading a live Parser's p.previous.line.

emit_byte_em :: proc(em: ^Emitter, b: u8, line: int) {
	core.chunk_write_byte(current_chunk_em(em), b, line)
}

emit_op_em :: proc(em: ^Emitter, op: core.Op_Code, line: int) {
	core.chunk_write_op(current_chunk_em(em), op, line)
}

emit_op_byte_em :: proc(em: ^Emitter, op: core.Op_Code, b: u8, line: int) {
	emit_op_em(em, op, line)
	emit_byte_em(em, b, line)
}

emit_constant_em :: proc(em: ^Emitter, v: core.Value, line: int) {
	emit_op_byte_em(em, .Constant, core.chunk_add_constant(current_chunk_em(em), v), line)
}

@(private = "file")
emit_return_em :: proc(em: ^Emitter, line: int) {
	if em.current.fn_type == .Initializer {
		emit_op_byte_em(em, .Get_Local, 0, line) // implicit `return this`
	} else {
		emit_op_em(em, .Nil, line)
	}
	emit_op_em(em, .Return, line)
}

emit_jump_em :: proc(em: ^Emitter, op: core.Op_Code, line: int) -> int {
	emit_op_em(em, op, line)
	emit_byte_em(em, 0xff, line)
	emit_byte_em(em, 0xff, line)
	return len(current_chunk_em(em).code) - 2
}

patch_jump_em :: proc(em: ^Emitter, offset: int, line: int) {
	chunk := current_chunk_em(em)
	jump := len(chunk.code) - offset - 2
	if jump > 0xffff {
		emit_error(em, line, "Too much code to jump over.")
	}
	chunk.code[offset] = u8((jump >> 8) & 0xff)
	chunk.code[offset + 1] = u8(jump & 0xff)
}

emit_loop_em :: proc(em: ^Emitter, loop_start: int, line: int) {
	emit_op_em(em, .Loop, line)
	offset := len(current_chunk_em(em).code) - loop_start + 2
	if offset > 0xffff {
		emit_error(em, line, "Loop body too large.")
	}
	emit_byte_em(em, u8((offset >> 8) & 0xff), line)
	emit_byte_em(em, u8(offset & 0xff), line)
}

// emit_property_cache_em allocates a fresh monomorphic-inline-cache slot
// and emits it as the trailing operand byte of a Get_Property/Invoke
// instruction -- see core/chunk.odin's Property_Cache doc comment. Guards
// the 255-slots-per-chunk limit the u8 index implies, matching
// emit_property_cache exactly.
emit_property_cache_em :: proc(em: ^Emitter, line: int) {
	chunk := current_chunk_em(em)
	if len(chunk.property_caches) == 255 {
		emit_error(em, line, "Too many property accesses/method calls in one function.")
	}
	emit_byte_em(em, core.chunk_add_property_cache(chunk), line)
}

// -----------------------------------------------------------------------
// Var_Ref -> Op_Code -- the mapping resolve_variable's (arg, get_op,
// set_op) return used to bake in directly; kept separate here so the
// Resolver never has to know about opcodes (see Var_Ref's own doc comment
// in ast.odin).

get_op_for_ref :: proc(kind: Var_Ref_Kind) -> core.Op_Code {
	#partial switch kind {
	case .Local:
		return .Get_Local
	case .Upvalue:
		return .Get_Upvalue
	case .Global:
		return .Get_Global
	}
	return .Noop
}

set_op_for_ref :: proc(kind: Var_Ref_Kind) -> core.Op_Code {
	#partial switch kind {
	case .Local:
		return .Set_Local
	case .Upvalue:
		return .Set_Upvalue
	case .Global:
		return .Set_Global
	}
	return .Noop
}

// compound_op_code maps a compound-assignment token to the opcode that
// computes its operator (the Set_* half is separate -- see
// get_op_for_ref/set_op_for_ref), same mapping as expr.odin's
// compound_assign_op.
compound_op_code :: proc(t: Token_Type) -> core.Op_Code {
	#partial switch t {
	case .Plus_Equal:
		return .Add_Numeric
	case .Minus_Equal:
		return .Subtract
	case .Star_Equal:
		return .Multiply
	case .Slash_Equal:
		return .Divide
	case .Percent_Equal:
		return .Modulus
	}
	return .Noop
}

// -----------------------------------------------------------------------
// Compile-time peephole optimizer -- byte-for-byte copy of
// compiler_state.odin's peephole_optimise/fuse (private to that file, so
// this file can't call them directly during the migration). Deleted here
// at cutover, when the original goes away.

@(private = "file")
peephole_optimise_em :: proc(c: ^core.Chunk) {
	code := c.code
	i := 0
	for i + 7 < len(code) {
		is_get_local := code[i] == u8(core.Op_Code.Get_Local)
		set_matches :=
			code[i + 5] == u8(core.Op_Code.Set_Local) &&
			code[i + 6] == code[i + 1] &&
			code[i + 7] == u8(core.Op_Code.Pop) &&
			code[i + 4] == u8(core.Op_Code.Add_Numeric)

		if is_get_local && set_matches && code[i + 2] == u8(core.Op_Code.Get_Local) {
			fuse_em(code, i, .Add_Nn, code[i + 1], code[i + 3])
			i += 8
			continue
		}
		if is_get_local && set_matches && code[i + 2] == u8(core.Op_Code.Constant) {
			fuse_em(code, i, .Incr_Const_N, code[i + 1], code[i + 3])
			i += 8
			continue
		}
		i += 1
	}
}

@(private = "file")
fuse_em :: proc(code: [dynamic]u8, i: int, op: core.Op_Code, a, b: u8) {
	code[i] = u8(op)
	code[i + 1] = a
	code[i + 2] = b
	for k in i + 3 ..= i + 7 {
		code[k] = u8(core.Op_Code.Noop)
	}
}
