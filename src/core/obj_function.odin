package core

import "core:strings"

// Function_Object is the compiled form of a `func` declaration or lambda
// -- one per compile-time function, stored as a Chunk constant and
// wrapped in a Closure_Object at runtime by OP_CLOSURE (see the compiler
// and vm packages). `min_arity`/`is_variadic` back default
// and variadic parameters: `min_arity` is the fewest args a caller must
// supply (fixed params with no default), `arity` counts every named
// parameter slot including a trailing `*rest`, and `is_variadic` marks
// that trailing slot as the rest-list rather than an ordinary parameter.
Function_Object :: struct {
	using obj:     Obj,
	arity:         int,
	min_arity:     int,
	is_variadic:   bool,
	chunk:         ^Chunk,
	name:          ^String_Object,
	upvalue_count: int,
	environment:   ^Environment,
}

make_function_object :: proc(filename: string, environment: ^Environment) -> ^Function_Object {
	f := new(Function_Object)
	f.obj.type = .Function
	f.chunk = new_chunk(filename)
	f.name = intern_string("")
	f.environment = environment
	return f
}

function_to_string :: proc(f: ^Function_Object, allocator := context.allocator) -> string {
	if len(f.name.chars) == 0 {
		return "<script>"
	}
	return strings.concatenate({"<fn ", f.name.chars, ">"}, allocator)
}
