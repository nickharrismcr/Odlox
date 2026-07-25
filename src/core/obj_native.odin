package core

// Native_Object wraps a Lox-callable native function (a `len`/`append`/
// raylib-binding/etc. implemented in Odin rather than compiled Lox
// bytecode).
//
// Builtin_Fn's `vm` parameter is `rawptr`, not `^VM` -- this is a
// deliberate boundary, not a placeholder to "fix later". Value/Chunk/the
// object model (this package, `core`) must sit *below* both `compiler`
// and `vm` in the package graph (vm calls compiler.compile() for module
// imports, so vm depends on compiler, and both depend on core for
// Value/Chunk -- core can depend on neither without a cycle). But a
// native function obviously needs to call back into the running VM
// (read its stack, raise a runtime error, allocate/GC-link a new
// object, ...), and that VM type is defined in the `vm` package, not
// here. glox solves the equivalent problem in Go with a `VMContext`
// interface declared in `core` that `*vm.VM` implements structurally,
// so `core` never has to import `vm` at all. Odin has no structural
// interfaces to borrow that trick from, so the boundary here is a plain
// opaque pointer instead: every native function's first line is a cast
// back to the concrete `^vm.VM` (`vm := (^vm.VM)(vm_ptr)`), which the
// `vm` package provides as a thin, typed wrapper so call sites in
// `vm`/`natives` never write a raw cast themselves. Zero-cost, and it's
// exactly the same shape Odin's own `context.user_ptr` uses to solve
// this same "lower layer needs to call back into a higher one" problem.
//
// (This corrects an earlier draft of docs/ARCHITECTURE.md, which framed
// the core/vm boundary as *only* needing "invert natives' dependency on
// vm" -- true for the `natives` package, but core's own Native_Object
// needed this separate rawptr boundary regardless, since core can't
// import vm either.)
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
