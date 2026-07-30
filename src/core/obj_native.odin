package core

// Native_Object wraps a Lox-callable native function (a `len`/`append`/
// raylib-binding/etc. implemented in Odin rather than compiled Lox
// bytecode).
//
// Builtin_Fn's `vm` parameter is `rawptr`, not `^VM`: `core` sits below
// both `compiler` and `vm` in the package graph and cannot import
// either, but a native function still needs to call back into the
// running VM (read its stack, raise a runtime error, allocate/GC-link a
// new object, ...). The boundary is a plain opaque pointer instead --
// every native function's first line casts it back to the concrete
// `^vm.VM` (`vm := (^vm.VM)(vm_ptr)`), which the `vm` package provides
// as a thin, typed wrapper so call sites in `vm`/`natives` never write a
// raw cast themselves. See docs/ARCHITECTURE.md's "core.VMContext"
// section for the full rationale.
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
