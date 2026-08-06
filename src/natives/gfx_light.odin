package natives

import "../core"
import "../vm"
import "core:mem"
import rl "vendor:raylib"

// gfx_light: Light_Data -- one slot in the shared instanced-drawing
// shader's `uniform Light lights[MAX_LIGHTS]` array
// (src/shaders/instanced/lighting.fs). Lights are bound to the
// process-wide instanced_shader singleton (gfx_batch_instanced.odin's
// instanced_shader_get()), not to an individual Batch_Instanced_Data --
// adding a light affects every instanced batch drawn with that shader,
// the same way the shader itself is already shared. Uniform naming,
// types, and the 0-255 -> 0-1 color normalization follow raylib's own
// rlights.h/rlights.odin convention (the upstream shaders_mesh_instancing
// example's approach), which lighting.fs already implements.

MAX_INSTANCED_LIGHTS :: 4
LIGHT_DIRECTIONAL :: 0
LIGHT_POINT :: 1

@(private = "file")
instanced_light_count: int

Light_Data :: struct {
	index:        int,
	enabled_loc:  i32,
	type_loc:     i32,
	position_loc: i32,
	target_loc:   i32,
	color_loc:    i32,
}

@(private = "file")
light_vtable := core.Userdata_Vtable {
	tag       = "Light",
	free      = light_data_free,
	to_string = light_to_string,
	size      = light_data_size,
	invoke    = light_invoke,
}

@(private = "file")
light_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	return "<Light>"
}

@(private = "file")
light_data_size :: proc(data: rawptr) -> int {
	return size_of(Light_Data)
}

@(private = "file")
light_data_free :: proc(data: rawptr) {
	free(data)
}

@(private = "file")
light_set_enabled :: proc(shader: rl.Shader, l: ^Light_Data, enabled: bool) {
	value := i32(1) if enabled else i32(0)
	rl.SetShaderValue(shader, l.enabled_loc, &value, .INT)
}

@(private = "file")
light_set_type :: proc(shader: rl.Shader, l: ^Light_Data, type: int) {
	value := i32(type)
	rl.SetShaderValue(shader, l.type_loc, &value, .INT)
}

@(private = "file")
light_set_position :: proc(shader: rl.Shader, l: ^Light_Data, pos: core.Vec3) {
	value := [3]f32{f32(pos.x), f32(pos.y), f32(pos.z)}
	rl.SetShaderValue(shader, l.position_loc, &value, .VEC3)
}

@(private = "file")
light_set_target :: proc(shader: rl.Shader, l: ^Light_Data, target: core.Vec3) {
	value := [3]f32{f32(target.x), f32(target.y), f32(target.z)}
	rl.SetShaderValue(shader, l.target_loc, &value, .VEC3)
}

// light_set_color normalizes 0-255 vec4 components to 0-1 before upload,
// matching rlights.odin's UpdateLightValues.
@(private = "file")
light_set_color :: proc(shader: rl.Shader, l: ^Light_Data, color: core.Vec4) {
	value := [4]f32{f32(color.x) / 255, f32(color.y) / 255, f32(color.z) / 255, f32(color.w) / 255}
	rl.SetShaderValue(shader, l.color_loc, &value, .VEC4)
}

// gfx_instanced_ambient: (color) -- overrides the shared instanced
// shader's ambient base-fill uniform (see instanced_shader_get()'s own
// doc comment for the ambient/10.0 division lighting.fs applies). Same
// 0-255 vec4 color convention as instanced_light()'s color argument and
// arg_color elsewhere in this package, so scripts don't need to know the
// shader normalizes/divides internally.
@(private)
gfx_instanced_ambient :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "instanced_ambient() expects 1 argument (color).")
		return core.NIL_VALUE
	}
	color_val := v.stack[arg_stack_ptr]
	if !core.is_vec4(color_val) {
		vm.runtime_error(v, "instanced_ambient() argument must be a vec4 (color, 0-255 components).")
		return core.NIL_VALUE
	}
	shader := instanced_shader_get()
	ambient_loc := rl.GetShaderLocation(shader, "ambient")
	color := core.as_vec4(color_val)
	value := [4]f32{f32(color.x) / 255, f32(color.y) / 255, f32(color.z) / 255, f32(color.w) / 255}
	rl.SetShaderValue(shader, ambient_loc, &value, .VEC4)
	return core.NIL_VALUE
}

