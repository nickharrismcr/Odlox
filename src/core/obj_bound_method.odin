package core

// Bound_Method_Object is what `instance.method` (as a value, not a call)
// produces: a receiver snapshot paired with the unbound method closure --
// calling it later re-supplies `receiver` as the implicit first argument.
Bound_Method_Object :: struct {
	using obj: Obj,
	receiver:  Value,
	method:    ^Closure_Object,
}

make_bound_method_object :: proc(receiver: Value, method: ^Closure_Object) -> ^Bound_Method_Object {
	o := new(Bound_Method_Object)
	o.obj.type = .Bound_Method
	o.receiver = receiver
	o.method = method
	return o
}
