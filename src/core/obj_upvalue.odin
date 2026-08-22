package core

// Upvalue_Object is how a closure captures a variable from an enclosing
// function's stack frame. `location` points at the live value: either
// straight into the VM's value stack while "open", or at this object's
// own `closed` field once the VM detaches it. `next_open` chains every
// open upvalue into the VM's sorted-by-slot list; named `next_open` rather
// than `next` because `using obj: Obj` already promotes the GC's unrelated
// `Obj.next` sweep-list link into this scope.
Upvalue_Object :: struct {
	using obj: Obj,
	location:  ^Value,
	slot:      int,
	next_open: ^Upvalue_Object,
	closed:    Value,
}

make_upvalue_object :: proc(location: ^Value, slot: int) -> ^Upvalue_Object {
	uv := new(Upvalue_Object)
	uv.obj.type = .Upvalue
	uv.location = location
	uv.slot = slot
	uv.closed = NIL_VALUE
	return uv
}
