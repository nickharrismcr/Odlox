package compiler

import "../core"
import "core:fmt"

// The Emitter's shared primitives and function/chunk lifecycle: walks the
// AST the parser (parser.odin/rules.odin/expr.odin/stmt.odin) built and
// the Resolver (resolve.odin) annotated, turning it into core.Chunk
// bytecode. emit_expr.odin/emit_stmt.odin hold the per-node-kind walk.
// See docs/plans/compiler-ast-split.md for the full design.
//
// Everything here reads slot numbers/resolutions the Resolver already
// computed (Var_Ref.kind/slot, declared_slot, Local_Exit, etc. -- all on
// the AST already) rather than re-deriving them. break/continue/return
// crossing an enclosing try (emit_stmt.odin's emit_try_crossings) walks
// the ancestor Stmt_Try chain the Resolver already collected and emits
// each crossed try's cleanup/finally directly, in order -- no jump-to-a-
// deferred-site indirection the way a single-pass compiler needs.

// -----------------------------------------------------------------------
// Types

// Loop tracks one enclosing loop's patch lists during emission --
// bytecode-offset bookkeeping (start/breaks/continues) that doesn't exist
// until Emit actually runs, so unlike Local/Upvalue/Class_Compiler (all
// resolve.odin's, since the Resolver needs them too) this lives here
// instead. is_foreach: continue forward-jumps to Op_Next rather than
// back-jumping to start.
Loop :: struct {
	start:      int,
	breaks:     [dynamic]int,
	is_foreach: bool,
	continues:  [dynamic]int,
	previous:   ^Loop,
}

// Emit_Func is one per function currently being emitted, chained to its
// lexically enclosing one via `enclosing` -- mirrors the Resolver's own
// per-function nesting (Resolve_Scope), just without the scope/local/
// upvalue bookkeeping (that already happened in the Resolver; this only
// needs the *results*).
Emit_Func :: struct {
	enclosing:   ^Emit_Func,
	function:    ^core.Function_Object,
	environment: ^core.Environment,
	fn_type:     Function_Type,
	loop:        ^Loop, // current loop context, for break/continue jump-patching
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

current_chunk :: proc(em: ^Emitter) -> ^core.Chunk {
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
	emit_return(em, line)
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
		peephole_optimise(fn.chunk)
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
			jump := emit_jump_if_defined(em, slot, line)
			emit_expr(em, param.default)
			emit_op_byte(em, .Set_Local, slot, line)
			emit_op(em, .Pop, line)
			patch_jump(em, jump, line)
		} else {
			min_arity += 1
		}
	}
	fn.min_arity = min_arity

	emit_stmt_list(em, decl.body)

	// Pops back to the enclosing Emit_Func -- current_chunk(em) below
	// now refers to the *caller's* chunk, matching how compile_function
	// emits Op_Code.Closure in the enclosing context after end_compiler.
	finished := end_function_emit(em, line)
	// The Resolver only ever tracked upvalue count on its own Resolve_Scope
	// (a resolve-time-only struct) -- the real Function_Object's own
	// upvalue_count is what the VM's Op_Closure handler and the
	// disassembler both size the closure/skip the trailing descriptor
	// bytes by, so it has to be set explicitly here from decl.upvalues,
	// the Resolver's actual output.
	finished.function.upvalue_count = len(decl.upvalues)
	const_idx := core.chunk_add_constant(current_chunk(em), core.make_object_value(&finished.function.obj))
	emit_op_byte(em, .Closure, const_idx, line)
	for uv in decl.upvalues {
		emit_byte(em, 1 if uv.is_local else 0, line)
		emit_byte(em, uv.index, line)
	}
}

@(private = "file")
emit_jump_if_defined :: proc(em: ^Emitter, slot: u8, line: int) -> int {
	emit_op(em, .Jump_If_Defined, line)
	emit_byte(em, slot, line)
	emit_byte(em, 0xff, line)
	emit_byte(em, 0xff, line)
	return len(current_chunk(em).code) - 2
}

// -----------------------------------------------------------------------
// Local debug info -- best-effort; core/chunk_test.odin,
// debug/disassemble.odin, and debug/inspect.odin are the only consumers,
// none of them asserted on by compile_test.odin's own suite.

open_local_debug :: proc(em: ^Emitter, name: string, slot: int) {
	chunk := current_chunk(em)
	append(&chunk.local_vars, core.Local_Var_Info{name = name, start_ip = len(chunk.code), end_ip = -1, slot = slot})
	em.current.local_debug[slot] = len(chunk.local_vars) - 1
}

