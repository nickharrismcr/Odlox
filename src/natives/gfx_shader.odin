package natives

import "../core"
import "../vm"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"

// gfx_shader: Shader_Data (a raylib GLSL shader program), construction,
// and method dispatch. Two construction paths: gfx.shader(vertex_file,
// fragment_file) loads compiled GLSL from disk immediately; gfx.shader()
// (no arguments) constructs an empty, not-yet-loaded shader (rl.Shader{})
// for a script to fill in afterward via
// .load_from_memory(vertex_code, fragment_code), for GLSL source
// embedded as Lox string literals rather than read from a file.

Shader_Data :: struct {
	shader: rl.Shader,
	freed:  bool, // idempotent-unload guard, same convention as Texture_Data/Render_Texture_Data
}

@(private = "file")
shader_vtable := core.Userdata_Vtable {
	tag       = "Shader",
	free      = shader_data_free,
	to_string = shader_to_string,
	size      = shader_data_size,
	invoke    = shader_invoke,
}

@(private = "file")
shader_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	s := cast(^Shader_Data)data
	return fmt.aprintf("<Shader ID:%d>", s.shader.id, allocator = allocator)
}

@(private = "file")
shader_data_size :: proc(data: rawptr) -> int {
	return size_of(Shader_Data)
}

@(private = "file")
shader_unload :: proc(s: ^Shader_Data) {
	if s.freed {
		return
	}
	s.freed = true
	rl.UnloadShader(s.shader)
}

@(private = "file")
shader_data_free :: proc(data: rawptr) {
	s := cast(^Shader_Data)data
	shader_unload(s)
	free(s)
}

// is_shader_value: package-private since gfx_window.odin's
// begin_shader_mode needs it too.
@(private)
is_shader_value :: proc(v: core.Value) -> bool {
	return v.type == .Obj && v.obj_type == .Userdata && core.as_userdata(v).vtable == &shader_vtable
}

@(private)
shader_data_of :: proc(v: core.Value) -> ^Shader_Data {
	return cast(^Shader_Data)core.as_userdata(v).data
}

// gfx_shader: 0 arguments constructs an empty, not-yet-loaded shader
// (rl.Shader{}) for a script to fill in via
// .load_from_memory(vertex_code, fragment_code); 2 arguments
// (vertex_file, fragment_file) loads compiled GLSL from disk
// immediately via rl.LoadShader.
@(private)
gfx_shader :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	switch argc {
	case 0:
		data := new(Shader_Data)
		data.shader = rl.Shader{}
		o := core.make_userdata_object(&shader_vtable, data)
		vm.gc_track(v, &o.obj)
		return core.make_object_value(&o.obj, true)
	case 2:
		vs_val, fs_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1]
		if !core.is_string(vs_val) || !core.is_string(fs_val) {
			vm.runtime_error(v, "shader() expects string arguments for vertex and fragment shader files.")
			return core.NIL_VALUE
		}
		cvs := strings.clone_to_cstring(core.string_get(core.as_string(vs_val)))
		defer delete(cvs)
		cfs := strings.clone_to_cstring(core.string_get(core.as_string(fs_val)))
		defer delete(cfs)
		data := new(Shader_Data)
		data.shader = rl.LoadShader(cvs, cfs)
		o := core.make_userdata_object(&shader_vtable, data)
		vm.gc_track(v, &o.obj)
		return core.make_object_value(&o.obj, true)
	case:
		vm.runtime_error(v, "shader() expects 0 or 2 arguments.")
		return core.NIL_VALUE
	}
}

