package debug

import "../core"
import "core:fmt"

// Port of glox's src/debug/debug.go: a bytecode disassembler for
// `Chunk`. One case per opcode below, each picking the formatter that
// matches its operand shape. The operand shapes themselves aren't
// duplicated from anywhere — they're this port's own choice (this
// compiler and this VM are both implemented here), and the
// authoritative source for each is the emission site in
// src/compiler/*.odin. Where a shape isn't obvious from the opcode
// name alone, the comment says which emission site to check.
//
// This is deliberately a different, fuller tool than
// compile_test.odin's `decode` helper: that one only needs to skip the
// right number of operand bytes to walk a chunk in tests. This one has
// to render every operand in a form a human debugging the compiler or
// VM can actually read — resolved jump targets, constant values,
// upvalue-capture kind, etc.

// disassemble_chunk prints every instruction in c, prefixed with a
// `== name ==` banner (matches clox's own `disassembleChunk`).
disassemble_chunk :: proc(c: ^core.Chunk, name: string) {
	fmt.printfln("== %s ==", name)
	offset := 0
	for offset < len(c.code) {
		offset = disassemble_instruction(c, offset)
	}
}

// disassemble_program disassembles fn's own chunk, then recurses into
// every Function constant in its constant pool (nested `func`
// declarations, methods, lambdas) so one call dumps everything a
// compiled script contains -- a single top-level Chunk only holds the
// top-level code; every function body is its own separate Chunk stored
// as a constant (see obj_function.odin's Function_Object.chunk).
// visited guards against printing the same Function_Object twice (it's
// a plain constant-pool entry, so nothing stops two call sites from
// sharing one lambda if the compiler ever dedups them).
disassemble_program :: proc(fn: ^core.Function_Object) {
	visited: map[^core.Function_Object]bool
	defer delete(visited)
	disassemble_program_rec(fn, &visited)
}

@(private = "file")
disassemble_program_rec :: proc(fn: ^core.Function_Object, visited: ^map[^core.Function_Object]bool) {
	if visited[fn] {
		return
	}
	visited[fn] = true

	name := core.function_to_string(fn)
	disassemble_chunk(fn.chunk, name)
	fmt.println()

	for v in fn.chunk.constants {
		if v.type == .Obj && v.obj_type == .Function {
			disassemble_program_rec(core.as_function(v), visited)
		}
	}
}

