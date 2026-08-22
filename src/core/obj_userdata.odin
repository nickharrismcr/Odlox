package core

import "core:mem"

// Userdata_Object: a pluggable heap-object kind for native-extension
// objects (gfx/physics/sound/...) that would otherwise need their own
// bespoke Object_Type case threaded through every switch in core/object.odin
// and vm/gc.odin. Behavior is supplied per concrete kind via a
// Userdata_Vtable, owned by whichever natives/*.odin file constructs the
// object. vm_ctx is a bare opaque pointer, same as Builtin_Fn's `vm:
// rawptr`, since core cannot spell `^vm.VM`.
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

	// get_property: resolve a bare `.NAME` property read (not a call) --
	// e.g. Window's win.KEY_SPACE/win.BLEND_ALPHA/win.BATCH_CUBE
	// constants. nil for every kind with no such properties (the common
	// case -- everything so far except Window).
	get_property: proc(data: rawptr, name: string) -> (Value, bool),
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
