package natives

import "../core"
import "../vm"
import rl "vendor:raylib"

// gfx_camera: Camera_Data (a raylib 3D camera), construction, and method
// dispatch. Always perspective projection with a 45° default field of
// view -- there is no way to change projection mode or construct an
// orthographic camera from Lox.

Camera_Data :: struct {
	camera: rl.Camera3D,
}

@(private = "file")
camera_vtable := core.Userdata_Vtable {
	tag    = "Camera3D",
	free   = camera_data_free,
	invoke = camera_invoke,
}

@(private = "file")
camera_data_free :: proc(data: rawptr) {
	free(cast(^Camera_Data)data)
}

// is_camera_value/camera_data_of: package-private (not file-private)
// since gfx_window.odin's begin_3d/gfx_batch_instanced's draw() need
// them too.
@(private)
is_camera_value :: proc(v: core.Value) -> bool {
	return v.type == .Obj && v.obj_type == .Userdata && core.as_userdata(v).vtable == &camera_vtable
}

@(private)
camera_data_of :: proc(v: core.Value) -> ^Camera_Data {
	return cast(^Camera_Data)core.as_userdata(v).data
}

// gfx_camera always creates a perspective-projection camera with a 45°
// default fovy -- see Camera_Data's own doc comment.
@(private)
gfx_camera :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 3 {
		vm.runtime_error(v, "camera() expects 3 arguments: position(vec3), target(vec3), up(vec3).")
		return core.NIL_VALUE
	}
	pos_val, target_val, up_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2]
	if !core.is_vec3(pos_val) || !core.is_vec3(target_val) || !core.is_vec3(up_val) {
		vm.runtime_error(v, "camera() arguments must be vec3.")
		return core.NIL_VALUE
	}
	pos := core.as_vec3(pos_val)
	target := core.as_vec3(target_val)
	up := core.as_vec3(up_val)
	data := new(Camera_Data)
	data.camera = rl.Camera3D {
		position   = rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)},
		target     = rl.Vector3{f32(target.x), f32(target.y), f32(target.z)},
		up         = rl.Vector3{f32(up.x), f32(up.y), f32(up.z)},
		fovy       = 45.0,
		projection = .PERSPECTIVE,
	}
	o := core.make_userdata_object(&camera_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
camera_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	c := cast(^Camera_Data)data
	result: core.Value
	switch name {
	case "set_position":
		if arg_count != 1 {
			vm.runtime_error(v, "set_position() expects 1 argument (vec3).")
			return false
		}
		val := vm.peek(v, 0)
		if !core.is_vec3(val) {
			vm.runtime_error(v, "set_position() argument must be a vec3.")
			return false
		}
		vv := core.as_vec3(val)
		c.camera.position = rl.Vector3{f32(vv.x), f32(vv.y), f32(vv.z)}
		result = core.NIL_VALUE
	case "set_target":
		if arg_count != 1 {
			vm.runtime_error(v, "set_target() expects 1 argument (vec3).")
			return false
		}
		val := vm.peek(v, 0)
		if !core.is_vec3(val) {
			vm.runtime_error(v, "set_target() argument must be a vec3.")
			return false
		}
		vv := core.as_vec3(val)
		c.camera.target = rl.Vector3{f32(vv.x), f32(vv.y), f32(vv.z)}
		result = core.NIL_VALUE
	case "set_fovy":
		if arg_count != 1 {
			vm.runtime_error(v, "set_fovy() expects 1 argument (number).")
			return false
		}
		val := vm.peek(v, 0)
		if !core.is_number(val) {
			vm.runtime_error(v, "set_fovy() argument must be a number.")
			return false
		}
		c.camera.fovy = f32(core.as_float(val))
		result = core.NIL_VALUE
	case "update":
		if arg_count != 0 {
			vm.runtime_error(v, "update() takes no arguments.")
			return false
		}
		rl.UpdateCamera(&c.camera, .FREE)
		result = core.NIL_VALUE
	case "get_position":
		if arg_count != 0 {
			vm.runtime_error(v, "get_position() takes no arguments.")
			return false
		}
		p := c.camera.position
		result = core.make_vec3_value(f64(p.x), f64(p.y), f64(p.z))
	case:
		vm.runtime_error(v, "Undefined Camera method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
