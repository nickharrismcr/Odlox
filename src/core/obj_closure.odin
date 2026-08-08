package core

// Closure_Object wraps a compiled Function_Object with the actual
// upvalues it captured at the point OP_CLOSURE ran -- the same function
// compiled once can be closed over many times (e.g. once per outer call),
// producing a distinct Closure_Object with distinct upvalue bindings each
// time. This is why Chunk.add_constant refuses to deduplicate a
// Closure/Function/Bound_Method constant (see chunk.odin): each
// occurrence in the bytecode must still produce its own object at
// runtime, not share one.
// owner_class is set once, in vm/properties.odin's do_method, only for a
// non-static method closure -- the Class_Object it was textually
// declared in. Get_Field_Slot/Set_Field_Slot's VM dispatch (run.odin)
// only trusts a baked-in field-slot index when the receiver's own class
// matches this exactly: do_inherit copies method closures verbatim into
// a subclass's method table, so a superclass method's closure can run
// against a subclass instance whose field-slot table wasn't built from
// the same init, and a mismatched slot index would be a real
// out-of-bounds/misaligned read, not just a missed optimization. nil for
// a closure that isn't a method at all (top-level function, lambda) or a
// static method (this is irrelevant there).
Closure_Object :: struct {
	using obj:     Obj,
	function:      ^Function_Object,
	upvalues:      []^Upvalue_Object,
	upvalue_count: int,
	owner_class:   ^Class_Object,
}

make_closure_object :: proc(function: ^Function_Object) -> ^Closure_Object {
	c := new(Closure_Object)
	c.obj.type = .Closure
	c.function = function
	c.upvalues = make([]^Upvalue_Object, function.upvalue_count)
	c.upvalue_count = function.upvalue_count
	return c
}
