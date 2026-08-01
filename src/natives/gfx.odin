package natives

import "../core"
import "../vm"
import rl "vendor:raylib"

// gfx: a large raylib-dependent module surface -- window/image/texture/
// render_texture/shader/camera/batch/batch_instanced. Each object kind
// (Userdata_Object -- see core/obj_userdata.odin and this package's own
// README.md) lives in its own sibling file: gfx_window.odin,
// gfx_image.odin, gfx_texture.odin (Texture + Render_Texture),
// gfx_shader.odin, gfx_camera.odin, gfx_batch.odin,
// gfx_batch_instanced.odin. This file holds module registration plus the
// few plain functions (encode_rgba/decode_rgba/float_array) and helpers
// shared across those sibling files.
//
// gfx.window(width, height) only constructs the window object -- it
// does *not* call raylib's InitWindow itself; that only happens inside
// the separate win.init() method, so a script must call .init() before
// drawing. This is a deliberate API shape, not an oversight.

@(private)
register_gfx :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "gfx")
	vm.define_builtin(v, "gfx", "encode_rgba", gfx_encode_rgba)
	vm.define_builtin(v, "gfx", "decode_rgba", gfx_decode_rgba)
	vm.define_builtin(v, "gfx", "float_array", gfx_float_array)
	vm.define_builtin(v, "gfx", "window", gfx_window)
	vm.define_builtin(v, "gfx", "image", gfx_image)
	vm.define_builtin(v, "gfx", "texture", gfx_texture)
	vm.define_builtin(v, "gfx", "render_texture", gfx_render_texture)
	vm.define_builtin(v, "gfx", "shader", gfx_shader)
	vm.define_builtin(v, "gfx", "camera", gfx_camera)
	vm.define_builtin(v, "gfx", "batch", gfx_batch)
	vm.define_builtin(v, "gfx", "batch_instanced", gfx_batch_instanced)
	vm.define_builtin(v, "gfx", "lox_julia_array", gfx_lox_julia_array)
	vm.define_builtin(v, "gfx", "lox_mandel_array", gfx_lox_mandel_array)
}

// window_created tracks whether a window exists: gfx.texture() requires
// one (a GPU texture upload needs a live GL context), checked in
// gfx_texture.odin's gfx_texture rather than in its own file since it's
// a natives-package-level constructor concern, not something the object
// itself needs to know. A package-level flag assumes a single VM per
// process, the same assumption debug/trace.odin's instruction_count_val
// makes.
@(private)
window_created: bool

// vec4_to_rl_color/arg_color: package-private since gfx_window.odin's
// own drawing methods and gfx_texture.odin's Render_Texture-mirrored
// drawing methods both need them.
@(private)
vec4_to_rl_color :: proc(v: ^core.Vec4_Object) -> rl.Color {
	return rl.Color{
		u8(clamp(v.x, 0, 255)),
		u8(clamp(v.y, 0, 255)),
		u8(clamp(v.z, 0, 255)),
		u8(clamp(v.w, 0, 255)),
	}
}

// arg_color validates and extracts the color argument every drawing
// method takes as its last parameter.
@(private)
arg_color :: proc(v: ^vm.VM, val: core.Value, method: string) -> (rl.Color, bool) {
	if !core.is_vec4(val) {
		vm.runtime_error(v, "%s() color argument must be a vec4.", method)
		return {}, false
	}
	return vec4_to_rl_color(core.as_vec4(val)), true
}

@(private = "file")
gfx_float_array :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "Invalid argument count to float_array.")
		return core.NIL_VALUE
	}
	w_val, h_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1]
	if !core.is_int(w_val) || !core.is_int(h_val) {
		vm.runtime_error(v, "float_array arguments must be integers")
		return core.NIL_VALUE
	}
	arr := core.make_float_array_object(core.as_int(w_val), core.as_int(h_val))
	vm.gc_track(v, &arr.obj)
	return core.make_object_value(&arr.obj)
}

// gfx_encode_rgba packs three 0-255 int components into one 24-bit
// integer (r<<16 | g<<8 | b), stored as a float64-valued Value rather
// than an int. Out-of-range components raise a Lox runtime error rather
// than crashing.
@(private = "file")
gfx_encode_rgba :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 3 {
		vm.runtime_error(v, "encode_rgba expects 3 arguments")
		return core.NIL_VALUE
	}
	r_val, g_val, b_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2]
	if !core.is_int(r_val) || !core.is_int(g_val) || !core.is_int(b_val) {
		vm.runtime_error(v, "encode_rgba arguments must be integers")
		return core.NIL_VALUE
	}
	r, g, b := core.as_int(r_val), core.as_int(g_val), core.as_int(b_val)
	if r < 0 || r > 255 || g < 0 || g > 255 || b < 0 || b > 255 {
		vm.runtime_error(v, "encode_rgba values must be between 0 and 255")
		return core.NIL_VALUE
	}
	packed := u32(r) << 16 | u32(g) << 8 | u32(b)
	return core.make_float_value(f64(packed))
}

@(private = "file")
gfx_decode_rgba :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "decode_rgba expects 1 float argument")
		return core.NIL_VALUE
	}
	f_val := v.stack[arg_stack_ptr]
	if !core.is_float(f_val) {
		vm.runtime_error(v, "decode_rgba argument must be a float")
		return core.NIL_VALUE
	}
	packed := u32(core.as_float(f_val))
	r := int((packed >> 16) & 0xFF)
	g := int((packed >> 8) & 0xFF)
	b := int(packed & 0xFF)
	items: [dynamic]core.Value
	append(&items, core.make_int_value(r), core.make_int_value(g), core.make_int_value(b))
	result := core.make_list_object(items, true) // is_tuple: true
	vm.gc_track(v, &result.obj)
	return core.make_object_value(&result.obj, true) // tuples are immutable Values, same as create_list's own convention
}