close_local_debug :: proc(em: ^Emitter, slot: int) {
	chunk := current_chunk(em)
	if idx, ok := em.current.local_debug[slot]; ok {
		chunk.local_vars[idx].end_ip = len(chunk.code)
		delete_key(&em.current.local_debug, slot)
	}
}

// -----------------------------------------------------------------------
// Bytecode emission primitives -- same shapes as compiler_state.odin's,
// taking an explicit line (from the triggering AST node's own token)
// instead of reading a live Parser's p.previous.line.

emit_byte :: proc(em: ^Emitter, b: u8, line: int) {
	core.chunk_write_byte(current_chunk(em), b, line)
}

emit_op :: proc(em: ^Emitter, op: core.Op_Code, line: int) {
	core.chunk_write_op(current_chunk(em), op, line)
}

emit_op_byte :: proc(em: ^Emitter, op: core.Op_Code, b: u8, line: int) {
	emit_op(em, op, line)
	emit_byte(em, b, line)
}

emit_constant :: proc(em: ^Emitter, v: core.Value, line: int) {
	emit_op_byte(em, .Constant, core.chunk_add_constant(current_chunk(em), v), line)
}

@(private = "file")
emit_return :: proc(em: ^Emitter, line: int) {
	if em.current.fn_type == .Initializer {
		emit_op_byte(em, .Get_Local, 0, line) // implicit `return this`
	} else {
		emit_op(em, .Nil, line)
	}
	emit_op(em, .Return, line)
}

emit_jump :: proc(em: ^Emitter, op: core.Op_Code, line: int) -> int {
	emit_op(em, op, line)
	emit_byte(em, 0xff, line)
	emit_byte(em, 0xff, line)
	return len(current_chunk(em).code) - 2
}

patch_jump :: proc(em: ^Emitter, offset: int, line: int) {
	chunk := current_chunk(em)
	jump := len(chunk.code) - offset - 2
	if jump > 0xffff {
		emit_error(em, line, "Too much code to jump over.")
	}
	chunk.code[offset] = u8((jump >> 8) & 0xff)
	chunk.code[offset + 1] = u8(jump & 0xff)
}

emit_loop :: proc(em: ^Emitter, loop_start: int, line: int) {
	emit_op(em, .Loop, line)
	offset := len(current_chunk(em).code) - loop_start + 2
	if offset > 0xffff {
		emit_error(em, line, "Loop body too large.")
	}
	emit_byte(em, u8((offset >> 8) & 0xff), line)
	emit_byte(em, u8(offset & 0xff), line)
}

