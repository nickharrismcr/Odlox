package core

// Closure_Object wraps a compiled Function_Object with the actual upvalues
// it captured at the point OP_CLOSURE ran; the same function can be closed
// over many times with distinct upvalue bindings each time, which is why
// Chunk.add_constant refuses to deduplicate such constants. owner_class,
// set only for non-static method closures, must match the receiver's class
// exactly before Get_Field_Slot/Set_Field_Slot trusts a baked-in slot
// index, since do_inherit copies method closures verbatim into subclasses.
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
