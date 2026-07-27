package vm

import "../core"
import rl "vendor:raylib"

// gfx_texture: method dispatch for Image_Object/Texture_Object/
// Render_Texture_Object -- construction lives in natives/gfx.odin
// (thin argument-marshalling wrappers, same split as gfx_window.odin),
// the real per-type logic (frame-rect/animate bookkeeping) lives
// alongside each struct in core/obj_image.odin/obj_texture.odin/
// obj_render_texture.odin, since none of it needs VM state.

invoke_builtin_image :: proc(vm: ^VM, img: ^core.Image_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "width":
		if arg_count != 0 {
			runtime_error(vm, "width() takes no arguments.")
			return false
		}
		result = core.make_int_value(img.width, true)
	case "height":
		if arg_count != 0 {
			runtime_error(vm, "height() takes no arguments.")
			return false
		}
		result = core.make_int_value(img.height, true)
	case:
		runtime_error(vm, "Undefined Image method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}

invoke_builtin_texture :: proc(vm: ^VM, t: ^core.Texture_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "width":
		if arg_count != 0 {
			runtime_error(vm, "width() takes no arguments.")
			return false
		}
		result = core.make_int_value(t.width, true)
	case "height":
		if arg_count != 0 {
			runtime_error(vm, "height() takes no arguments.")
			return false
		}
		result = core.make_int_value(t.height, true)
	case "frame_width":
		if arg_count != 0 {
			runtime_error(vm, "frame_width() takes no arguments.")
			return false
		}
		result = core.make_int_value(t.frame_width, true)
	case "animate":
		if arg_count != 1 {
			runtime_error(vm, "animate() expects 1 argument (ticks_per_frame).")
			return false
		}
		ticks_val := peek(vm, 0)
		if !core.is_number(ticks_val) {
			runtime_error(vm, "animate() argument must be a number.")
			return false
		}
		t.ticks_per_frame = core.as_int(ticks_val)
		result = core.NIL_VALUE
	case "set_wrap_mode":
		if arg_count != 1 {
			runtime_error(vm, "set_wrap_mode() expects 1 argument (wrap_mode).")
			return false
		}
		wrap_val := peek(vm, 0)
		if !core.is_number(wrap_val) {
			runtime_error(vm, "set_wrap_mode() argument must be a number.")
			return false
		}
		rl.SetTextureWrap(t.texture, rl.TextureWrap(core.as_int(wrap_val)))
		result = core.NIL_VALUE
	case "unload":
		if arg_count != 0 {
			runtime_error(vm, "unload() takes no arguments.")
			return false
		}
		core.texture_unload(t)
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined Texture method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}

// invoke_builtin_render_texture covers only width/height/unload -- this
// pass doesn't need get_texture() (a GPU-sync roundtrip glox's own
// RenderTexture.get_texture() does via LoadImageFromTexture/UnloadImage
// specifically to dodge a driver race, per that method's own doc
// comment) or the render-texture-specific mirror of window's own 2D
// drawing methods (draw_array_fast and friends); defender only needs
// win.begin_texture_mode/end_texture_mode/draw_render_texture, all
// implemented in gfx_window.odin, which redirect the *existing* window
// drawing methods at this render target via raylib's own global GL
// state -- nothing extra needed here for that to work.
invoke_builtin_render_texture :: proc(vm: ^VM, rt: ^core.Render_Texture_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "width":
		if arg_count != 0 {
			runtime_error(vm, "width() takes no arguments.")
			return false
		}
		result = core.make_int_value(rt.width, true)
	case "height":
		if arg_count != 0 {
			runtime_error(vm, "height() takes no arguments.")
			return false
		}
		result = core.make_int_value(rt.height, true)
	case "unload":
		if arg_count != 0 {
			runtime_error(vm, "unload() takes no arguments.")
			return false
		}
		core.render_texture_unload(rt)
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined RenderTexture method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