// emit_property_cache allocates a fresh monomorphic-inline-cache slot
// and emits it as the trailing operand byte of a Get_Property/Invoke
// instruction -- see core/chunk.odin's Property_Cache doc comment. Guards
// the 255-slots-per-chunk limit the u8 index implies, matching
// emit_property_cache exactly.
emit_property_cache :: proc(em: ^Emitter, line: int) {
	chunk := current_chunk(em)
	if len(chunk.property_caches) == 255 {
		emit_error(em, line, "Too many property accesses/method calls in one function.")
	}
	emit_byte(em, core.chunk_add_property_cache(chunk), line)
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

// set_vec_field_op_for_ref is set_op_for_ref's counterpart for
// swizzle-component assignment (`v.x = expr`) directly on a bare
// variable -- see emit_expr.odin's emit_swizzle_set and core/chunk.odin's
// Set_*_Vec_Field family doc comment.
set_vec_field_op_for_ref :: proc(kind: Var_Ref_Kind) -> core.Op_Code {
	#partial switch kind {
	case .Local:
		return .Set_Local_Vec_Field
	case .Upvalue:
		return .Set_Upvalue_Vec_Field
	case .Global:
		return .Set_Global_Vec_Field
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

// DebugSkipPeephole is a package-level toggle (intended for a future
// `-n`/`--no-peephole` CLI flag) for disabling the peephole optimizer.
// Read only when constructing an Emitter (see emit_program/Compile_Repl
// in compile.odin), which copies it into that Emitter's own skip_peephole
// field -- end_function_emit reads *that*, not this global directly, so
// one compile's behavior is a stable snapshot rather than shared mutable
// state another concurrent compile could flip mid-run.
DebugSkipPeephole := false

// -----------------------------------------------------------------------
// Compile-time peephole optimizer -- rewrites two fixed-shape 8-byte
// instruction sequences in place, padding with Noop so already-computed
// jump offsets elsewhere in the chunk stay valid (nothing shifts). This
// is stage one of a two-stage design: the VM further specializes
// Add_Nn/Incr_Const_N into their _Ii/_Ff type-specific children at
// runtime, on first execution (a minimal inline cache) -- see
// docs/ARCHITECTURE.md's Chunk section. Runs on the finished Chunk
// regardless of how it was generated, so it's unaffected by the parse/
// resolve/emit split.

// Numeric_Fuse_Family: one row per arithmetic operator this pass fuses --
// the plain source opcode Get_Local/Get_Local(or Constant)/<source_op>/
// Set_Local/Pop compiles to, and the two fused opcodes (local-local,
// local-constant) it collapses into. Subtract/Multiply/Divide are
// generalizations of the original Add_Numeric/Add_Nn/Incr_Const_N case;
// see chunk.odin's Op_Code doc comment for why their _Ii/_Ff children
// still re-check types every execution instead of trusting the first
// patch the way Add_Ii/Add_Ff do.
@(private = "file")
Numeric_Fuse_Family :: struct {
	source_op:      core.Op_Code,
	local_local_op: core.Op_Code,
	local_const_op: core.Op_Code,
}

@(private = "file")
numeric_fuse_families := [4]Numeric_Fuse_Family {
	{.Add_Numeric, .Add_Nn, .Incr_Const_N},
	{.Subtract, .Sub_Nn, .Decr_Const_N},
	{.Multiply, .Mul_Nn, .Mul_Const_N},
	{.Divide, .Div_Nn, .Div_Const_N},
}

@(private = "file")
peephole_optimise :: proc(c: ^core.Chunk) {
	code := c.code
	i := 0
	for i + 7 < len(code) {
		is_get_local := code[i] == u8(core.Op_Code.Get_Local)
		tail_matches :=
			code[i + 5] == u8(core.Op_Code.Set_Local) &&
			code[i + 6] == code[i + 1] &&
			code[i + 7] == u8(core.Op_Code.Pop)

		if is_get_local && tail_matches {
			matched := false
			for family in numeric_fuse_families {
				if code[i + 4] != u8(family.source_op) {
					continue
				}
				if code[i + 2] == u8(core.Op_Code.Get_Local) {
					fuse(code, i, family.local_local_op, code[i + 1], code[i + 3])
					matched = true
				} else if code[i + 2] == u8(core.Op_Code.Constant) {
					// `x += 1` (and only `+=` -- Subtract/Multiply/Divide
					// have no equivalent "by exactly one" shortcut worth
					// its own opcode) collapses one step further: Inc_Local
					// hardcodes +1 with no constant-pool lookup at all, a
					// strictly smaller instruction than Incr_Const_N/I/F
					// for the single most common loop-counter shape.
					if family.source_op == .Add_Numeric && constant_is_one(c, code[i + 3]) {
						fuse_one_operand(code, i, .Inc_Local, code[i + 1])
					} else {
						fuse(code, i, family.local_const_op, code[i + 1], code[i + 3])
					}
					matched = true
				}
				break
			}
			if matched {
				i += 8
				continue
			}
		}
		// `++` (Add_Vector) has no Constant-operand sibling: a vector is
		// always produced by a vec2/3/4() call or another Add_Vector/
		// property read, never the compile-time constant pool -- see
		// docs/plans/vec-op-peephole.md's Scope section.
		if is_get_local && tail_matches && code[i + 4] == u8(core.Op_Code.Add_Vector) && code[i + 2] == u8(core.Op_Code.Get_Local) {
			fuse(code, i, .Add_Vv, code[i + 1], code[i + 3])
			i += 8
			continue
		}
		i += 1
	}
}

@(private = "file")
constant_is_one :: proc(c: ^core.Chunk, const_idx: u8) -> bool {
	v := c.constants[const_idx]
	if core.is_int(v) {
		return core.as_int(v) == 1
	}
	if core.is_float(v) {
		return core.as_float(v) == 1
	}
	return false
}

@(private = "file")
fuse :: proc(code: [dynamic]u8, i: int, op: core.Op_Code, a, b: u8) {
	code[i] = u8(op)
	code[i + 1] = a
	code[i + 2] = b
	for k in i + 3 ..= i + 7 {
		code[k] = u8(core.Op_Code.Noop)
	}
}

// fuse_one_operand is fuse's single-operand sibling, for Inc_Local (just
// a slot, no second operand byte at all -- see vm/run.odin's dispatch).
@(private = "file")
fuse_one_operand :: proc(code: [dynamic]u8, i: int, op: core.Op_Code, a: u8) {
	code[i] = u8(op)
	code[i + 1] = a
	for k in i + 2 ..= i + 7 {
		code[k] = u8(core.Op_Code.Noop)
	}
}
