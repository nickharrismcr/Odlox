package core

// Upvalue_Object is how a closure captures a variable from an enclosing
// function's stack frame. `location` points at the live value -- either
// straight into the VM's value stack (while "open", i.e. the enclosing
// frame is still on the call stack) or at this object's own `closed`
// field (once the VM detaches it on scope-exit/return, see the vm
// package's Phase 4 close_upvalues). `next_open` chains every currently-
// open upvalue into the VM's single sorted-by-slot list, mirroring
// clox -- named `next_open` rather than `next` because `using obj: Obj`
// already promotes `Obj.next` (the *garbage collector's* unrelated
// sweep-list link) to this same scope, and Odin (like Go) doesn't allow
// two same-named fields to coexist even when one arrives via embedding.
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