// disassemble_instruction prints the single instruction at offset and
// returns the offset of the next one. Exported (not just used by
// disassemble_chunk) so a trace hook can call it once per step without
// re-walking the whole chunk from the start.
disassemble_instruction :: proc(c: ^core.Chunk, offset: int) -> int {
	fmt.printf("%04d ", offset)
	if offset > 0 && c.lines[offset] == c.lines[offset - 1] {
		fmt.printf("   | ")
	} else {
		fmt.printf("%4d ", c.lines[offset])
	}

	op := core.Op_Code(c.code[offset])
	switch op {
	// --- no operands ---
	case .Return, .Noop, .Negate, .Add_Numeric, .Concat, .Add_Vector,
	     .Subtract, .Multiply, .Divide, .Modulus, .Nil, .True, .False,
	     .Not, .Equal, .Greater, .Less, .Print, .Str, .Pop, .Dup, .One,
	     .Create_Tuple, .Index, .Index_Assign, .Slice, .Slice_Assign,
	     .In, .Close_Upvalue, .Inherit, .Raise, .End_Except,
	     .Finally, .End_Foreach, .Breakpoint:
		return simple_instruction(op, offset)

	// --- one-byte constant-pool index ---
	case .Constant, .Get_Property, .Set_Property, .Method,
	     .Static_Method, .Class_Var, .Get_Super:
		return constant_instruction(op, c, offset)

	// --- one-byte global slot -- NOT a constant-pool index. Slots are
	// numbered into Environment.globals; Chunk.global_names (populated
	// only on the top-level chunk -- see chunk.odin's doc comment) is
	// the only place a slot's name can be recovered from, and even
	// that's only meaningful for the outermost chunk. ---
	case .Get_Global, .Set_Global, .Define_Global, .Define_Global_Const:
		return global_instruction(op, c, offset)

	// --- one-byte local slot -- Chunk.local_vars (debug info recorded
	// by the compiler's add_local/end_local -- see compiler_state.odin)
	// lets these show the variable's source name, not just its slot
	// number. ---
	case .Get_Local, .Set_Local, .Inc_Local:
		return local_instruction(op, c, offset)

	// --- one-byte upvalue slot -- indexes the *enclosing* function's
	// captured-variable list, which isn't recorded in this chunk at
	// all, so (unlike a local) there's no name to recover here. ---
	case .Get_Upvalue, .Set_Upvalue:
		return byte_instruction(op, c, offset)

	// --- one-byte plain count/index (not a constant-pool index) ---
	case .Call, .Create_List, .Create_Dict, .Unpack:
		return byte_instruction(op, c, offset)

	// --- Class: name is a constant, but there's no receiver/value to
	// show alongside it the way Get/Set_Property have -- same shape as
	// constant_instruction either way. ---
	case .Class:
		return constant_instruction(op, c, offset)

	// --- two-byte forward/backward jump offset. Loop is the only
	// backward one of this group (emit_loop computes its offset
	// directly at emission time); Jump_If_False/Jump/Try/End_Try are
	// all forward placeholders patched later by patch_jump. ---
	case .Jump_If_False, .Jump, .Loop, .Try, .End_Try:
		sign := -1 if op == .Loop else 1
		return jump_instruction(op, sign, c, offset)

	// --- Except: [type_const][skip_hi][skip_lo] -- see
	// stmt.odin's try_except_statement and vm/exceptions.odin. ---
	case .Except:
		return except_instruction(c, offset)

	// --- Jump_If_Defined: [slot][jump_hi][jump_lo] -- see
	// functions.odin's emit_jump_if_defined. ---
	case .Jump_If_Defined:
		return jump_if_defined_instruction(c, offset)

	// --- Foreach: [var_slot][iter_slot][jump_hi][jump_lo] -- see
	// stmt.odin's foreach_statement. ---
	case .Foreach:
		return foreach_instruction(c, offset)

	// --- Next: [jump_hi][jump_lo][var_slot][iter_slot] -- see
	// stmt.odin's foreach_statement. ---
	case .Next:
		return next_instruction(c, offset)

	// --- Invoke/Super_Invoke: [name_const][arg_count] -- see
	// expr.odin's dot/super_. ---
	case .Invoke, .Super_Invoke:
		return invoke_instruction(op, c, offset)

	// --- Import: [module_const][alias_const] -- see stmt.odin's
	// import_statement. ---
	case .Import:
		return two_const_instruction(op, c, offset)

	// --- Import_From: [module_const][count][name_const]* -- see
	// stmt.odin's from_import_statement. ---
	case .Import_From:
		return import_from_instruction(c, offset)

	// --- Closure: [const_idx]([is_local][index])* -- see
	// functions.odin's emit_closure. ---
	case .Closure:
		return closure_instruction(c, offset)

	// --- Self-specializing arithmetic family: [slot_a][operand_b],
	// where operand_b is a local slot (Add_Nn/_Ii/_Ff) or a constant
	// index (Incr_Const_N/_I/_F) -- see compiler_state.odin's fuse. ---
	case .Add_Nn, .Add_Ii, .Add_Ff:
		return two_byte_instruction(op, c, offset)
	case .Incr_Const_N, .Incr_Const_I, .Incr_Const_F:
		return incr_const_instruction(op, c, offset)

	case:
		fmt.printfln("Unknown opcode %d", op)
		return offset + 1
	}
}

@(private = "file")
simple_instruction :: proc(op: core.Op_Code, offset: int) -> int {
	fmt.printfln("%v", op)
	return offset + 1
}

@(private = "file")
byte_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	slot := c.code[offset + 1]
	fmt.printfln("%-16v %4d", op, slot)
	return offset + 2
}

@(private = "file")
two_byte_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	a := c.code[offset + 1]
	b := c.code[offset + 2]
	fmt.printfln("%-16v slot=%d slot=%d", op, a, b)
	return offset + 3
}

@(private = "file")
incr_const_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	slot := c.code[offset + 1]
	const_idx := c.code[offset + 2]
	fmt.printfln("%-16v slot=%d const=%d %v", op, slot, const_idx, const_repr(c, const_idx))
	return offset + 3
}

@(private = "file")
local_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	slot := c.code[offset + 1]
	name := local_name_at(c, offset, slot)
	if name != "" {
		fmt.printfln("%-16v %4d (%s)", op, slot, name)
	} else {
		fmt.printfln("%-16v %4d", op, slot)
	}
	return offset + 2
}

// local_name_at finds the local recorded as live (start_ip <= offset <
// end_ip) in the given slot -- add_local initializes end_ip to -1 and
// end_scope patches it in once the scope closes, so -1 here means
// "still live through the end of the chunk" (see compiler_state.odin's
// add_local/end_scope).
@(private = "file")
local_name_at :: proc(c: ^core.Chunk, offset: int, slot: u8) -> string {
	for lv in c.local_vars {
		if lv.slot != int(slot) {
			continue
		}
		if offset < lv.start_ip {
			continue
		}
		if lv.end_ip != -1 && offset >= lv.end_ip {
			continue
		}
		return lv.name
	}
	return ""
}