// gfx_instanced_light: (type, position, target, color) -- allocates the
// next free slot (0..MAX_INSTANCED_LIGHTS-1) in the shared instanced
// shader's lights[] array. Errors via a runtime error once all
// MAX_INSTANCED_LIGHTS slots are taken, rather than silently reusing or
// overwriting an earlier light -- the same fixed-capacity convention
// batch_instanced_add uses for its transforms array.
@(private)
gfx_instanced_light :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 4 {
		vm.runtime_error(v, "instanced_light() expects 4 arguments (type, position, target, color).")
		return core.NIL_VALUE
	}
	type_val, pos_val, target_val, color_val :=
		v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2], v.stack[arg_stack_ptr + 3]
	if !core.is_int(type_val) {
		vm.runtime_error(v, "instanced_light() first argument must be an int (type: 0=directional, 1=point).")
		return core.NIL_VALUE
	}
	if !core.is_vec3(pos_val) {
		vm.runtime_error(v, "instanced_light() second argument must be a vec3 (position).")
		return core.NIL_VALUE
	}
	if !core.is_vec3(target_val) {
		vm.runtime_error(v, "instanced_light() third argument must be a vec3 (target).")
		return core.NIL_VALUE
	}
	if !core.is_vec4(color_val) {
		vm.runtime_error(v, "instanced_light() fourth argument must be a vec4 (color, 0-255 components).")
		return core.NIL_VALUE
	}
	if instanced_light_count >= MAX_INSTANCED_LIGHTS {
		vm.runtime_error(v, "instanced_light(): max %d lights already added.", MAX_INSTANCED_LIGHTS)
		return core.NIL_VALUE
	}

	shader := instanced_shader_get()
	idx := instanced_light_count
	instanced_light_count += 1

	data := new(Light_Data)
	data.index = idx
	data.enabled_loc = rl.GetShaderLocation(shader, rl.TextFormat("lights[%i].enabled", i32(idx)))
	data.type_loc = rl.GetShaderLocation(shader, rl.TextFormat("lights[%i].type", i32(idx)))
	data.position_loc = rl.GetShaderLocation(shader, rl.TextFormat("lights[%i].position", i32(idx)))
	data.target_loc = rl.GetShaderLocation(shader, rl.TextFormat("lights[%i].target", i32(idx)))
	data.color_loc = rl.GetShaderLocation(shader, rl.TextFormat("lights[%i].color", i32(idx)))

	light_set_enabled(shader, data, true)
	light_set_type(shader, data, core.as_int(type_val))
	light_set_position(shader, data, core.as_vec3(pos_val))
	light_set_target(shader, data, core.as_vec3(target_val))
	light_set_color(shader, data, core.as_vec4(color_val))

	o := core.make_userdata_object(&light_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
light_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	l := cast(^Light_Data)data
	shader := instanced_shader_get()
	result: core.Value
	switch name {
	case "set_position":
		if arg_count != 1 {
			vm.runtime_error(v, "set_position() expects 1 argument (vec3).")
			return false
		}
		pos_val := vm.peek(v, 0)
		if !core.is_vec3(pos_val) {
			vm.runtime_error(v, "set_position() argument must be a vec3.")
			return false
		}
		light_set_position(shader, l, core.as_vec3(pos_val))
		result = core.NIL_VALUE
	case "set_target":
		if arg_count != 1 {
			vm.runtime_error(v, "set_target() expects 1 argument (vec3).")
			return false
		}
		target_val := vm.peek(v, 0)
		if !core.is_vec3(target_val) {
			vm.runtime_error(v, "set_target() argument must be a vec3.")
			return false
		}
		light_set_target(shader, l, core.as_vec3(target_val))
		result = core.NIL_VALUE
	case "set_color":
		if arg_count != 1 {
			vm.runtime_error(v, "set_color() expects 1 argument (vec4).")
			return false
		}
		color_val := vm.peek(v, 0)
		if !core.is_vec4(color_val) {
			vm.runtime_error(v, "set_color() argument must be a vec4.")
			return false
		}
		light_set_color(shader, l, core.as_vec4(color_val))
		result = core.NIL_VALUE
	case "enable":
		if arg_count != 0 {
			vm.runtime_error(v, "enable() takes no arguments.")
			return false
		}
		light_set_enabled(shader, l, true)
		result = core.NIL_VALUE
	case "disable":
		if arg_count != 0 {
			vm.runtime_error(v, "disable() takes no arguments.")
			return false
		}
		light_set_enabled(shader, l, false)
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Unknown Light method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
