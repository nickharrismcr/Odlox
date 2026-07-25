package core

// Closure_Object wraps a compiled Function_Object with the actual
// upvalues it captured at the point OP_CLOSURE ran -- the same function
// compiled once can be closed over many times (e.g. once per outer call),
// producing a distinct Closure_Object with distinct upvalue bindings each
// time. This is why Chunk.add_constant refuses to deduplicate a
// Closure/Function/Bound_Method constant (see chunk.odin): each
// occurrence in the bytecode must still produce its own object at
// runtime, not share one.
Closure_Object :: struct {
	using obj:     Obj,
	function:      ^Function_Object,
	upvalues:      []^Upvalue_Object,
	upvalue_count: int,
}

make_closure_object :: proc(function: ^Function_Object) -> ^Closure_Object {
	c := new(Closure_Object)
	c.obj.type = .Closure
	c.function = function
	c.upvalues = make([]^Upvalue_Object, function.upvalue_count)
	c.upvalue_count = function.upvalue_count
	return c
}
