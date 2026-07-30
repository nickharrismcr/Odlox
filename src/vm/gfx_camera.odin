package vm

import "../core"
import rl "vendor:raylib"

// gfx_camera: method dispatch for Camera_Object. Construction lives in
// natives/gfx.odin, same split as every other gfx native type.
invoke_builtin_camera :: proc(vm: ^VM, c: ^core.Camera_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "set_position":
		if arg_count != 1 {
			runtime_error(vm, "set_position() expects 1 argument (vec3).")
			return false
		}
		v := peek(vm, 0)
		if !core.is_vec3(v) {
			runtime_error(vm, "set_position() argument must be a vec3.")
			return false
		}
		vv := core.as_vec3(v)
		c.camera.position = rl.Vector3{f32(vv.x), f32(vv.y), f32(vv.z)}
		result = core.NIL_VALUE
	case "set_target":
		if arg_count != 1 {
			runtime_error(vm, "set_target() expects 1 argument (vec3).")
			return false
		}
		v := peek(vm, 0)
		if !core.is_vec3(v) {
			runtime_error(vm, "set_target() argument must be a vec3.")
			return false
		}
		vv := core.as_vec3(v)
		c.camera.target = rl.Vector3{f32(vv.x), f32(vv.y), f32(vv.z)}
		result = core.NIL_VALUE
	case "set_fovy":
		if arg_count != 1 {
			runtime_error(vm, "set_fovy() expects 1 argument (number).")
			return false
		}
		v := peek(vm, 0)
		if !core.is_number(v) {
			runtime_error(vm, "set_fovy() argument must be a number.")
			return false
		}
		c.camera.fovy = f32(core.as_float(v))
		result = core.NIL_VALUE
	case "update":
		if arg_count != 0 {
			runtime_error(vm, "update() takes no arguments.")
			return false
		}
		rl.UpdateCamera(&c.camera, .FREE)
		result = core.NIL_VALUE
	case "get_position":
		if arg_count != 0 {
			runtime_error(vm, "get_position() takes no arguments.")
			return false
		}
		p := c.camera.position
		o := alloc_vec3(vm, f64(p.x), f64(p.y), f64(p.z))
		result = core.Value{type = .Vec3, obj_type = .Vec3, obj = &o.obj}
	case:
		runtime_error(vm, "Undefined Camera method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
