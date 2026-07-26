package natives

import "../core"
import "../debug"
import "../vm"

// inspect: VM introspection (get_frame/dump_frame), ported from glox's
// src/debug/inspect.go + src/builtin/core_functions.go's
// DumpFrameBuiltIn/GetFrameBuiltIn. The actual frame-walking logic lives
// in the debug package (debug/inspect.odin), a sibling of this one off
// vm -- this file is just the module registration.

@(private)
register_inspect :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "inspect")
	vm.define_builtin(v, "inspect", "get_frame", inspect_get_frame)
	vm.define_builtin(v, "inspect", "dump_frame", inspect_dump_frame)
}

@(private = "file")
inspect_get_frame :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	return debug.frame_dict_value(v)
}

@(private = "file")
inspect_dump_frame :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	debug.dump_frame(v)
	return core.NIL_VALUE
}
