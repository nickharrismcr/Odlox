package natives

import "../core"
import "../vm"
import "core:strings"
import rl "vendor:raylib"

// gfx: glox's own gfx module (src/vm/builtin.go's makeBuiltInModule(vm,
// "gfx")) is a large raylib-dependent surface -- window/image/texture/
// render_texture/shader/camera/batch. Window lifecycle, core 2D drawing,
// texture/image/render_texture, and shader are implemented (see
// vm/gfx_window.odin, vm/gfx_texture.odin, vm/gfx_shader.odin for the
// real logic); camera/batch/batch_instanced, 3D drawing, and draw_array
// are still not (ROADMAP.md/TODO.md track them as explicit follow-on
// work). Calling any of those still fails with "<name> is not a member
// of module 'gfx'", same as any other not-yet-registered name.
//
// gfx.window(width, height) only constructs the Window_Object -- it
// does *not* call raylib's InitWindow itself. Matches glox's own API
// shape exactly: WindowBuiltIn (obj_builtin_window.go) just builds the
// struct; rl.InitWindow only happens inside the separate win.init()
// method (win_methods.go), so a script must call .init() before
// drawing. Ported as a real API-shape decision, not an oversight.

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
	vm.define_builtin(v, "gfx", "lox_julia_array", gfx_lox_julia_array)
}

// window_created mirrors glox's own package-level `windowCreated` bool
// (obj_builtin_window.go) exactly: gfx.texture() requires a window to
// already exist (a GPU texture upload needs a live GL context), checked
// here rather than in vm/gfx_texture.odin since it's a natives-package-
// level constructor concern, not something the object itself needs to
// know. Single-VM-per-process, matching the existing package-level-state
// precedent in debug/trace.odin's instruction_count_val.
@(private = "file")
window_created: bool

@(private = "file")
gfx_window :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "window() expects 2 arguments (width, height).")
		return core.NIL_VALUE
	}
	w_val, h_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1]
	if !core.is_int(w_val) || !core.is_int(h_val) {
		vm.runtime_error(v, "window() arguments must be integers.")
		return core.NIL_VALUE
	}
	win := core.make_window_object(core.as_int(w_val), core.as_int(h_val))
	vm.gc_track(v, &win.obj)
	window_created = true
	return core.make_object_value(&win.obj, true)
}

// gfx_image loads an rl.Image from a file into CPU memory. Unlike glox's
// MakeImageObject, which panics on load failure, a failed load is a
// proper Lox runtime_error here -- matching this port's established
// pattern of turning native crash-on-error into a real, catchable Lox
// exception rather than taking the whole process down.
@(private = "file")
gfx_image :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "image() expects 1 argument (filename).")
		return core.NIL_VALUE
	}
	filename_val := v.stack[arg_stack_ptr]
	if !core.is_string(filename_val) {
		vm.runtime_error(v, "image() argument must be a string.")
		return core.NIL_VALUE
	}
	cfilename := strings.clone_to_cstring(core.string_get(core.as_string(filename_val)))
	defer delete(cfilename)
	img := rl.LoadImage(cfilename)
	if img.data == nil {
		vm.runtime_error(v, "Failed to load image from '%s'.", core.string_get(core.as_string(filename_val)))
		return core.NIL_VALUE
	}
	o := core.make_image_object(int(img.width), int(img.height), img)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

// gfx_texture uploads an already-loaded Image to the GPU, optionally
// sliced into `frames` equal-width horizontal animation frames. Requires
// a window to already exist (see window_created's doc comment).
@(private = "file")
gfx_texture :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if !window_created {
		vm.runtime_error(v, "Cannot create texture: no window has been created.")
		return core.NIL_VALUE
	}
	if argc != 4 {
		vm.runtime_error(v, "texture() expects 4 arguments (image, frames, start_frame, end_frame).")
		return core.NIL_VALUE
	}
	img_val := v.stack[arg_stack_ptr]
	frames_val := v.stack[arg_stack_ptr + 1]
	start_frame_val := v.stack[arg_stack_ptr + 2]
	end_frame_val := v.stack[arg_stack_ptr + 3]
	if img_val.type != .Obj || img_val.obj_type != .Image {
		vm.runtime_error(v, "texture() first argument must be an image.")
		return core.NIL_VALUE
	}
	if !core.is_int(frames_val) {
		vm.runtime_error(v, "texture() frames argument must be an integer.")
		return core.NIL_VALUE
	}
	frames := core.as_int(frames_val)
	if frames < 1 {
		vm.runtime_error(v, "texture() frames must be at least 1.")
		return core.NIL_VALUE
	}
	if !core.is_int(start_frame_val) {
		vm.runtime_error(v, "texture() start_frame argument must be an integer.")
		return core.NIL_VALUE
	}
	start_frame := core.as_int(start_frame_val)
	if start_frame < 1 || start_frame > frames {
		vm.runtime_error(v, "texture() start_frame must be between 1 and frames.")
		return core.NIL_VALUE
	}
	if !core.is_int(end_frame_val) {
		vm.runtime_error(v, "texture() end_frame argument must be an integer.")
		return core.NIL_VALUE
	}
	end_frame := core.as_int(end_frame_val)
	if end_frame < 1 || end_frame > frames {
		vm.runtime_error(v, "texture() end_frame must be between 1 and frames.")
		return core.NIL_VALUE
	}
	img := core.as_image(img_val)
	o := core.make_texture_object(img.image, frames, start_frame, end_frame)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
gfx_render_texture :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "render_texture() expects 2 arguments (width, height).")
		return core.NIL_VALUE
	}
	w_val, h_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1]
	if !core.is_int(w_val) || !core.is_int(h_val) {
		vm.runtime_error(v, "render_texture() arguments must be integers.")
		return core.NIL_VALUE
	}
	o := core.make_render_texture_object(core.as_int(w_val), core.as_int(h_val))
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

// gfx_shader mirrors glox's own ShaderBuiltIn exactly: 0 arguments
// constructs an empty, not-yet-loaded shader (rl.Shader{}) for a script
// to fill in via .load_from_memory(vertex_code, fragment_code); 2
// arguments (vertex_file, fragment_file) loads compiled GLSL from disk
// immediately via rl.LoadShader.
@(private = "file")
gfx_shader :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	switch argc {
	case 0:
		o := core.make_shader_object(rl.Shader{})
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
		o := core.make_shader_object(rl.LoadShader(cvs, cfs))
		vm.gc_track(v, &o.obj)
		return core.make_object_value(&o.obj, true)
	case:
		vm.runtime_error(v, "shader() expects 0 or 2 arguments.")
		return core.NIL_VALUE
	}
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

// gfx_encode_rgba mirrors glox's EncodeRGBABuiltIn/util.EncodeRGB
// exactly: packs three 0-255 int components into one float64-valued
// 24-bit integer (r<<16 | g<<8 | b), matching glox's own choice to store
// it as a Value float rather than an int (its own comment gives no
// reason; ported as-is for exact behavioral parity, including glox's own
// panic-worthy range check turned into an ordinary Lox runtime error
// instead of a native crash).
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
	result := core.make_list_object(items, true) // is_tuple, matching glox's own MakeListObject(..., true)
	vm.gc_track(v, &result.obj)
	return core.make_object_value(&result.obj, true) // tuples are immutable Values, same as create_list's own convention
}