@(private = "file")
global_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	slot := c.code[offset + 1]
	name := "?"
	if int(slot) < len(c.global_names) {
		name = c.global_names[slot]
	}
	fmt.printfln("%-16v %4d (%s)", op, slot, name)
	return offset + 2
}

@(private = "file")
constant_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	const_idx := c.code[offset + 1]
	fmt.printfln("%-16v %4d %v", op, const_idx, const_repr(c, const_idx))
	return offset + 2
}

@(private = "file")
two_const_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	a := c.code[offset + 1]
	b := c.code[offset + 2]
	fmt.printfln("%-16v %v as %v", op, const_repr(c, a), const_repr(c, b))
	return offset + 3
}

@(private = "file")
invoke_instruction :: proc(op: core.Op_Code, c: ^core.Chunk, offset: int) -> int {
	name_const := c.code[offset + 1]
	arg_count := c.code[offset + 2]
	fmt.printfln("%-16v %v (%d args)", op, const_repr(c, name_const), arg_count)
	return offset + 3
}

@(private = "file")
jump_instruction :: proc(op: core.Op_Code, sign: int, c: ^core.Chunk, offset: int) -> int {
	jump := int(c.code[offset + 1]) << 8 | int(c.code[offset + 2])
	target := offset + 3 + sign * jump
	fmt.printfln("%-16v %4d -> %d", op, offset, target)
	return offset + 3
}

@(private = "file")
jump_if_defined_instruction :: proc(c: ^core.Chunk, offset: int) -> int {
	slot := c.code[offset + 1]
	jump := int(c.code[offset + 2]) << 8 | int(c.code[offset + 3])
	target := offset + 4 + jump
	fmt.printfln("%-16v slot=%d %4d -> %d", core.Op_Code.Jump_If_Defined, slot, offset, target)
	return offset + 4
}

@(private = "file")
except_instruction :: proc(c: ^core.Chunk, offset: int) -> int {
	type_const := c.code[offset + 1]
	skip := int(c.code[offset + 2]) << 8 | int(c.code[offset + 3])
	next_clause := offset + 4 + skip
	fmt.printfln("%-16v %v next-clause=%d", core.Op_Code.Except, const_repr(c, type_const), next_clause)
	return offset + 4
}

@(private = "file")
foreach_instruction :: proc(c: ^core.Chunk, offset: int) -> int {
	var_slot := c.code[offset + 1]
	iter_slot := c.code[offset + 2]
	jump := int(c.code[offset + 3]) << 8 | int(c.code[offset + 4])
	target := offset + 5 + jump
	fmt.printfln(
		"%-16v var=%d iter=%d end=%d",
		core.Op_Code.Foreach,
		var_slot,
		iter_slot,
		target,
	)
	return offset + 5
}

@(private = "file")
next_instruction :: proc(c: ^core.Chunk, offset: int) -> int {
	jump := int(c.code[offset + 1]) << 8 | int(c.code[offset + 2])
	var_slot := c.code[offset + 3]
	iter_slot := c.code[offset + 4]
	target := offset + 5 - jump
	fmt.printfln(
		"%-16v var=%d iter=%d loop=%d",
		core.Op_Code.Next,
		var_slot,
		iter_slot,
		target,
	)
	return offset + 5
}

@(private = "file")
import_from_instruction :: proc(c: ^core.Chunk, offset: int) -> int {
	module_const := c.code[offset + 1]
	count := c.code[offset + 2]
	fmt.printf("%-16v %v from %v (", core.Op_Code.Import_From, "*" if count == 0 else "names", const_repr(c, module_const))
	for i in 0 ..< int(count) {
		if i > 0 {
			fmt.printf(", ")
		}
		fmt.printf("%v", const_repr(c, c.code[offset + 3 + i]))
	}
	fmt.printfln(")")
	return offset + 3 + int(count)
}

@(private = "file")
closure_instruction :: proc(c: ^core.Chunk, offset: int) -> int {
	const_idx := c.code[offset + 1]
	fn := core.as_function(c.constants[const_idx])
	fmt.printfln("%-16v %4d %v", core.Op_Code.Closure, const_idx, const_repr(c, const_idx))
	off := offset + 2
	for _ in 0 ..< fn.upvalue_count {
		is_local := c.code[off] != 0
		index := c.code[off + 1]
		kind := "local" if is_local else "upvalue"
		fmt.printfln("%04d      |                     %s %d", off, kind, index)
		off += 2
	}
	return off
}

// const_repr renders a constant-pool value compactly for disassembly
// output. Not core.value_to_string directly at the call sites above so
// this stays free to special-case anything that reads badly in that
// generic form later (e.g. a Function constant's own name) without
// touching every call site.
@(private = "file")
const_repr :: proc(c: ^core.Chunk, idx: u8) -> string {
	if int(idx) >= len(c.constants) {
		return "<out of range>"
	}
	return core.value_to_string(c.constants[idx])
}
