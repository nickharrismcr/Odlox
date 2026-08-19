package core

// Op_Code: one variant per bytecode instruction. Odin's enums are
// namespaced under the type (`.Constant` reads fine at a use site), so no
// prefix is needed to avoid collisions. Add_Nn/Incr_Const_N and their
// Vv/V2/V3/V4 vector-op counterparts are compile-time peephole fusions
// further specialized at runtime via in-place opcode-byte patching (an
// inline cache) into type-specific variants.
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

	// Compile-time-baked instance field-slot fast path, emitted only for
	// `this.name` access inside the declaring class's own methods; every
	// other property access still compiles to Get_Property/Set_Property.
	Get_Field_Slot,
	Set_Field_Slot,

	// Swizzle-component assignment (`v.x = expr`) write-back family: a
	// vec2/3/4 Value is an inline copy, so mutating a component read via
	// plain Get_Local/Get_Global/Get_Upvalue/Get_Property has nothing to
	// write back into without a matching write-back opcode per storage kind.
	Set_Local_Vec_Field,
	Set_Global_Vec_Field,
	Set_Upvalue_Vec_Field,
	Set_Property_Vec_Field,

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

	// Self-specializing vector-add family; see the doc comment above.
	// Unlike Add_Nn's Ii/Ff children, Add_V2/V3/V4 keep a type guard on
	// every execution rather than trusting the first patch forever.
	Add_Vv,
	Add_V2,
	Add_V3,
	Add_V4,

	// Self-specializing subtract/multiply/divide families, the same
	// peephole-fusion shape as Add_Nn/Incr_Const_N. Subtract/Multiply have
	// alternate operand-type semantics (vector subtraction, string
	// repetition) a later call can still hit after an earlier patch, so
	// their _Ii/_Ff children keep a type guard every execution rather than
	// trusting the first patch forever, like Add_V2/V3/V4 do for vectors.
	Sub_Nn,
	Sub_Ii,
	Sub_Ff,
	Decr_Const_N,
	Decr_Const_I,
	Decr_Const_F,
	Mul_Nn,
	Mul_Ii,
	Mul_Ff,
	Mul_Const_N,
	Mul_Const_I,
	Mul_Const_F,
	Div_Nn,
	Div_Ii,
	Div_Ff,
	Div_Const_N,
	Div_Const_I,
	Div_Const_F,
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
	code:               [dynamic]u8,
	constants:          [dynamic]Value,
	lines:              [dynamic]int, // parallel to code: one entry per byte
	filename:           string,
	local_vars:         [dynamic]Local_Var_Info, // debug info
	global_count:       int,
	global_names:       [dynamic]string,
	property_caches:    [dynamic]Property_Cache,
	field_slot_tables:  [dynamic][]string, // see chunk_add_field_slot_table's doc comment
}

// Property_Cache backs the monomorphic inline cache on Get_Property and
// Invoke: one per callsite, allocated at compile time and carried as an
// extra bytecode operand (an index into this array) for O(1) access on a
// hit. `class == nil` means "never populated" (cold). Caches only the
// class -> method resolution (Class_Object.methods), never the receiver's
// own instance-fields lookup, since Lox instances have no fixed shape.
Property_Cache :: struct {
	class:  ^Class_Object,
	method: Value,
}

new_chunk :: proc(filename: string) -> ^Chunk {
	c := new(Chunk)
	c.filename = filename
	return c
}

// chunk_add_property_cache allocates a fresh, cold cache slot and returns
// its index, called once per Get_Property/Invoke callsite at compile time.
// u8-indexed, so a function emitting more than 255 such expressions hits a
// hard limit checked at the call site, not here.
chunk_add_property_cache :: proc(c: ^Chunk) -> u8 {
	append(&c.property_caches, Property_Cache{})
	return u8(len(c.property_caches) - 1)
}

// chunk_add_field_slot_table registers one class declaration's discovered
// field-slot names (index -> name, in discovery order) and returns its
// index into Chunk.field_slot_tables, emitted as the Class opcode's second
// operand. Called once per class declaration, even for zero discovered
// fields. Only answers "what does slot i mean for this class" at
// class-construction time and in cold paths -- never consulted on
// Get_Field_Slot/Set_Field_Slot's hot path, which reads a literal index.
chunk_add_field_slot_table :: proc(c: ^Chunk, names: []string) -> u8 {
	append(&c.field_slot_tables, names)
	return u8(len(c.field_slot_tables) - 1)
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
