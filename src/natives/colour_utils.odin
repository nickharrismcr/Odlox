package natives

import "../core"
import "../vm"
import "core:math"
import "core:math/rand"

// colour_utils: pure colour-math helper functions with no raylib
// dependency. Every function here returns a vec4 (r, g, b, 255). Lives
// in natives rather than vm/builtins*.odin so the whole `colour_utils`
// module (registration + every function under it) stays in one place,
// the same way gfx.odin keeps its own raylib-free encode_rgba/
// decode_rgba alongside gfx's raylib-dependent surface.

@(private)
register_colour_utils :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "colour_utils")
	vm.define_builtin(v, "colour_utils", "fade", colour_utils_fade)
	vm.define_builtin(v, "colour_utils", "tint", colour_utils_tint)
	vm.define_builtin(v, "colour_utils", "brightness", colour_utils_brightness)
	vm.define_builtin(v, "colour_utils", "lerp", colour_utils_lerp)
	vm.define_builtin(v, "colour_utils", "hsv_to_rgb", colour_utils_hsv_to_rgb)
	vm.define_builtin(v, "colour_utils", "random", colour_utils_random)
}

@(private = "file")
clamp01 :: proc(x: f64) -> f64 {
	return math.min(1, math.max(0, x))
}

@(private = "file")
clamp255 :: proc(x: f64) -> f64 {
	return math.min(255, math.max(0, x))
}

@(private = "file")
colour_utils_fade :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 4 {
		vm.runtime_error(v, "fade expects 4 arguments (r, g, b, alpha)")
		return core.NIL_VALUE
	}
	r_val, g_val, b_val, alpha_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2], v.stack[arg_stack_ptr + 3]
	if !core.is_number(r_val) || !core.is_number(g_val) || !core.is_number(b_val) || !core.is_number(alpha_val) {
		vm.runtime_error(v, "fade arguments must be numbers")
		return core.NIL_VALUE
	}
	r := clamp255(core.as_float(r_val))
	g := clamp255(core.as_float(g_val))
	b := clamp255(core.as_float(b_val))
	alpha := clamp01(core.as_float(alpha_val))
	return core.make_vec4_value(f64(int(r * alpha)), f64(int(g * alpha)), f64(int(b * alpha)), 255.0)
}

@(private = "file")
colour_utils_tint :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 6 {
		vm.runtime_error(v, "tint expects 6 arguments (r1, g1, b1, r2, g2, b2)")
		return core.NIL_VALUE
	}
	vals: [6]core.Value
	for i in 0 ..< 6 {
		vals[i] = v.stack[arg_stack_ptr + i]
		if !core.is_number(vals[i]) {
			vm.runtime_error(v, "tint arguments must be numbers")
			return core.NIL_VALUE
		}
	}
	r1 := clamp255(core.as_float(vals[0]))
	g1 := clamp255(core.as_float(vals[1]))
	b1 := clamp255(core.as_float(vals[2]))
	r2 := clamp255(core.as_float(vals[3]))
	g2 := clamp255(core.as_float(vals[4]))
	b2 := clamp255(core.as_float(vals[5]))
	new_r := f64(int((r1 * r2) / 255.0))
	new_g := f64(int((g1 * g2) / 255.0))
	new_b := f64(int((b1 * b2) / 255.0))
	return core.make_vec4_value(new_r, new_g, new_b, 255.0)
}

@(private = "file")
colour_utils_brightness :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 4 {
		vm.runtime_error(v, "brightness expects 4 arguments (r, g, b, factor)")
		return core.NIL_VALUE
	}
	r_val, g_val, b_val, factor_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2], v.stack[arg_stack_ptr + 3]
	if !core.is_number(r_val) || !core.is_number(g_val) || !core.is_number(b_val) || !core.is_number(factor_val) {
		vm.runtime_error(v, "brightness arguments must be numbers")
		return core.NIL_VALUE
	}
	r := clamp255(core.as_float(r_val))
	g := clamp255(core.as_float(g_val))
	b := clamp255(core.as_float(b_val))
	factor := core.as_float(factor_val)
	new_r := f64(int(clamp255(r * factor)))
	new_g := f64(int(clamp255(g * factor)))
	new_b := f64(int(clamp255(b * factor)))
	return core.make_vec4_value(new_r, new_g, new_b, 255.0)
}

@(private = "file")
colour_utils_lerp :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 7 {
		vm.runtime_error(v, "lerp expects 7 arguments (r1, g1, b1, r2, g2, b2, amount)")
		return core.NIL_VALUE
	}
	vals: [7]core.Value
	for i in 0 ..< 7 {
		vals[i] = v.stack[arg_stack_ptr + i]
		if !core.is_number(vals[i]) {
			vm.runtime_error(v, "lerp arguments must be numbers")
			return core.NIL_VALUE
		}
	}
	r1 := clamp255(core.as_float(vals[0]))
	g1 := clamp255(core.as_float(vals[1]))
	b1 := clamp255(core.as_float(vals[2]))
	r2 := clamp255(core.as_float(vals[3]))
	g2 := clamp255(core.as_float(vals[4]))
	b2 := clamp255(core.as_float(vals[5]))
	amount := clamp01(core.as_float(vals[6]))
	new_r := f64(int(r1 + (r2 - r1) * amount))
	new_g := f64(int(g1 + (g2 - g1) * amount))
	new_b := f64(int(b1 + (b2 - b1) * amount))
	return core.make_vec4_value(new_r, new_g, new_b, 255.0)
}

@(private = "file")
colour_utils_hsv_to_rgb :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 3 {
		vm.runtime_error(v, "hsv_to_rgb expects 3 arguments (h, s, v)")
		return core.NIL_VALUE
	}
	h_val, s_val, val_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2]
	if !core.is_number(h_val) || !core.is_number(s_val) || !core.is_number(val_val) {
		vm.runtime_error(v, "hsv_to_rgb arguments must be numbers")
		return core.NIL_VALUE
	}
	h := math.mod(core.as_float(h_val), 360.0)
	s := clamp01(core.as_float(s_val))
	val := clamp01(core.as_float(val_val))

	c := val * s
	x := c * (1 - math.abs(math.mod(h / 60.0, 2) - 1))
	m := val - c

	r, g, b: f64
	switch {
	case h >= 0 && h < 60:
		r, g, b = c, x, 0
	case h >= 60 && h < 120:
		r, g, b = x, c, 0
	case h >= 120 && h < 180:
		r, g, b = 0, c, x
	case h >= 180 && h < 240:
		r, g, b = 0, x, c
	case h >= 240 && h < 300:
		r, g, b = x, 0, c
	case:
		r, g, b = c, 0, x
	}

	return core.make_vec4_value(f64(int((r + m) * 255)), f64(int((g + m) * 255)), f64(int((b + m) * 255)), 255.0)
}

@(private = "file")
colour_utils_random :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 0 {
		vm.runtime_error(v, "random expects 0 arguments")
		return core.NIL_VALUE
	}
	return core.make_vec4_value(f64(rand.int_max(256)), f64(rand.int_max(256)), f64(rand.int_max(256)), 255.0)
}
