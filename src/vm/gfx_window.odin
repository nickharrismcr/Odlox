package vm

import "../core"
import rl "vendor:raylib"
import "core:c"
import "core:strings"

// gfx_window: the raylib-backed window/2D-drawing surface. Ported from
// glox's obj_builtin_window.go/win_methods.go -- this pass covers window
// lifecycle, frame begin/end, input, 2D primitive drawing, texture/
// render_texture drawing, and begin_blend_mode/end_blend_mode (needed by
// lox_examples/defender's fx.lox, see that case's own doc comment);
// shader/camera/batch/batch_instanced, 3D drawing, shader modes, and
// draw_array are deliberately not ported yet (see TODO.md).
//
// Colors cross the Lox boundary as vec4, each channel 0-255 -- matches
// natives/colour_utils.odin's existing, already-shipped convention
// (colour_utils_fade's clamp255/alpha-at-255 usage), not a 0-1
// normalized float.
//
// Deliberate deviation from glox: end() does *not* call rl.DrawFPS(10,
// 10) automatically the way glox's own end() does -- that's a debug
// overlay side effect baked into the wrong place; get_fps() is exposed
// so a script can draw its own FPS text if it wants one at all.
//
// No GC-triggered window teardown: unlike glox, which doesn't call
// CloseWindow from GCFree either, Window_Object owns no GPU resource of
// its own to free -- raylib's window/GL context is process-global, torn
// down only by an explicit .close() call (idempotent via the closed
// bool), never implicitly by garbage collection.

// vec4_to_rl_color/arg_color are package-visible (not file-private): both
// gfx_window.odin (Window's own drawing methods) and gfx_texture.odin
// (Render_Texture's mirrored drawing methods) need them.
vec4_to_rl_color :: proc(v: ^core.Vec4_Object) -> rl.Color {
	return rl.Color{
		u8(clamp(v.x, 0, 255)),
		u8(clamp(v.y, 0, 255)),
		u8(clamp(v.z, 0, 255)),
		u8(clamp(v.w, 0, 255)),
	}
}

// arg_color validates and extracts the color argument every drawing
// method below takes as its last parameter.
arg_color :: proc(vm: ^VM, v: core.Value, method: string) -> (rl.Color, bool) {
	if !core.is_vec4(v) {
		runtime_error(vm, "%s() color argument must be a vec4.", method)
		return {}, false
	}
	return vec4_to_rl_color(core.as_vec4(v)), true
}

