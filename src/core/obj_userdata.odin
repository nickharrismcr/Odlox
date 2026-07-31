package core

import "core:mem"

// Userdata_Object: a pluggable heap-object kind for native-extension
// objects (gfx/physics/sound/... -- anything owned by the `natives`
// package) that would otherwise need their own bespoke Object_Type case
// threaded through every switch in core/object.odin and vm/gc.odin.
// Behavior is supplied per concrete kind via a Userdata_Vtable, built and
// owned entirely by whichever natives/*.odin file constructs the object
// -- core and vm never learn the concrete data type, they just dispatch
// through the function pointers stored here. This is the one Object_Type
// case native code should ever need; see obj_sound.odin (in natives, not
// core -- this is the prototype of the split) for a worked example.
//
// The vm_ctx parameter on mark/invoke mirrors Builtin_Fn's `vm: rawptr`
// convention (see obj_native.odin's doc comment): core sits below vm in
// the package graph and cannot spell `^vm.VM`, so the boundary is a bare
// opaque pointer that vm's own call sites cast back before invoking the
// vtable, and that natives casts back again via vm.native_vm/native_vm-
// equivalent helpers on the other side of the call.
Userdata_Vtable :: struct {
	// tag: used for the default object_to_string rendering ("<tag>")
	// when to_string is nil, and for debug/error output.
	tag: string,

	// mark: trace any Obj-typed children data holds, via vm.mark_object
	// (vm_ctx cast back to ^vm.VM first). nil if data holds no Obj
	// pointers -- the common case.
	mark: proc(vm_ctx: rawptr, data: rawptr),

	// free: release data's own resources (external handles, backing
	// slices, ...) and data itself (a matching `free(cast(^Concrete_Type)data)`).
	// Never nil -- every userdata kind owns at least the alloc backing data.
	free: proc(data: rawptr),

	// to_string: nil falls back to "<tag>", matching how most native
	// object kinds print today (e.g. "<sound>", "<process>").
	to_string: proc(data: rawptr, allocator: mem.Allocator) -> string,

	// size: rough byte estimate for the GC heap-growth heuristic (see
	// vm/gc.odin's object_size doc comment). nil means "just the struct
	// header" -- object_size in vm/gc.odin already adds size_of(Userdata_Object).
	size: proc(data: rawptr) -> int,

	// invoke: dispatch a `.method(args)` call. Never nil.
	invoke: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool,
}

Userdata_Object :: struct {
	using obj: Obj,
	vtable:    ^Userdata_Vtable,
	data:      rawptr,
}

make_userdata_object :: proc(vtable: ^Userdata_Vtable, data: rawptr) -> ^Userdata_Object {
	o := new(Userdata_Object)
	o.obj.type = .Userdata
	o.vtable = vtable
	o.data = data
	return o
}
