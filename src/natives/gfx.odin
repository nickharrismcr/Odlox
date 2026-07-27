package natives

import "../core"
import "../vm"
import rl "vendor:raylib"

// gfx: glox's own gfx module (src/vm/builtin.go's makeBuiltInModule(vm,
// "gfx")) is a large raylib-dependent surface -- window/image/texture/
// render_texture/shader/camera/batch. This pass covers window lifecycle
// and core 2D drawing (see vm/gfx_window.odin for the real logic);
// texture/image/shader/camera/render_texture/batch/batch_instanced, 3D
// drawing, blend/shader modes, and draw_array are still not implemented
// (ROADMAP.md/TODO.md track them as explicit follow-on work). Calling
// any of those still fails with "<name> is not a member of module
// 'gfx'", same as any other not-yet-registered name.
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
	register_gfx_key_constants(v)
}

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
	return core.make_object_value(&win.obj, true)
}

// register_gfx_key_constants exposes the subset of rl.KeyboardKey a
// real script is actually likely to need (gfx.KEY_A .. gfx.KEY_Z,
// gfx.KEY_ZERO .. gfx.KEY_NINE, plus the common named keys) as plain
// module-level constants -- not glox's full ~100-constant enum (glox
// registers them all on the window object itself as gfx.KEY_*; expand
// this list on demand rather than blind-porting all of it up front).
@(private = "file")
register_gfx_key_constants :: proc(v: ^vm.VM) {
	define_key :: proc(v: ^vm.VM, name: string, key: rl.KeyboardKey) {
		vm.define_builtin_const(v, "gfx", name, core.make_int_value(int(key), true))
	}

	define_key(v, "KEY_SPACE", .SPACE)
	define_key(v, "KEY_ESCAPE", .ESCAPE)
	define_key(v, "KEY_ENTER", .ENTER)
	define_key(v, "KEY_UP", .UP)
	define_key(v, "KEY_DOWN", .DOWN)
	define_key(v, "KEY_LEFT", .LEFT)
	define_key(v, "KEY_RIGHT", .RIGHT)

	define_key(v, "KEY_A", .A)
	define_key(v, "KEY_B", .B)
	define_key(v, "KEY_C", .C)
	define_key(v, "KEY_D", .D)
	define_key(v, "KEY_E", .E)
	define_key(v, "KEY_F", .F)
	define_key(v, "KEY_G", .G)
	define_key(v, "KEY_H", .H)
	define_key(v, "KEY_I", .I)
	define_key(v, "KEY_J", .J)
	define_key(v, "KEY_K", .K)
	define_key(v, "KEY_L", .L)
	define_key(v, "KEY_M", .M)
	define_key(v, "KEY_N", .N)
	define_key(v, "KEY_O", .O)
	define_key(v, "KEY_P", .P)
	define_key(v, "KEY_Q", .Q)
	define_key(v, "KEY_R", .R)
	define_key(v, "KEY_S", .S)
	define_key(v, "KEY_T", .T)
	define_key(v, "KEY_U", .U)
	define_key(v, "KEY_V", .V)
	define_key(v, "KEY_W", .W)
	define_key(v, "KEY_X", .X)
	define_key(v, "KEY_Y", .Y)
	define_key(v, "KEY_Z", .Z)

	define_key(v, "KEY_0", .ZERO)
	define_key(v, "KEY_1", .ONE)
	define_key(v, "KEY_2", .TWO)
	define_key(v, "KEY_3", .THREE)
	define_key(v, "KEY_4", .FOUR)
	define_key(v, "KEY_5", .FIVE)
	define_key(v, "KEY_6", .SIX)
	define_key(v, "KEY_7", .SEVEN)
	define_key(v, "KEY_8", .EIGHT)
	define_key(v, "KEY_9", .NINE)
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
