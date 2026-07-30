package natives

import "../core"
import "../vm"

// physics: a hand-rolled 3D SoA sphere/box physics engine, no raylib
// dependency at all. The real simulation logic lives in
// vm/physics_world.odin (mutating core/obj_physics_world.odin's
// Physics_World_Object directly); this file is just the thin argument-
// marshalling constructor, matching natives/process.odin's and
// natives/re.odin's shape.

@(private)
register_physics :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "physics")
	vm.define_builtin(v, "physics", "physics_world", physics_world_builtin)
}

@(private = "file")
physics_world_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 4 {
		vm.runtime_error(v, "physics_world() expects 4 arguments (min, max, cell_size, gravity).")
		return core.NIL_VALUE
	}
	min_val := v.stack[arg_stack_ptr]
	max_val := v.stack[arg_stack_ptr + 1]
	cell_size_val := v.stack[arg_stack_ptr + 2]
	gravity_val := v.stack[arg_stack_ptr + 3]

	if !core.is_vec3(min_val) {
		vm.runtime_error(v, "physics_world() first argument must be a vec3 (bounds min).")
		return core.NIL_VALUE
	}
	if !core.is_vec3(max_val) {
		vm.runtime_error(v, "physics_world() second argument must be a vec3 (bounds max).")
		return core.NIL_VALUE
	}
	if !core.is_number(cell_size_val) {
		vm.runtime_error(v, "physics_world() third argument must be a number (cell_size).")
		return core.NIL_VALUE
	}
	if !core.is_vec3(gravity_val) {
		vm.runtime_error(v, "physics_world() fourth argument must be a vec3 (gravity).")
		return core.NIL_VALUE
	}

	min_v := core.as_vec3(min_val)
	max_v := core.as_vec3(max_val)
	gravity_v := core.as_vec3(gravity_val)

	w := core.make_physics_world_object(
		core.P_Vec3{min_v.x, min_v.y, min_v.z},
		core.P_Vec3{max_v.x, max_v.y, max_v.z},
		core.as_float(cell_size_val),
		core.P_Vec3{gravity_v.x, gravity_v.y, gravity_v.z},
	)
	vm.gc_track(v, &w.obj)
	return core.make_object_value(&w.obj, true)
}
