package vm

import "../core"

// gfx_batch_instanced: method dispatch for Batch_Instanced_Object.
// Construction lives in natives/gfx.odin, matching every other gfx
// native type in this port.
invoke_builtin_batch_instanced :: proc(vm: ^VM, b: ^core.Batch_Instanced_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "add":
		if arg_count != 3 {
			runtime_error(vm, "add() expects 3 arguments (position, rotation axis, angle).")
			return false
		}
		pos_val, axis_val, angle_val := peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_vec3(pos_val) {
			runtime_error(vm, "add() first argument must be a vec3 (position).")
			return false
		}
		if !core.is_vec3(axis_val) {
			runtime_error(vm, "add() second argument must be a vec3 (rotation axis).")
			return false
		}
		if !core.is_float(angle_val) {
			runtime_error(vm, "add() third argument must be a float (angle).")
			return false
		}
		pos := core.as_vec3(pos_val)
		axis := core.as_vec3(axis_val)
		angle := core.as_float(angle_val)
		if !core.batch_instanced_add(b, pos.x, pos.y, pos.z, axis.x, axis.y, axis.z, angle) {
			runtime_error(vm, "add(): max instances reached, cannot add more.")
			return false
		}
		result = core.NIL_VALUE
	case "make_transforms":
		if arg_count != 0 {
			runtime_error(vm, "make_transforms() expects no arguments.")
			return false
		}
		core.batch_instanced_make_transforms(b)
		result = core.NIL_VALUE
	case "draw":
		if arg_count != 1 {
			runtime_error(vm, "draw() expects 1 argument (camera).")
			return false
		}
		camera_val := peek(vm, 0)
		if camera_val.type != .Obj || camera_val.obj_type != .Camera {
			runtime_error(vm, "draw() argument must be a camera.")
			return false
		}
		core.batch_instanced_draw(b)
		result = core.NIL_VALUE
	case "count":
		if arg_count != 0 {
			runtime_error(vm, "count() expects no arguments.")
			return false
		}
		result = core.make_int_value(core.batch_instanced_count(b), true)
	case:
		runtime_error(vm, "Unknown batch_instanced method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
