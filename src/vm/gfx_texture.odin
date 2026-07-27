package vm

import "../core"
import "core:c"
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

// invoke_builtin_render_texture: width/height/unload, plus a mirror of
// Window's own 2D primitive set (clear/pixel/line/line_ex/triangle/
// rectangle/circle/circle_fill/draw_texture) -- found needed by
// lox_examples/tile_planes.lox ("frame.line_ex(...)"/"this.texture.clear(...)")
// and confirmed against several other example scripts (cobweb-bifurc.lox,
// kaleido.lox, cube_stack_fly2.lox, textured_batch_demo2.lox) that draw
// directly onto a render_texture the same way, not only via
// win.begin_texture_mode/end_texture_mode/win.<primitive> (defender's own
// pattern, still supported separately in gfx_window.odin). Matches glox's
// own render_texture_methods.go exactly: each call brackets *just that one
// draw* in its own BeginTextureMode/EndTextureMode, not a persistent mode
// switch -- unlike Window's methods, which draw against whatever the
// current global GL target already is. Deliberately still not implemented:
// text() (glox's own RenderTexture.text() takes a different, narrower
// argument list -- (x, y, string) only, fixed font size 10, hardcoded
// white -- than Window's text(), and no example script here calls it, so
// there's nothing to verify that mismatch against), get_texture() (GPU-sync
// roundtrip, not needed by anything ported so far), draw_texture_pro(), and
// draw_array_fast() (float_array-to-texture upload, needed by julia.lox/
// mandel_gfx.lox but those are also blocked on unimplemented batch_instanced
// features regardless).
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
	case "clear":
		if arg_count != 1 {
			runtime_error(vm, "clear() expects 1 argument (color).")
			return false
		}
		col, ok := arg_color(vm, peek(vm, 0), "clear")
		if !ok {
			return false
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.ClearBackground(col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "pixel":
		if arg_count != 3 {
			runtime_error(vm, "pixel() expects 3 arguments (x, y, color).")
			return false
		}
		x_val, y_val, col_val := peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) {
			runtime_error(vm, "pixel() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "pixel")
		if !ok {
			return false
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawPixel(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "line":
		if arg_count != 5 {
			runtime_error(vm, "line() expects 5 arguments (x1, y1, x2, y2, color).")
			return false
		}
		x1_val, y1_val, x2_val, y2_val, col_val := peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(x1_val) || !core.is_number(y1_val) || !core.is_number(x2_val) || !core.is_number(y2_val) {
			runtime_error(vm, "line() coordinate arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "line")
		if !ok {
			return false
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawLine(
			c.int(int(core.as_float(x1_val))), c.int(int(core.as_float(y1_val))),
			c.int(int(core.as_float(x2_val))), c.int(int(core.as_float(y2_val))),
			col,
		)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "line_ex":
		if arg_count != 6 {
			runtime_error(vm, "line_ex() expects 6 arguments (x1, y1, x2, y2, thickness, color).")
			return false
		}
		x1_val, y1_val, x2_val, y2_val, thick_val, col_val := peek(vm, 5), peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(x1_val) || !core.is_number(y1_val) || !core.is_number(x2_val) || !core.is_number(y2_val) || !core.is_number(thick_val) {
			runtime_error(vm, "line_ex() coordinate/thickness arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "line_ex")
		if !ok {
			return false
		}
		p1 := rl.Vector2{f32(core.as_float(x1_val)), f32(core.as_float(y1_val))}
		p2 := rl.Vector2{f32(core.as_float(x2_val)), f32(core.as_float(y2_val))}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawLineEx(p1, p2, f32(core.as_float(thick_val)), col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "triangle":
		if arg_count != 7 {
			runtime_error(vm, "triangle() expects 7 arguments (x1, y1, x2, y2, x3, y3, color).")
			return false
		}
		x1_val, y1_val, x2_val, y2_val, x3_val, y3_val, col_val :=
			peek(vm, 6), peek(vm, 5), peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(x1_val) || !core.is_number(y1_val) || !core.is_number(x2_val) ||
		   !core.is_number(y2_val) || !core.is_number(x3_val) || !core.is_number(y3_val) {
			runtime_error(vm, "triangle() coordinate arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "triangle")
		if !ok {
			return false
		}
		p1 := rl.Vector2{f32(core.as_float(x1_val)), f32(core.as_float(y1_val))}
		p2 := rl.Vector2{f32(core.as_float(x2_val)), f32(core.as_float(y2_val))}
		p3 := rl.Vector2{f32(core.as_float(x3_val)), f32(core.as_float(y3_val))}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawTriangle(p1, p2, p3, col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "rectangle":
		if arg_count != 5 {
			runtime_error(vm, "rectangle() expects 5 arguments (x, y, width, height, color).")
			return false
		}
		x_val, y_val, w_val, h_val, col_val := peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(w_val) || !core.is_number(h_val) {
			runtime_error(vm, "rectangle() x/y/width/height arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "rectangle")
		if !ok {
			return false
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawRectangle(
			c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))),
			c.int(int(core.as_float(w_val))), c.int(int(core.as_float(h_val))),
			col,
		)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "circle":
		if arg_count != 4 {
			runtime_error(vm, "circle() expects 4 arguments (x, y, radius, color).")
			return false
		}
		x_val, y_val, r_val, col_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(r_val) {
			runtime_error(vm, "circle() x/y/radius arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "circle")
		if !ok {
			return false
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawCircleLines(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "circle_fill":
		if arg_count != 4 {
			runtime_error(vm, "circle_fill() expects 4 arguments (x, y, radius, color).")
			return false
		}
		x_val, y_val, r_val, col_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(r_val) {
			runtime_error(vm, "circle_fill() x/y/radius arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "circle_fill")
		if !ok {
			return false
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawCircle(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "draw_texture":
		// glox's RenderTexture.draw_texture is narrower than Window's own
		// (obj_builtin_render_texture.go's render_texture_methods.go): 3
		// args (texture, x, y), always tinted rl.White, no frame-rect/
		// animation support at all -- ported to match that exactly, not
		// Window's own draw_texture.
		if arg_count != 3 {
			runtime_error(vm, "draw_texture() expects 3 arguments (texture, x, y).")
			return false
		}
		tex_val, x_val, y_val := peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if tex_val.type != .Obj || tex_val.obj_type != .Texture {
			runtime_error(vm, "draw_texture() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			runtime_error(vm, "draw_texture() x/y arguments must be numbers.")
			return false
		}
		t := core.as_texture(tex_val)
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawTexture(t.texture, c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), rl.WHITE)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined RenderTexture method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
