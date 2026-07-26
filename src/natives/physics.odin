package natives

import "../core"
import "../vm"

// physics: glox's own `physics_world` (src/builtin/obj_builtin_physics_world.go)
// is a real hand-rolled spatial-grid physics engine, well beyond this
// pass's scope (same reasoning as gfx.odin's raylib-dependent functions --
// a genuine multi-session port of its own). Registered here only so the
// `physics` module and its `physics_world` name exist at all (matching
// glox's own makeBuiltInModule(vm, "physics") + defineBuiltIn(...,
// "physics_world", ...) shape) -- `type(physics.physics_world)` correctly
// reports "builtin", same as any other native function, without needing
// physics_world to actually be callable yet. Calling it raises a clear
// "not implemented" error rather than silently doing nothing or crashing.

@(private)
register_physics :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "physics")
	vm.define_builtin(v, "physics", "physics_world", physics_world_builtin)
}

@(private = "file")
physics_world_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	vm.runtime_error(v, "physics_world() is not yet implemented in odlox.")
	return core.NIL_VALUE
}
