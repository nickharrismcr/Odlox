package core

// Native_Object wraps a Lox-callable native function (a `len`/`append`/
// raylib-binding/etc. implemented in Odin rather than compiled Lox
// bytecode). Builtin_Fn's `vm` parameter is `rawptr`, not `^VM`, since
// `core` sits below `vm` in the package graph and cannot import it; every
// native function's first line casts it back to the concrete `^vm.VM`.
Builtin_Fn :: #type proc(argc: int, arg_stack_ptr: int, vm: rawptr) -> Value

Native_Object :: struct {
	using obj: Obj,
	function:  Builtin_Fn,
}

make_native_object :: proc(function: Builtin_Fn) -> ^Native_Object {
	o := new(Native_Object)
	o.obj.type = .Native
	o.function = function
	return o
}