@(private = "file")
shader_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	s := cast(^Shader_Data)data
	result: core.Value
	switch name {
	case "load_from_memory":
		if arg_count != 2 {
			vm.runtime_error(v, "load_from_memory() expects 2 arguments (vertex_code, fragment_code).")
			return false
		}
		vs_val, fs_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_string(vs_val) || !core.is_string(fs_val) {
			vm.runtime_error(v, "load_from_memory() arguments must be strings.")
			return false
		}
		cvs := strings.clone_to_cstring(core.string_get(core.as_string(vs_val)))
		defer delete(cvs)
		cfs := strings.clone_to_cstring(core.string_get(core.as_string(fs_val)))
		defer delete(cfs)
		s.shader = rl.LoadShaderFromMemory(cvs, cfs)
		result = core.NIL_VALUE
	case "get_location":
		if arg_count != 1 {
			vm.runtime_error(v, "get_location() expects 1 argument (uniform_name).")
			return false
		}
		name_val := vm.peek(v, 0)
		if !core.is_string(name_val) {
			vm.runtime_error(v, "get_location() argument must be a string.")
			return false
		}
		cname := strings.clone_to_cstring(core.string_get(core.as_string(name_val)))
		defer delete(cname)
		loc := rl.GetShaderLocation(s.shader, cname)
		result = core.make_int_value(int(loc), true)
	case "set_value_float":
		if arg_count != 2 {
			vm.runtime_error(v, "set_value_float() expects 2 arguments (location, value).")
			return false
		}
		loc_val, val_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(loc_val) || !core.is_number(val_val) {
			vm.runtime_error(v, "set_value_float() expects an int location and a numeric value.")
			return false
		}
		value := f32(core.as_float(val_val))
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &value, .FLOAT)
		result = core.NIL_VALUE
	case "set_value_vec2":
		if arg_count != 2 {
			vm.runtime_error(v, "set_value_vec2() expects 2 arguments (location, vec2).")
			return false
		}
		loc_val, v_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(loc_val) || !core.is_vec2(v_val) {
			vm.runtime_error(v, "set_value_vec2() expects an int location and a vec2 value.")
			return false
		}
		vv := core.as_vec2(v_val)
		values := [2]f32{f32(vv.x), f32(vv.y)}
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &values, .VEC2)
		result = core.NIL_VALUE
	case "set_value_vec3":
		if arg_count != 2 {
			vm.runtime_error(v, "set_value_vec3() expects 2 arguments (location, vec3).")
			return false
		}
		loc_val, v_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(loc_val) || !core.is_vec3(v_val) {
			vm.runtime_error(v, "set_value_vec3() expects an int location and a vec3 value.")
			return false
		}
		vv := core.as_vec3(v_val)
		values := [3]f32{f32(vv.x), f32(vv.y), f32(vv.z)}
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &values, .VEC3)
		result = core.NIL_VALUE
	case "set_value_vec4":
		if arg_count != 2 {
			vm.runtime_error(v, "set_value_vec4() expects 2 arguments (location, vec4).")
			return false
		}
		loc_val, v_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(loc_val) || !core.is_vec4(v_val) {
			vm.runtime_error(v, "set_value_vec4() expects an int location and a vec4 value.")
			return false
		}
		vv := core.as_vec4(v_val)
		values := [4]f32{f32(vv.x), f32(vv.y), f32(vv.z), f32(vv.w)}
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &values, .VEC4)
		result = core.NIL_VALUE
	case "set_value_texture":
		if arg_count != 2 {
			vm.runtime_error(v, "set_value_texture() expects 2 arguments (location, texture).")
			return false
		}
		loc_val, tex_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(loc_val) {
			vm.runtime_error(v, "set_value_texture() expects an int location.")
			return false
		}
		tex: rl.Texture2D
		switch {
		case is_texture_value(tex_val):
			tex = texture_data_of(tex_val).texture
		case is_render_texture_value(tex_val):
			tex = render_texture_data_of(tex_val).render_texture.texture
		case:
			vm.runtime_error(v, "set_value_texture() second argument must be a texture or render_texture.")
			return false
		}
		rl.SetShaderValueTexture(s.shader, c.int(core.as_int(loc_val)), tex)
		result = core.NIL_VALUE
	case "is_valid":
		if arg_count != 0 {
			vm.runtime_error(v, "is_valid() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.IsShaderValid(s.shader)))
	case "unload":
		if arg_count != 0 {
			vm.runtime_error(v, "unload() takes no arguments.")
			return false
		}
		shader_unload(s)
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Undefined Shader method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
