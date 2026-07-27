package vm

import "../core"
import rl "vendor:raylib"
import "core:c"
import "core:strings"

// gfx_window: the raylib-backed window/2D-drawing surface. Ported from
// glox's obj_builtin_window.go/win_methods.go -- this pass covers only
// window lifecycle, frame begin/end, input, and 2D primitive drawing;
// texture/shader/camera/render_texture/batch/batch_instanced, 3D
// drawing, blend/shader modes, and draw_array are deliberately not
// ported yet (see TODO.md).
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

@(private = "file")
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
@(private = "file")
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

	case:
		runtime_error(vm, "Undefined Window method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