invoke_builtin_window :: proc(vm: ^VM, w: ^core.Window_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {

	// --- lifecycle ---
	case "init":
		if arg_count != 0 {
			runtime_error(vm, "init() takes no arguments.")
			return false
		}
		rl.SetTraceLogLevel(.NONE)
		rl.SetConfigFlags({.VSYNC_HINT})
		rl.InitWindow(c.int(w.width), c.int(w.height), "odlox")
		rl.SetTargetFPS(60)
		result = core.NIL_VALUE
	case "close":
		if arg_count != 0 {
			runtime_error(vm, "close() takes no arguments.")
			return false
		}
		if !w.closed {
			rl.CloseWindow()
			w.closed = true
		}
		result = core.NIL_VALUE
	case "should_close":
		if arg_count != 0 {
			runtime_error(vm, "should_close() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.WindowShouldClose()))

	// --- frame ---
	case "begin":
		if arg_count != 0 {
			runtime_error(vm, "begin() takes no arguments.")
			return false
		}
		rl.BeginDrawing()
		rl.BeginBlendMode(.ALPHA)
		result = core.NIL_VALUE
	case "end":
		if arg_count != 0 {
			runtime_error(vm, "end() takes no arguments.")
			return false
		}
		rl.EndDrawing()
		result = core.NIL_VALUE

	// --- info ---
	case "toggle_fullscreen":
		if arg_count != 0 {
			runtime_error(vm, "toggle_fullscreen() takes no arguments.")
			return false
		}
		if !rl.IsWindowFullscreen() {
			monitor := rl.GetCurrentMonitor()
			rl.SetWindowSize(rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor))
		}
		rl.ToggleFullscreen()
		result = core.NIL_VALUE
	case "get_screen_width":
		if arg_count != 0 {
			runtime_error(vm, "get_screen_width() takes no arguments.")
			return false
		}
		// Real, deliberate deviation from glox: returns int, not float
		// -- a screen width has no fractional part, and every other
		// pixel-coordinate argument throughout this file is an int too.
		result = core.make_int_value(int(rl.GetScreenWidth()))
	case "get_screen_height":
		if arg_count != 0 {
			runtime_error(vm, "get_screen_height() takes no arguments.")
			return false
		}
		result = core.make_int_value(int(rl.GetScreenHeight()))
	case "set_target_fps":
		if arg_count != 1 {
			runtime_error(vm, "set_target_fps() expects 1 argument (fps).")
			return false
		}
		fps_val := peek(vm, 0)
		if !core.is_int(fps_val) {
			runtime_error(vm, "set_target_fps() argument must be an integer.")
			return false
		}
		rl.SetTargetFPS(c.int(core.as_int(fps_val)))
		result = core.NIL_VALUE
	case "get_fps":
		if arg_count != 0 {
			runtime_error(vm, "get_fps() takes no arguments.")
			return false
		}
		result = core.make_int_value(int(rl.GetFPS()))

	// --- input ---
	case "key_down":
		if arg_count != 1 {
			runtime_error(vm, "key_down() takes one win.KEY_XXX argument.")
			return false
		}
		key_val := peek(vm, 0)
		if !core.is_int(key_val) {
			runtime_error(vm, "key_down() argument must be an integer (a gfx.KEY_XXX constant).")
			return false
		}
		result = core.make_bool_value(bool(rl.IsKeyDown(rl.KeyboardKey(core.as_int(key_val)))))
	case "key_pressed":
		if arg_count != 1 {
			runtime_error(vm, "key_pressed() takes one win.KEY_XXX argument.")
			return false
		}
		key_val := peek(vm, 0)
		if !core.is_int(key_val) {
			runtime_error(vm, "key_pressed() argument must be an integer (a gfx.KEY_XXX constant).")
			return false
		}
		result = core.make_bool_value(bool(rl.IsKeyPressed(rl.KeyboardKey(core.as_int(key_val)))))

	// --- 2D drawing ---
	case "clear":
		if arg_count != 1 {
			runtime_error(vm, "clear() expects 1 argument (color).")
			return false
		}
		col, ok := arg_color(vm, peek(vm, 0), "clear")
		if !ok {
			return false
		}
		rl.ClearBackground(col)
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
		rl.DrawPixel(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), col)
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
		rl.DrawLine(
			c.int(int(core.as_float(x1_val))), c.int(int(core.as_float(y1_val))),
			c.int(int(core.as_float(x2_val))), c.int(int(core.as_float(y2_val))),
			col,
		)
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
		rl.DrawLineEx(p1, p2, f32(core.as_float(thick_val)), col)
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
		rl.DrawTriangle(p1, p2, p3, col)
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
		rl.DrawRectangle(
			c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))),
			c.int(int(core.as_float(w_val))), c.int(int(core.as_float(h_val))),
			col,
		)
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
		rl.DrawCircleLines(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
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
		rl.DrawCircle(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
		result = core.NIL_VALUE
	case "text":
		if arg_count != 5 {
			runtime_error(vm, "text() expects 5 arguments (text, x, y, size, color).")
			return false
		}
		text_val, x_val, y_val, size_val, col_val := peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_string(text_val) {
			runtime_error(vm, "text() first argument must be a string.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(size_val) {
			runtime_error(vm, "text() x/y/size arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "text")
		if !ok {
			return false
		}
		ctext := strings.clone_to_cstring(core.string_get(core.as_string(text_val)))
		defer delete(ctext)
		rl.DrawText(ctext, c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), c.int(int(core.as_float(size_val))), col)
		result = core.NIL_VALUE

	// --- texture drawing ---
	case "draw_texture":
		if arg_count != 4 {
			runtime_error(vm, "draw_texture() expects 4 arguments (texture, x, y, color).")
			return false
		}
		tex_val, x_val, y_val, col_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if tex_val.type != .Obj || tex_val.obj_type != .Texture {
			runtime_error(vm, "draw_texture() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			runtime_error(vm, "draw_texture() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "draw_texture")
		if !ok {
			return false
		}
		t := core.as_texture(tex_val)
		rect := core.texture_frame_rect(t)
		rl.DrawTextureRec(t.texture, rect, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		core.texture_animate(t)
		result = core.NIL_VALUE
	case "draw_texture_flip":
		// Like draw_texture, but mirrors the sprite horizontally when
		// flip_x is true (a negative source width flips it in place).
		if arg_count != 5 {
			runtime_error(vm, "draw_texture_flip() expects 5 arguments (texture, x, y, color, flip_x).")
			return false
		}
		tex_val, x_val, y_val, col_val, flip_val := peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if tex_val.type != .Obj || tex_val.obj_type != .Texture {
			runtime_error(vm, "draw_texture_flip() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			runtime_error(vm, "draw_texture_flip() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "draw_texture_flip")
		if !ok {
			return false
		}
		t := core.as_texture(tex_val)
		rect := core.texture_frame_rect(t)
		if flip_val.type == .Bool && flip_val.data != 0 {
			rect.width = -rect.width
		}
		rl.DrawTextureRec(t.texture, rect, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		core.texture_animate(t)
		result = core.NIL_VALUE
	case "draw_texture_scaled":
		// Like draw_texture_flip, but scales the drawn size by `scale`
		// (dest size = frame size * scale, anchored at x,y as the
		// top-left corner of the scaled sprite).
		if arg_count != 6 {
			runtime_error(vm, "draw_texture_scaled() expects 6 arguments (texture, x, y, color, flip_x, scale).")
			return false
		}
		tex_val, x_val, y_val, col_val, flip_val, scale_val :=
			peek(vm, 5), peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if tex_val.type != .Obj || tex_val.obj_type != .Texture {
			runtime_error(vm, "draw_texture_scaled() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(scale_val) {
			runtime_error(vm, "draw_texture_scaled() x/y/scale arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "draw_texture_scaled")
		if !ok {
			return false
		}
		t := core.as_texture(tex_val)
		rect := core.texture_frame_rect(t)
		if flip_val.type == .Bool && flip_val.data != 0 {
			rect.width = -rect.width
		}
		abs_width := rect.width
		if abs_width < 0 {
			abs_width = -abs_width
		}
		scale := f32(core.as_float(scale_val))
		dest_rect := rl.Rectangle{f32(core.as_float(x_val)), f32(core.as_float(y_val)), abs_width * scale, rect.height * scale}
		rl.DrawTexturePro(t.texture, rect, dest_rect, rl.Vector2{0, 0}, 0, col)
		core.texture_animate(t)
		result = core.NIL_VALUE
	case "draw_texture_rect":
		if arg_count != 8 {
			runtime_error(vm, "draw_texture_rect() expects 8 arguments (texture, x, y, src_x, src_y, src_w, src_h, color).")
			return false
		}
		tex_val, x_val, y_val, sx_val, sy_val, sw_val, sh_val, col_val :=
			peek(vm, 7), peek(vm, 6), peek(vm, 5), peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if tex_val.type != .Obj || tex_val.obj_type != .Texture {
			runtime_error(vm, "draw_texture_rect() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(sx_val) ||
		   !core.is_number(sy_val) || !core.is_number(sw_val) || !core.is_number(sh_val) {
			runtime_error(vm, "draw_texture_rect() coordinate arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "draw_texture_rect")
		if !ok {
			return false
		}
		t := core.as_texture(tex_val)
		rect := rl.Rectangle{f32(core.as_float(sx_val)), f32(core.as_float(sy_val)), f32(core.as_float(sw_val)), f32(core.as_float(sh_val))}
		rl.DrawTextureRec(t.texture, rect, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		core.texture_animate(t)
		result = core.NIL_VALUE

	// begin_blend_mode/end_blend_mode: a narrow, deliberate exception to
	// "blend modes are out of scope this pass" (see this file's header
	// comment) -- found needed by lox_examples/defender's fx.lox, which
	// calls win.begin_blend_mode("BLEND_ADD") around its particle-effect
	// draw calls. Matches glox's own win_methods.go exactly, *including*
	// its latent bug: glox's BeginBlendMode passes modeVal.AsInt() straight
	// through with no type check, and AsInt() on a non-numeric Value (a
	// string, here) returns 0 (core.Value.AsInt()'s own default case) --
	// so that real, currently-played script's "additive blend" call has
	// always actually meant rl.BlendMode(0), i.e. BlendAlpha (normal
	// blending), never BlendAdditive. core.as_int has the identical
	// default-to-0 behavior for a non-numeric Value (see value.odin), so
	// this port reproduces that behavior byte for byte rather than adding
	// the stricter type validation every other method in this file has --
	// doing so here would turn a silent content bug into a hard crash for
	// a script that has always run, just not quite as its author intended.
	case "begin_blend_mode":
		if arg_count != 1 {
			runtime_error(vm, "begin_blend_mode() expects 1 argument (mode).")
			return false
		}
		mode_val := peek(vm, 0)
		rl.BeginBlendMode(rl.BlendMode(core.as_int(mode_val)))
		result = core.NIL_VALUE
	case "end_blend_mode":
		if arg_count != 0 {
			runtime_error(vm, "end_blend_mode() takes no arguments.")
			return false
		}
		rl.EndBlendMode()
		result = core.NIL_VALUE

	// --- render-texture (off-screen target) mode ---
	case "begin_texture_mode":
		// Redirects every ordinary window drawing call (clear/pixel/
		// line/rectangle/circle/text/draw_texture*/...) at rt instead
		// of the screen, until end_texture_mode -- a raylib-global GL
		// state toggle, not something this file needs to duplicate its
		// own drawing methods for.
		if arg_count != 1 {
			runtime_error(vm, "begin_texture_mode() expects 1 argument (render_texture).")
			return false
		}
		rt_val := peek(vm, 0)
		if rt_val.type != .Obj || rt_val.obj_type != .Render_Texture {
			runtime_error(vm, "begin_texture_mode() argument must be a render_texture.")
			return false
		}
		rl.BeginTextureMode(core.as_render_texture(rt_val).render_texture)
		result = core.NIL_VALUE
	case "end_texture_mode":
		if arg_count != 0 {
			runtime_error(vm, "end_texture_mode() takes no arguments.")
			return false
		}
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "draw_render_texture":
		if arg_count != 4 {
			runtime_error(vm, "draw_render_texture() expects 4 arguments (render_texture, x, y, color).")
			return false
		}
		rt_val, x_val, y_val, col_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if rt_val.type != .Obj || rt_val.obj_type != .Render_Texture {
			runtime_error(vm, "draw_render_texture() first argument must be a render_texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			runtime_error(vm, "draw_render_texture() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "draw_render_texture")
		if !ok {
			return false
		}
		target := core.as_render_texture(rt_val).render_texture.texture
		// Render textures are stored bottom-up in OpenGL -- a negative
		// source height draws it right-side-up, matching glox's own
		// draw_render_texture exactly.
		src := rl.Rectangle{0, 0, f32(target.width), -f32(target.height)}
		rl.DrawTextureRec(target, src, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		result = core.NIL_VALUE
	case "draw_render_texture_ex":
		// Unlike draw_render_texture, glox's own draw_render_texture_ex
		// (win_methods.go) draws via plain rl.DrawTextureEx with no
		// Y-flip correction at all -- ported to match exactly, upside-down
		// quirk included, not "fixed" to be consistent with the non-ex
		// version. Found needed by lox_examples/tile_planes.lox.
		if arg_count != 6 {
			runtime_error(vm, "draw_render_texture_ex() expects 6 arguments (render_texture, x, y, rotation, scale, color).")
			return false
		}
		rt_val, x_val, y_val, rot_val, scale_val, col_val := peek(vm, 5), peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if rt_val.type != .Obj || rt_val.obj_type != .Render_Texture {
			runtime_error(vm, "draw_render_texture_ex() first argument must be a render_texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(rot_val) || !core.is_number(scale_val) {
			runtime_error(vm, "draw_render_texture_ex() x/y/rotation/scale arguments must be numbers.")
			return false
		}
		col, ok := arg_color(vm, col_val, "draw_render_texture_ex")
		if !ok {
			return false
		}
		target := core.as_render_texture(rt_val).render_texture.texture
		rl.DrawTextureEx(
			target,
			rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))},
			f32(core.as_float(rot_val)), f32(core.as_float(scale_val)),
			col,
		)
		result = core.NIL_VALUE

	case:
		runtime_error(vm, "Undefined Window method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}

// window_constant answers a `win.KEY_*`/`win.BLEND_*`/`win.WRAP_*` property
// read (properties.odin's get_property .Window case) -- glox registers all
// of these directly on the window object (RegisterAllWindowConstants,
// win_methods.go), not as module-level constants; a real script (found via
// porting the lox_examples/defender game, and BLEND_ALPHA/BLEND_MULTIPLY/
// WRAP_REPEAT via tile_planes.lox) accesses them as `win.KEY_SPACE`/
// `win.BLEND_ALPHA` etc., not `gfx.KEY_SPACE`, so that's the surface this
// ports. Full rl.KeyboardKey coverage except KEY_BACK/KEY_MENU
// (Android-only buttons glox's own raylib-go binding exposes that
// vendor:raylib's Odin binding does not); full BLEND_*/WRAP_* coverage.
// BATCH_* deliberately not included -- gfx.batch()/batch_instanced()
// themselves aren't implemented yet (see TODO.md), so those constants
// would have no consumer. Values are plain immutable ints, identical
// across every Window instance, so this is a pure function of the name
// rather than per-object state.
window_constant :: proc(name: string) -> (core.Value, bool) {
	switch name {
	case "BLEND_ADD": return core.make_int_value(int(rl.BlendMode.ADDITIVE), true), true
	case "BLEND_ALPHA": return core.make_int_value(int(rl.BlendMode.ALPHA), true), true
	case "BLEND_MULTIPLY": return core.make_int_value(int(rl.BlendMode.MULTIPLIED), true), true
	case "BLEND_SUBCOLOR": return core.make_int_value(int(rl.BlendMode.SUBTRACT_COLORS), true), true
	case "BLEND_ADDCOLOR": return core.make_int_value(int(rl.BlendMode.ADD_COLORS), true), true
	case "WRAP_REPEAT": return core.make_int_value(int(rl.TextureWrap.REPEAT), true), true
	case "WRAP_CLAMP": return core.make_int_value(int(rl.TextureWrap.CLAMP), true), true
	case "WRAP_MIRROR_REPEAT": return core.make_int_value(int(rl.TextureWrap.MIRROR_REPEAT), true), true
	case "WRAP_MIRROR_CLAMP": return core.make_int_value(int(rl.TextureWrap.MIRROR_CLAMP), true), true
	}

	key: rl.KeyboardKey
	switch name {
	case "KEY_NULL": key = .KEY_NULL
	case "KEY_SPACE": key = .SPACE
	case "KEY_ESCAPE": key = .ESCAPE
	case "KEY_ENTER": key = .ENTER
	case "KEY_TAB": key = .TAB
	case "KEY_BACKSPACE": key = .BACKSPACE
	case "KEY_INSERT": key = .INSERT
	case "KEY_DELETE": key = .DELETE
	case "KEY_RIGHT": key = .RIGHT
	case "KEY_LEFT": key = .LEFT
	case "KEY_DOWN": key = .DOWN
	case "KEY_UP": key = .UP
	case "KEY_PAGE_UP": key = .PAGE_UP
	case "KEY_PAGE_DOWN": key = .PAGE_DOWN
	case "KEY_HOME": key = .HOME
	case "KEY_END": key = .END
	case "KEY_CAPS_LOCK": key = .CAPS_LOCK
	case "KEY_SCROLL_LOCK": key = .SCROLL_LOCK
	case "KEY_NUM_LOCK": key = .NUM_LOCK
	case "KEY_PRINT_SCREEN": key = .PRINT_SCREEN
	case "KEY_PAUSE": key = .PAUSE
	case "KEY_F1": key = .F1
	case "KEY_F2": key = .F2
	case "KEY_F3": key = .F3
	case "KEY_F4": key = .F4
	case "KEY_F5": key = .F5
	case "KEY_F6": key = .F6
	case "KEY_F7": key = .F7
	case "KEY_F8": key = .F8
	case "KEY_F9": key = .F9
	case "KEY_F10": key = .F10
	case "KEY_F11": key = .F11
	case "KEY_F12": key = .F12
	case "KEY_LEFT_SHIFT": key = .LEFT_SHIFT
	case "KEY_LEFT_CONTROL": key = .LEFT_CONTROL
	case "KEY_LEFT_ALT": key = .LEFT_ALT
	case "KEY_LEFT_SUPER": key = .LEFT_SUPER
	case "KEY_RIGHT_SHIFT": key = .RIGHT_SHIFT
	case "KEY_RIGHT_CONTROL": key = .RIGHT_CONTROL
	case "KEY_RIGHT_ALT": key = .RIGHT_ALT
	case "KEY_RIGHT_SUPER": key = .RIGHT_SUPER
	case "KEY_KB_MENU": key = .KB_MENU
	case "KEY_LEFT_BRACKET": key = .LEFT_BRACKET
	case "KEY_BACK_SLASH": key = .BACKSLASH
	case "KEY_RIGHT_BRACKET": key = .RIGHT_BRACKET
	case "KEY_GRAVE": key = .GRAVE
	case "KEY_KP_0": key = .KP_0
	case "KEY_KP_1": key = .KP_1
	case "KEY_KP_2": key = .KP_2
	case "KEY_KP_3": key = .KP_3
	case "KEY_KP_4": key = .KP_4
	case "KEY_KP_5": key = .KP_5
	case "KEY_KP_6": key = .KP_6
	case "KEY_KP_7": key = .KP_7
	case "KEY_KP_8": key = .KP_8
	case "KEY_KP_9": key = .KP_9
	case "KEY_KP_DECIMAL": key = .KP_DECIMAL
	case "KEY_KP_DIVIDE": key = .KP_DIVIDE
	case "KEY_KP_MULTIPLY": key = .KP_MULTIPLY
	case "KEY_KP_SUBTRACT": key = .KP_SUBTRACT
	case "KEY_KP_ADD": key = .KP_ADD
	case "KEY_KP_ENTER": key = .KP_ENTER
	case "KEY_KP_EQUAL": key = .KP_EQUAL
	case "KEY_APOSTROPHE": key = .APOSTROPHE
	case "KEY_COMMA": key = .COMMA
	case "KEY_MINUS": key = .MINUS
	case "KEY_PERIOD": key = .PERIOD
	case "KEY_SLASH": key = .SLASH
	case "KEY_ZERO": key = .ZERO
	case "KEY_ONE": key = .ONE
	case "KEY_TWO": key = .TWO
	case "KEY_THREE": key = .THREE
	case "KEY_FOUR": key = .FOUR
	case "KEY_FIVE": key = .FIVE
	case "KEY_SIX": key = .SIX
	case "KEY_SEVEN": key = .SEVEN
	case "KEY_EIGHT": key = .EIGHT
	case "KEY_NINE": key = .NINE
	case "KEY_SEMICOLON": key = .SEMICOLON
	case "KEY_EQUAL": key = .EQUAL
	case "KEY_A": key = .A
	case "KEY_B": key = .B
	case "KEY_C": key = .C
	case "KEY_D": key = .D
	case "KEY_E": key = .E
	case "KEY_F": key = .F
	case "KEY_G": key = .G
	case "KEY_H": key = .H
	case "KEY_I": key = .I
	case "KEY_J": key = .J
	case "KEY_K": key = .K
	case "KEY_L": key = .L
	case "KEY_M": key = .M
	case "KEY_N": key = .N
	case "KEY_O": key = .O
	case "KEY_P": key = .P
	case "KEY_Q": key = .Q
	case "KEY_R": key = .R
	case "KEY_S": key = .S
	case "KEY_T": key = .T
	case "KEY_U": key = .U
	case "KEY_V": key = .V
	case "KEY_W": key = .W
	case "KEY_X": key = .X
	case "KEY_Y": key = .Y
	case "KEY_Z": key = .Z
	case "KEY_VOLUME_UP": key = .VOLUME_UP
	case "KEY_VOLUME_DOWN": key = .VOLUME_DOWN
	case:
		return core.NIL_VALUE, false
	}
	return core.make_int_value(int(key), true), true
}
