package natives

import "../core"
import "../vm"

// gfx: glox's own gfx module (src/vm/builtin.go's makeBuiltInModule(vm,
// "gfx")) is a large raylib-dependent surface -- window/image/texture/
// render_texture/shader/camera/batch, none of which this port implements
// yet (raylib window/2D-drawing natives are ROADMAP.md's Phase 6b, a
// separate, much larger effort: real windowing, an actual vendor:raylib
// dependency, and a native object per raylib resource type). What's
// registered here is deliberately just the functions under `gfx` that
// don't actually need a window: encode_rgba/decode_rgba (pure bit-
// packing math, ported from glox's src/builtin/os_functions.go) and
// float_array (a plain w*h f64 buffer with no raylib dependency of its
// own -- see core/obj_float_array.odin and call.odin's
// invoke_builtin_float_array for the object itself and its get/set/
// clear/width/height methods; only *drawing* a float_array's contents
// to a window needs raylib, and this port doesn't have a window yet
// either). Calling any of the *other* gfx functions (window, texture,
// ...) still fails with "Module 'gfx' not found" turning into "<name>
// is not a member of module 'gfx'" style errors, same as any other
// not-yet-registered name, until Phase 6b adds them for real.

@(private)
register_gfx :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "gfx")
	vm.define_builtin(v, "gfx", "encode_rgba", gfx_encode_rgba)
	vm.define_builtin(v, "gfx", "decode_rgba", gfx_decode_rgba)
	vm.define_builtin(v, "gfx", "float_array", gfx_float_array)
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
