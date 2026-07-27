package core

// Op_Code: one variant per bytecode instruction. Odin's enums are
// namespaced under the type (`.Constant` reads fine at a use site), so
// there's no need for glox's `OP_` prefix, which exists only to avoid
// colliding in Go's flat package-level namespace.
//
// Two families are worth knowing about up front, both fully explained
// where the compiler/VM (Phases 3-4) actually implement them:
//
//   - Add_Nn/Add_Ii/Add_Ff and Incr_Const_N/Incr_Const_I/Incr_Const_F are
//     a compile-time peephole fusion (Add_Nn, Incr_Const_N) that the VM
//     then further specializes at runtime via in-place opcode-byte
//     patching on first execution (a minimal inline cache) into the
//     type-specific Ii/Ff variants.
//   - Try/End_Try/Except/End_Except/Finally/Raise implement
//     try/except/finally -- the bytecode shape and VM-side matching loop
//     are involved enough that they get their own design document
//     (glox's docs/exception-handling.md) rather than a summary here;
//     read that directly when implementing them.
Op_Code :: enum u8 {
	Return,
	Noop,
	Constant,
	Negate,

	Add_Numeric,
	Concat,
	Add_Vector,
	Subtract,
	Multiply,
	Divide,
	Modulus,

	Nil,
	True,
	False,
	Not,

	Equal,
	Greater,
	Less,

	Print,
	Str,
	Pop,
	Dup,
	One,

	Define_Global,
	Define_Global_Const,
	Get_Global,
	Set_Global,

	Get_Local,
	Set_Local,
	Inc_Local,

	Jump_If_False,
	Jump,
	Loop,
	Jump_If_Defined,

	Call,

	Create_List,
	Create_Dict,
	Create_Tuple,

	Index,
	Index_Assign,
	Slice,
	Slice_Assign,
	In,
	Unpack,

	Closure,
	Get_Upvalue,
	Set_Upvalue,
	Close_Upvalue,

	Class,
	Set_Property,
	Get_Property,
	Method,
	Static_Method,
	Class_Var,

	Invoke,
	Inherit,
	Get_Super,
	Super_Invoke,

	Import,
	Import_From,

	Try,
	End_Try,
	Except,
	End_Except,
	Finally,
	Raise,

	Foreach,
	Next,
	End_Foreach,

	Breakpoint,

	// Self-specializing arithmetic family; see the doc comment above.
	Add_Nn,
	Add_Ii,
	Add_Ff,
	Incr_Const_N,
	Incr_Const_I,
	Incr_Const_F,
}

Local_Var_Info :: struct {
	name:     string,
	start_ip: int,
	end_ip:   int,
	slot:     int,
}

// Chunk: one per compiled function (Function_Object.chunk) or top-level
// script. `global_names`/`global_count` are only ever populated on the
// *top-level* script's own chunk -- every function in one compilation
// unit shares a single Environment for globals, so inner functions
// resolve global names/slots through that shared Environment rather than
// carrying their own copy (see environment.odin).
Chunk :: struct {
	code:            [dynamic]u8,
	constants:       [dynamic]Value,
	lines:           [dynamic]int, // parallel to code: one entry per byte
	filename:        string,
	local_vars:      [dynamic]Local_Var_Info, // debug info
	global_count:    int,
	global_names:    [dynamic]string,
	property_caches: [dynamic]Property_Cache,
}

// Property_Cache backs the monomorphic inline cache on Get_Property and
// Invoke: one per callsite, allocated at compile time
// (chunk_add_property_cache) and carried as an extra bytecode operand
// (the cache's index into this array), not looked up by class identity
// in some shared map -- a real O(1) array access on a hit, not another
// hash lookup wearing an inline cache's clothes. `class == nil` means
// "never populated" (cold).
//
// Caches only the class -> method resolution (Class_Object.methods),
// never the receiver's own instance-fields lookup: that can't be safely
// cached at the class level at all, since Lox instances have no fixed
// shape -- two instances of the same class can have different field
// sets, so a field that happens to mask a method on one instance doesn't
// mean it does on another. See vm/call.odin's invoke and
// vm/properties.odin's get_property for exactly which lookup this skips
// (always the *second* one, after a same-class field-lookup miss).
Property_Cache :: struct {
	class:  ^Class_Object,
	method: Value,
}

new_chunk :: proc(filename: string) -> ^Chunk {
	c := new(Chunk)
	c.filename = filename
	return c
}

// chunk_add_property_cache allocates a fresh, cold cache slot and
// returns its index -- called once per Get_Property/Invoke callsite at
// compile time (compiler/expr.odin's dot), mirroring chunk_add_constant's
// shape. u8-indexed like every other operand in this bytecode format, so
// a single function emitting more than 255 property/method-call
// expressions hits the same kind of hard limit the 255-argument-list
// check already does -- checked at the call site, not here, matching
// that existing pattern.
chunk_add_property_cache :: proc(c: ^Chunk) -> u8 {
	append(&c.property_caches, Property_Cache{})
	return u8(len(c.property_caches) - 1)
}

chunk_write_op :: proc(c: ^Chunk, op: Op_Code, line: int) {
	append(&c.code, u8(op))
	append(&c.lines, line)
}

chunk_write_byte :: proc(c: ^Chunk, b: u8, line: int) {
	append(&c.code, b)
	append(&c.lines, line)
}

// chunk_add_constant appends v to the constant pool and returns its
// index, reusing an existing equal entry where that's safe. It is NOT
// safe for Closure/Function/Bound_Method constants: two occurrences of
// (say) a lambda literal in the same chunk must each produce their own
// runtime object when OP_CLOSURE runs, so those three kinds are always
// appended fresh, never deduplicated, regardless of value equality.
chunk_add_constant :: proc(c: ^Chunk, v: Value) -> u8 {
	if is_dedupable_constant(v) {
		for existing, i in c.constants {
			if values_equal(v, existing, true) {
				return u8(i)
			}
		}
	}
	append(&c.constants, v)
	return u8(len(c.constants) - 1)
}

@(private = "file")
is_dedupable_constant :: proc(v: Value) -> bool {
	if v.type != .Obj {
		return true
	}
	#partial switch v.obj_type {
	case .Bound_Method, .Closure, .Function:
		return false
	}
	return true
}

// chunk_slot_for_name looks up a global's slot purely from this chunk's
// own record of it -- only meaningful on the top-level chunk (see the
// struct doc comment); inner functions should resolve names through
// Environment.global_names/env_slot_for_name instead.
chunk_slot_for_name :: proc(c: ^Chunk, name: string) -> int {
	for n, i in c.global_names {
		if n == name {
			return i
		}
	}
	return -1
}
