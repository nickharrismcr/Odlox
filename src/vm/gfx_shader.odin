package vm

import "../core"
import "core:c"
import "core:strings"
import rl "vendor:raylib"

// gfx_shader: method dispatch for Shader_Object. Construction (both the
// load-from-files and empty-then-load-from-memory shapes) lives in
// natives/gfx.odin, matching the split every other gfx native type
// uses.
invoke_builtin_shader :: proc(vm: ^VM, s: ^core.Shader_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "load_from_memory":
		if arg_count != 2 {
			runtime_error(vm, "load_from_memory() expects 2 arguments (vertex_code, fragment_code).")
			return false
		}
		vs_val, fs_val := peek(vm, 1), peek(vm, 0)
		if !core.is_string(vs_val) || !core.is_string(fs_val) {
			runtime_error(vm, "load_from_memory() arguments must be strings.")
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
			runtime_error(vm, "get_location() expects 1 argument (uniform_name).")
			return false
		}
		name_val := peek(vm, 0)
		if !core.is_string(name_val) {
			runtime_error(vm, "get_location() argument must be a string.")
			return false
		}
		cname := strings.clone_to_cstring(core.string_get(core.as_string(name_val)))
		defer delete(cname)
		loc := rl.GetShaderLocation(s.shader, cname)
		result = core.make_int_value(int(loc), true)
	case "set_value_float":
		if arg_count != 2 {
			runtime_error(vm, "set_value_float() expects 2 arguments (location, value).")
			return false
		}
		loc_val, val_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(loc_val) || !core.is_number(val_val) {
			runtime_error(vm, "set_value_float() expects an int location and a numeric value.")
			return false
		}
		value := f32(core.as_float(val_val))
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &value, .FLOAT)
		result = core.NIL_VALUE
	case "set_value_vec2":
		if arg_count != 2 {
			runtime_error(vm, "set_value_vec2() expects 2 arguments (location, vec2).")
			return false
		}
		loc_val, v_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(loc_val) || !core.is_vec2(v_val) {
			runtime_error(vm, "set_value_vec2() expects an int location and a vec2 value.")
			return false
		}
		vv := core.as_vec2(v_val)
		values := [2]f32{f32(vv.x), f32(vv.y)}
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &values, .VEC2)
		result = core.NIL_VALUE
	case "set_value_vec3":
		if arg_count != 2 {
			runtime_error(vm, "set_value_vec3() expects 2 arguments (location, vec3).")
			return false
		}
		loc_val, v_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(loc_val) || !core.is_vec3(v_val) {
			runtime_error(vm, "set_value_vec3() expects an int location and a vec3 value.")
			return false
		}
		vv := core.as_vec3(v_val)
		values := [3]f32{f32(vv.x), f32(vv.y), f32(vv.z)}
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &values, .VEC3)
		result = core.NIL_VALUE
	case "set_value_vec4":
		if arg_count != 2 {
			runtime_error(vm, "set_value_vec4() expects 2 arguments (location, vec4).")
			return false
		}
		loc_val, v_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(loc_val) || !core.is_vec4(v_val) {
			runtime_error(vm, "set_value_vec4() expects an int location and a vec4 value.")
			return false
		}
		vv := core.as_vec4(v_val)
		values := [4]f32{f32(vv.x), f32(vv.y), f32(vv.z), f32(vv.w)}
		rl.SetShaderValue(s.shader, c.int(core.as_int(loc_val)), &values, .VEC4)
		result = core.NIL_VALUE
	case "is_valid":
		if arg_count != 0 {
			runtime_error(vm, "is_valid() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.IsShaderValid(s.shader)))
	case "unload":
		if arg_count != 0 {
			runtime_error(vm, "unload() takes no arguments.")
			return false
		}
		core.shader_unload(s)
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined Shader method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
