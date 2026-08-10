package natives

import "../core"
import "../vm"
import "core:c"
import "core:math"
import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// gfx_window: Window_Data -- the Lox-facing handle for raylib's
// window/graphics context. raylib's own window/OpenGL-context state is
// process-global (InitWindow/CloseWindow), so this struct is mostly a
// lightweight marker plus the width/height a script asked for, and the
// lazily-built shared unit-cube mesh/material `cube_mesh`/`cube_material`
// need (raylib has no DrawCube overload that takes a rotation, so those
// draw an arbitrarily rotated box via DrawMesh with a transform matrix
// instead -- one shared unit cube serves every box regardless of size,
// scaled at draw time).
//
// window lifecycle, frame begin/end, input, 2D primitive drawing,
// texture/render_texture drawing, blend/shader modes, 3D drawing (see
// begin_3d's own doc comment), draw_array, and win.KEY_*/BLEND_*/WRAP_*/
// BATCH_* property constants (window_get_property, via the vtable's
// get_property hook) all live here too.
//
// Colors cross the Lox boundary as vec4, each channel 0-255 -- matches
// colour_utils.odin's existing convention (colour_utils_fade's
// clamp255/alpha-at-255 usage), not a 0-1 normalized float.
//
// end() does *not* call rl.DrawFPS unconditionally -- that would be a
// debug overlay side effect baked into every frame regardless of
// whether the script wants one. It's opt-in instead: .show_fps(bool)
// toggles it (off by default), and get_fps() remains available too for
// a script that wants to draw its own FPS text some other way entirely.
//
// No GC-triggered window teardown: Window_Data owns no GPU resource of
// its own to free -- raylib's window/GL context is process-global, torn
// down only by an explicit .close() call (idempotent via the closed
// bool), never implicitly by garbage collection. Its lazily-built
// cube_mesh/cube_material are the same story -- never explicitly
// unloaded, process exit tears down the GL context regardless.

Window_Data :: struct {
	width:    int,
	height:   int,
	closed:   bool, // latched by .close() so a second call is a no-op, not a second CloseWindow()
	show_fps: bool, // toggled by .show_fps(bool) -- see the "end" case

	cube_mesh:       rl.Mesh,
	cube_material:   rl.Material,
	cube_mesh_ready: bool,

	// begin_shader_mode/end_shader_mode's rl.BeginShaderMode only affects
	// rlgl immediate-mode draws (cube/sphere/cylinder/...) -- DrawMesh
	// (cube_rotated) binds material.shader directly instead and never
	// sees that global state, so it's mirrored here to apply the same
	// active shader to DrawMesh-based draws too.
	active_shader:      rl.Shader,
	shader_mode_active: bool,
}

@(private = "file")
window_vtable := core.Userdata_Vtable {
	tag          = "window",
	free         = window_data_free,
	invoke       = window_invoke,
	get_property = window_get_property,
}

@(private = "file")
window_data_free :: proc(data: rawptr) {
	free(cast(^Window_Data)data)
}

@(private = "file")
window_get_property :: proc(data: rawptr, name: string) -> (core.Value, bool) {
	return window_constant(name)
}

@(private)
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
	data := new(Window_Data)
	data.width = core.as_int(w_val)
	data.height = core.as_int(h_val)
	o := core.make_userdata_object(&window_vtable, data)
	vm.gc_track(v, &o.obj)
	window_created = true
	return core.make_object_value(&o.obj, true)
}

// window_cube_model lazily creates and caches a shared unit cube mesh +
// default material -- see this file's own header comment for why.
@(private = "file")
window_cube_model :: proc(w: ^Window_Data) -> (rl.Mesh, rl.Material) {
	if !w.cube_mesh_ready {
		w.cube_mesh = rl.GenMeshCube(1, 1, 1)
		if w.cube_mesh.vaoId == 0 {
			rl.UploadMesh(&w.cube_mesh, false)
		}
		w.cube_material = rl.LoadMaterialDefault()
		w.cube_mesh_ready = true
	}
	return w.cube_mesh, w.cube_material
}

@(private = "file")
window_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	w := cast(^Window_Data)data
	result: core.Value
	switch name {

	// --- lifecycle ---
	case "init":
		if arg_count != 0 {
			vm.runtime_error(v, "init() takes no arguments.")
			return false
		}
		rl.SetTraceLogLevel(.NONE)
		rl.SetConfigFlags({.VSYNC_HINT})
		rl.InitWindow(c.int(w.width), c.int(w.height), "odlox")
		rl.SetTargetFPS(60)
		result = core.NIL_VALUE
	case "close":
		if arg_count != 0 {
			vm.runtime_error(v, "close() takes no arguments.")
			return false
		}
		if !w.closed {
			rl.CloseWindow()
			w.closed = true
		}
		result = core.NIL_VALUE
	case "should_close":
		if arg_count != 0 {
			vm.runtime_error(v, "should_close() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.WindowShouldClose()))

	// --- frame ---
	case "begin":
		if arg_count != 0 {
			vm.runtime_error(v, "begin() takes no arguments.")
			return false
		}
		rl.BeginDrawing()
		rl.BeginBlendMode(.ALPHA)
		result = core.NIL_VALUE
	case "end":
		if arg_count != 0 {
			vm.runtime_error(v, "end() takes no arguments.")
			return false
		}
		if w.show_fps {
			rl.DrawFPS(10, 10)
		}
		rl.EndDrawing()
		result = core.NIL_VALUE
	case "show_fps":
		if arg_count != 1 {
			vm.runtime_error(v, "show_fps() expects 1 argument (bool).")
			return false
		}
		enabled_val := vm.peek(v, 0)
		if enabled_val.type != .Bool {
			vm.runtime_error(v, "show_fps() argument must be a bool.")
			return false
		}
		w.show_fps = enabled_val.data != 0
		result = core.NIL_VALUE

	// --- info ---
	case "toggle_fullscreen":
		if arg_count != 0 {
			vm.runtime_error(v, "toggle_fullscreen() takes no arguments.")
			return false
		}
		if !rl.IsWindowFullscreen() {
			monitor := rl.GetCurrentMonitor()
			rl.SetWindowSize(rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor))
		}
		rl.ToggleFullscreen()
		result = core.NIL_VALUE
	case "screenshot":
		if arg_count != 1 {
			vm.runtime_error(v, "screenshot() expects 1 argument (path).")
			return false
		}
		path_val := vm.peek(v, 0)
		if !core.is_string(path_val) {
			vm.runtime_error(v, "screenshot() argument must be a string (path).")
			return false
		}
		cpath := strings.clone_to_cstring(core.string_get(core.as_string(path_val)))
		defer delete(cpath)
		rl.TakeScreenshot(cpath)
		result = core.NIL_VALUE
	case "get_screen_width":
		if arg_count != 0 {
			vm.runtime_error(v, "get_screen_width() takes no arguments.")
			return false
		}
		// Returns int, not float -- a screen width has no fractional part,
		// and every other pixel-coordinate argument throughout this file
		// is an int too.
		result = core.make_int_value(int(rl.GetScreenWidth()))
	case "get_screen_height":
		if arg_count != 0 {
			vm.runtime_error(v, "get_screen_height() takes no arguments.")
			return false
		}
		result = core.make_int_value(int(rl.GetScreenHeight()))
	case "set_target_fps":
		if arg_count != 1 {
			vm.runtime_error(v, "set_target_fps() expects 1 argument (fps).")
			return false
		}
		fps_val := vm.peek(v, 0)
		if !core.is_int(fps_val) {
			vm.runtime_error(v, "set_target_fps() argument must be an integer.")
			return false
		}
		rl.SetTargetFPS(c.int(core.as_int(fps_val)))
		result = core.NIL_VALUE
	case "get_fps":
		if arg_count != 0 {
			vm.runtime_error(v, "get_fps() takes no arguments.")
			return false
		}
		result = core.make_int_value(int(rl.GetFPS()))
	case "get_frame_time":
		// Actual measured duration of the last frame, in seconds -- unlike
		// get_fps() (an average smoothed over ~10 frames), this reflects
		// that one frame directly, so per-frame motion can be scaled by it
		// (distance/turn_rate * get_frame_time()) to stay speed-correct
		// even when the frame rate isn't perfectly steady, rather than
		// baking in an assumption of a fixed frame budget.
		if arg_count != 0 {
			vm.runtime_error(v, "get_frame_time() takes no arguments.")
			return false
		}
		result = core.make_float_value(f64(rl.GetFrameTime()))
	case "get_time":
		// Seconds elapsed since rl.InitWindow, as a monotonic f64 -- unlike
		// get_frame_time() (one frame's duration) or get_fps() (a smoothed
		// rate), this is a plain clock reading, for timing arbitrary spans
		// of script code by taking the difference between two calls.
		if arg_count != 0 {
			vm.runtime_error(v, "get_time() takes no arguments.")
			return false
		}
		result = core.make_float_value(rl.GetTime())

	// --- input ---
	case "key_down":
		if arg_count != 1 {
			vm.runtime_error(v, "key_down() takes one win.KEY_XXX argument.")
			return false
		}
		key_val := vm.peek(v, 0)
		if !core.is_int(key_val) {
			vm.runtime_error(v, "key_down() argument must be an integer (a gfx.KEY_XXX constant).")
			return false
		}
		result = core.make_bool_value(bool(rl.IsKeyDown(rl.KeyboardKey(core.as_int(key_val)))))
	case "key_pressed":
		if arg_count != 1 {
			vm.runtime_error(v, "key_pressed() takes one win.KEY_XXX argument.")
			return false
		}
		key_val := vm.peek(v, 0)
		if !core.is_int(key_val) {
			vm.runtime_error(v, "key_pressed() argument must be an integer (a gfx.KEY_XXX constant).")
			return false
		}
		result = core.make_bool_value(bool(rl.IsKeyPressed(rl.KeyboardKey(core.as_int(key_val)))))
	case "mouse_position":
		if arg_count != 0 {
			vm.runtime_error(v, "mouse_position() takes no arguments.")
			return false
		}
		pos := rl.GetMousePosition()
		result = core.make_vec2_value(f64(pos.x), f64(pos.y))
	case "mouse_delta":
		if arg_count != 0 {
			vm.runtime_error(v, "mouse_delta() takes no arguments.")
			return false
		}
		delta := rl.GetMouseDelta()
		result = core.make_vec2_value(f64(delta.x), f64(delta.y))
	case "mouse_down":
		if arg_count != 1 {
			vm.runtime_error(v, "mouse_down() takes one win.MOUSE_XXX argument.")
			return false
		}
		button_val := vm.peek(v, 0)
		if !core.is_int(button_val) {
			vm.runtime_error(v, "mouse_down() argument must be an integer (a win.MOUSE_XXX constant).")
			return false
		}
		result = core.make_bool_value(bool(rl.IsMouseButtonDown(rl.MouseButton(core.as_int(button_val)))))
	case "mouse_pressed":
		if arg_count != 1 {
			vm.runtime_error(v, "mouse_pressed() takes one win.MOUSE_XXX argument.")
			return false
		}
		button_val := vm.peek(v, 0)
		if !core.is_int(button_val) {
			vm.runtime_error(v, "mouse_pressed() argument must be an integer (a win.MOUSE_XXX constant).")
			return false
		}
		result = core.make_bool_value(bool(rl.IsMouseButtonPressed(rl.MouseButton(core.as_int(button_val)))))
	case "mouse_released":
		if arg_count != 1 {
			vm.runtime_error(v, "mouse_released() takes one win.MOUSE_XXX argument.")
			return false
		}
		button_val := vm.peek(v, 0)
		if !core.is_int(button_val) {
			vm.runtime_error(v, "mouse_released() argument must be an integer (a win.MOUSE_XXX constant).")
			return false
		}
		result = core.make_bool_value(bool(rl.IsMouseButtonReleased(rl.MouseButton(core.as_int(button_val)))))
	case "mouse_wheel":
		if arg_count != 0 {
			vm.runtime_error(v, "mouse_wheel() takes no arguments.")
			return false
		}
		result = core.make_float_value(f64(rl.GetMouseWheelMove()))
	case "show_cursor":
		if arg_count != 0 {
			vm.runtime_error(v, "show_cursor() takes no arguments.")
			return false
		}
		rl.ShowCursor()
		result = core.NIL_VALUE
	case "hide_cursor":
		if arg_count != 0 {
			vm.runtime_error(v, "hide_cursor() takes no arguments.")
			return false
		}
		rl.HideCursor()
		result = core.NIL_VALUE
	case "is_cursor_hidden":
		if arg_count != 0 {
			vm.runtime_error(v, "is_cursor_hidden() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.IsCursorHidden()))
	case "disable_cursor":
		// Unlike hide_cursor (visibility only), this locks the cursor to
		// the window -- raylib re-centres it every frame internally, so
		// mouse_delta() keeps reporting real relative movement no matter
		// how far or how long the mouse is pushed in one direction,
		// instead of the real OS cursor drifting into a screen edge and
		// getting stuck there (no further delta in that direction until
		// physically moved back). The standard raylib idiom for a
		// mouse-look/FPS-style camera.
		if arg_count != 0 {
			vm.runtime_error(v, "disable_cursor() takes no arguments.")
			return false
		}
		rl.DisableCursor()
		result = core.NIL_VALUE
	case "enable_cursor":
		if arg_count != 0 {
			vm.runtime_error(v, "enable_cursor() takes no arguments.")
			return false
		}
		rl.EnableCursor()
		result = core.NIL_VALUE

	// --- 2D drawing ---
	case "clear":
		if arg_count != 1 {
			vm.runtime_error(v, "clear() expects 1 argument (color).")
			return false
		}
		col, ok := arg_color(v, vm.peek(v, 0), "clear")
		if !ok {
			return false
		}
		rl.ClearBackground(col)
		result = core.NIL_VALUE
	case "pixel":
		if arg_count != 3 {
			vm.runtime_error(v, "pixel() expects 3 arguments (x, y, color).")
			return false
		}
		x_val, y_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) {
			vm.runtime_error(v, "pixel() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "pixel")
		if !ok {
			return false
		}
		rl.DrawPixel(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), col)
		result = core.NIL_VALUE
	case "line":
		if arg_count != 5 {
			vm.runtime_error(v, "line() expects 5 arguments (x1, y1, x2, y2, color).")
			return false
		}
		x1_val, y1_val, x2_val, y2_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x1_val) || !core.is_number(y1_val) || !core.is_number(x2_val) || !core.is_number(y2_val) {
			vm.runtime_error(v, "line() coordinate arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "line")
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
			vm.runtime_error(v, "line_ex() expects 6 arguments (x1, y1, x2, y2, thickness, color).")
			return false
		}
		x1_val, y1_val, x2_val, y2_val, thick_val, col_val := vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x1_val) || !core.is_number(y1_val) || !core.is_number(x2_val) || !core.is_number(y2_val) || !core.is_number(thick_val) {
			vm.runtime_error(v, "line_ex() coordinate/thickness arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "line_ex")
		if !ok {
			return false
		}
		p1 := rl.Vector2{f32(core.as_float(x1_val)), f32(core.as_float(y1_val))}
		p2 := rl.Vector2{f32(core.as_float(x2_val)), f32(core.as_float(y2_val))}
		rl.DrawLineEx(p1, p2, f32(core.as_float(thick_val)), col)
		result = core.NIL_VALUE
	case "triangle":
		if arg_count != 7 {
			vm.runtime_error(v, "triangle() expects 7 arguments (x1, y1, x2, y2, x3, y3, color).")
			return false
		}
		x1_val, y1_val, x2_val, y2_val, x3_val, y3_val, col_val :=
			vm.peek(v, 6), vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x1_val) || !core.is_number(y1_val) || !core.is_number(x2_val) ||
		   !core.is_number(y2_val) || !core.is_number(x3_val) || !core.is_number(y3_val) {
			vm.runtime_error(v, "triangle() coordinate arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "triangle")
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
			vm.runtime_error(v, "rectangle() expects 5 arguments (x, y, width, height, color).")
			return false
		}
		x_val, y_val, w_val, h_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(w_val) || !core.is_number(h_val) {
			vm.runtime_error(v, "rectangle() x/y/width/height arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "rectangle")
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
			vm.runtime_error(v, "circle() expects 4 arguments (x, y, radius, color).")
			return false
		}
		x_val, y_val, r_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(r_val) {
			vm.runtime_error(v, "circle() x/y/radius arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "circle")
		if !ok {
			return false
		}
		rl.DrawCircleLines(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
		result = core.NIL_VALUE
	case "circle_fill":
		if arg_count != 4 {
			vm.runtime_error(v, "circle_fill() expects 4 arguments (x, y, radius, color).")
			return false
		}
		x_val, y_val, r_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(r_val) {
			vm.runtime_error(v, "circle_fill() x/y/radius arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "circle_fill")
		if !ok {
			return false
		}
		rl.DrawCircle(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
		result = core.NIL_VALUE
	case "text":
		if arg_count != 5 {
			vm.runtime_error(v, "text() expects 5 arguments (text, x, y, size, color).")
			return false
		}
		text_val, x_val, y_val, size_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_string(text_val) {
			vm.runtime_error(v, "text() first argument must be a string.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(size_val) {
			vm.runtime_error(v, "text() x/y/size arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "text")
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
			vm.runtime_error(v, "draw_texture() expects 4 arguments (texture, x, y, color).")
			return false
		}
		tex_val, x_val, y_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !is_texture_value(tex_val) {
			vm.runtime_error(v, "draw_texture() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			vm.runtime_error(v, "draw_texture() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "draw_texture")
		if !ok {
			return false
		}
		t := texture_data_of(tex_val)
		rect := texture_frame_rect(t)
		rl.DrawTextureRec(t.texture, rect, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		texture_animate(t)
		result = core.NIL_VALUE
	case "draw_texture_flip":
		// Like draw_texture, but mirrors the sprite horizontally when
		// flip_x is true (a negative source width flips it in place).
		if arg_count != 5 {
			vm.runtime_error(v, "draw_texture_flip() expects 5 arguments (texture, x, y, color, flip_x).")
			return false
		}
		tex_val, x_val, y_val, col_val, flip_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !is_texture_value(tex_val) {
			vm.runtime_error(v, "draw_texture_flip() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			vm.runtime_error(v, "draw_texture_flip() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "draw_texture_flip")
		if !ok {
			return false
		}
		t := texture_data_of(tex_val)
		rect := texture_frame_rect(t)
		if flip_val.type == .Bool && flip_val.data != 0 {
			rect.width = -rect.width
		}
		rl.DrawTextureRec(t.texture, rect, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		texture_animate(t)
		result = core.NIL_VALUE
	case "draw_texture_scaled":
		// Like draw_texture_flip, but scales the drawn size by `scale`
		// (dest size = frame size * scale, anchored at x,y as the
		// top-left corner of the scaled sprite).
		if arg_count != 6 {
			vm.runtime_error(v, "draw_texture_scaled() expects 6 arguments (texture, x, y, color, flip_x, scale).")
			return false
		}
		tex_val, x_val, y_val, col_val, flip_val, scale_val :=
			vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !is_texture_value(tex_val) {
			vm.runtime_error(v, "draw_texture_scaled() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(scale_val) {
			vm.runtime_error(v, "draw_texture_scaled() x/y/scale arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "draw_texture_scaled")
		if !ok {
			return false
		}
		t := texture_data_of(tex_val)
		rect := texture_frame_rect(t)
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
		texture_animate(t)
		result = core.NIL_VALUE
	case "draw_texture_rect":
		if arg_count != 8 {
			vm.runtime_error(v, "draw_texture_rect() expects 8 arguments (texture, x, y, src_x, src_y, src_w, src_h, color).")
			return false
		}
		tex_val, x_val, y_val, sx_val, sy_val, sw_val, sh_val, col_val :=
			vm.peek(v, 7), vm.peek(v, 6), vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !is_texture_value(tex_val) {
			vm.runtime_error(v, "draw_texture_rect() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(sx_val) ||
		   !core.is_number(sy_val) || !core.is_number(sw_val) || !core.is_number(sh_val) {
			vm.runtime_error(v, "draw_texture_rect() coordinate arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "draw_texture_rect")
		if !ok {
			return false
		}
		t := texture_data_of(tex_val)
		rect := rl.Rectangle{f32(core.as_float(sx_val)), f32(core.as_float(sy_val)), f32(core.as_float(sw_val)), f32(core.as_float(sh_val))}
		rl.DrawTextureRec(t.texture, rect, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		texture_animate(t)
		result = core.NIL_VALUE
	case "draw_texture_pro":
		// Unlike every other draw_texture* method here, the source can be
		// either a Texture or a Render_Texture. Draws straight to
		// whatever the current GL target already is, with no
		// BeginTextureMode wrapping (render_texture's own draw_texture_pro
		// brackets the draw in one instead).
		if arg_count != 13 {
			vm.runtime_error(
				v,
				"draw_texture_pro() expects 13 arguments (texture, src_x, src_y, src_w, src_h, dest_x, dest_y, dest_w, dest_h, origin_x, origin_y, rotation, color).",
			)
			return false
		}
		tex_val, src_x, src_y, src_w, src_h, dst_x, dst_y, dst_w, dst_h, org_x, org_y, rot_val, col_val :=
			vm.peek(v, 12), vm.peek(v, 11), vm.peek(v, 10), vm.peek(v, 9), vm.peek(v, 8), vm.peek(v, 7), vm.peek(v, 6),
			vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		texture: rl.Texture2D
		if is_texture_value(tex_val) {
			texture = texture_data_of(tex_val).texture
		} else if is_render_texture_value(tex_val) {
			texture = render_texture_data_of(tex_val).render_texture.texture
		} else {
			vm.runtime_error(v, "draw_texture_pro() first argument must be a texture or render_texture.")
			return false
		}
		if !core.is_number(src_x) || !core.is_number(src_y) || !core.is_number(src_w) || !core.is_number(src_h) ||
		   !core.is_number(dst_x) || !core.is_number(dst_y) || !core.is_number(dst_w) || !core.is_number(dst_h) ||
		   !core.is_number(org_x) || !core.is_number(org_y) || !core.is_number(rot_val) {
			vm.runtime_error(v, "draw_texture_pro() coordinate/rotation arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "draw_texture_pro")
		if !ok {
			return false
		}
		src := rl.Rectangle{f32(core.as_float(src_x)), f32(core.as_float(src_y)), f32(core.as_float(src_w)), f32(core.as_float(src_h))}
		dst := rl.Rectangle{f32(core.as_float(dst_x)), f32(core.as_float(dst_y)), f32(core.as_float(dst_w)), f32(core.as_float(dst_h))}
		origin := rl.Vector2{f32(core.as_float(org_x)), f32(core.as_float(org_y))}
		rl.DrawTexturePro(texture, src, dst, origin, f32(core.as_float(rot_val)), col)
		result = core.NIL_VALUE

	// begin_blend_mode() deliberately skips the argument-type validation
	// every other method in this file has: core.as_int returns 0 for a
	// non-numeric Value (see value.odin), so passing something other
	// than one of the win.BLEND_* constants silently falls back to
	// rl.BlendMode(0) (ordinary alpha blending) rather than raising a
	// runtime error -- a bad blend-mode argument produces a
	// visually-wrong frame instead of crashing the script.
	case "begin_blend_mode":
		if arg_count != 1 {
			vm.runtime_error(v, "begin_blend_mode() expects 1 argument (mode).")
			return false
		}
		mode_val := vm.peek(v, 0)
		rl.BeginBlendMode(rl.BlendMode(core.as_int(mode_val)))
		result = core.NIL_VALUE
	case "end_blend_mode":
		if arg_count != 0 {
			vm.runtime_error(v, "end_blend_mode() takes no arguments.")
			return false
		}
		rl.EndBlendMode()
		result = core.NIL_VALUE

	// begin_shader_mode/end_shader_mode redirect subsequent draw calls
	// through a custom GLSL shader. Only affects draws that use raylib's
	// currently-bound shader -- plain 2D primitives, win.draw_texture*,
	// and win.draw_render_texture* all qualify; batch_instanced always
	// renders with its own fixed shader regardless.
	case "begin_shader_mode":
		if arg_count != 1 {
			vm.runtime_error(v, "begin_shader_mode() expects 1 argument (shader).")
			return false
		}
		shader_val := vm.peek(v, 0)
		if !is_shader_value(shader_val) {
			vm.runtime_error(v, "begin_shader_mode() argument must be a shader.")
			return false
		}
		w.active_shader = shader_data_of(shader_val).shader
		w.shader_mode_active = true
		rl.BeginShaderMode(w.active_shader)
		result = core.NIL_VALUE
	case "end_shader_mode":
		if arg_count != 0 {
			vm.runtime_error(v, "end_shader_mode() takes no arguments.")
			return false
		}
		w.shader_mode_active = false
		rl.EndShaderMode()
		result = core.NIL_VALUE

	// --- render-texture (off-screen target) mode ---
	case "begin_texture_mode":
		// Redirects every ordinary window drawing call (clear/pixel/
		// line/rectangle/circle/text/draw_texture*/...) at rt instead
		// of the screen, until end_texture_mode -- a raylib-global GL
		// state toggle, not something this file needs to duplicate its
		// own drawing methods for.
		if arg_count != 1 {
			vm.runtime_error(v, "begin_texture_mode() expects 1 argument (render_texture).")
			return false
		}
		rt_val := vm.peek(v, 0)
		if !is_render_texture_value(rt_val) {
			vm.runtime_error(v, "begin_texture_mode() argument must be a render_texture.")
			return false
		}
		rl.BeginTextureMode(render_texture_data_of(rt_val).render_texture)
		result = core.NIL_VALUE
	case "end_texture_mode":
		if arg_count != 0 {
			vm.runtime_error(v, "end_texture_mode() takes no arguments.")
			return false
		}
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "draw_render_texture":
		if arg_count != 4 {
			vm.runtime_error(v, "draw_render_texture() expects 4 arguments (render_texture, x, y, color).")
			return false
		}
		rt_val, x_val, y_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !is_render_texture_value(rt_val) {
			vm.runtime_error(v, "draw_render_texture() first argument must be a render_texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			vm.runtime_error(v, "draw_render_texture() x/y arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "draw_render_texture")
		if !ok {
			return false
		}
		target := render_texture_data_of(rt_val).render_texture.texture
		// Render textures are stored bottom-up in OpenGL -- a negative
		// source height draws it right-side-up.
		src := rl.Rectangle{0, 0, f32(target.width), -f32(target.height)}
		rl.DrawTextureRec(target, src, rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))}, col)
		result = core.NIL_VALUE
	case "draw_render_texture_ex":
		// Unlike draw_render_texture, this draws via plain rl.DrawTextureEx
		// with no Y-flip correction -- the render texture's bottom-up
		// OpenGL storage (see draw_render_texture's own comment) is not
		// compensated for here, so the result renders upside-down.
		if arg_count != 6 {
			vm.runtime_error(v, "draw_render_texture_ex() expects 6 arguments (render_texture, x, y, rotation, scale, color).")
			return false
		}
		rt_val, x_val, y_val, rot_val, scale_val, col_val := vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !is_render_texture_value(rt_val) {
			vm.runtime_error(v, "draw_render_texture_ex() first argument must be a render_texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(rot_val) || !core.is_number(scale_val) {
			vm.runtime_error(v, "draw_render_texture_ex() x/y/rotation/scale arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "draw_render_texture_ex")
		if !ok {
			return false
		}
		target := render_texture_data_of(rt_val).render_texture.texture
		rl.DrawTextureEx(
			target,
			rl.Vector2{f32(core.as_float(x_val)), f32(core.as_float(y_val))},
			f32(core.as_float(rot_val)), f32(core.as_float(scale_val)),
			col,
		)
		result = core.NIL_VALUE

	case "draw_array":
		// Draws a float_array (each cell an RGB-encoded float, same
		// convention as gfx.encode_rgba/decode_rgba) one DrawPixel call
		// per cell, straight to whatever the current render target
		// already is -- unlike render_texture's own draw_array_fast, no
		// GPU texture is involved at all: a direct per-pixel loop, not a
		// bulk upload. Slower than draw_array_fast for anything but small
		// arrays.
		if arg_count != 1 {
			vm.runtime_error(v, "draw_array() expects 1 argument (float_array).")
			return false
		}
		arr_val := vm.peek(v, 0)
		if arr_val.type != .Obj || arr_val.obj_type != .Float_Array {
			vm.runtime_error(v, "draw_array() argument must be a float_array.")
			return false
		}
		arr := core.as_float_array(arr_val)
		for x in 0 ..< arr.width {
			for y in 0 ..< arr.height {
				f, _ := core.float_array_get(arr, x, y)
				packed := u32(f)
				col := rl.Color{u8((packed >> 16) & 0xFF), u8((packed >> 8) & 0xFF), u8(packed & 0xFF), 255}
				rl.DrawPixel(c.int(x), c.int(y), col)
			}
		}
		result = core.NIL_VALUE

	// --- 3D drawing (see .begin_3d()'s own doc comment for the mode
	// this requires being active) ---
	case "begin_3d":
		if arg_count != 1 {
			vm.runtime_error(v, "begin_3d() expects 1 argument (camera).")
			return false
		}
		cam_val := vm.peek(v, 0)
		if !is_camera_value(cam_val) {
			vm.runtime_error(v, "begin_3d() argument must be a camera.")
			return false
		}
		rl.BeginMode3D(camera_data_of(cam_val).camera)
		result = core.NIL_VALUE
	case "end_3d":
		if arg_count != 0 {
			vm.runtime_error(v, "end_3d() takes no arguments.")
			return false
		}
		rl.EndMode3D()
		result = core.NIL_VALUE
	case "cube":
		if arg_count != 3 {
			vm.runtime_error(v, "cube() expects 3 arguments (position, size, color).")
			return false
		}
		pos_val, size_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(size_val) {
			vm.runtime_error(v, "cube() position/size arguments must be vec3.")
			return false
		}
		col, ok := arg_color(v, col_val, "cube")
		if !ok {
			return false
		}
		pos, size := core.as_vec3(pos_val), core.as_vec3(size_val)
		rl.DrawCube(rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)}, f32(size.x), f32(size.y), f32(size.z), col)
		result = core.NIL_VALUE
	case "cube_wires":
		if arg_count != 3 {
			vm.runtime_error(v, "cube_wires() expects 3 arguments (position, size, color).")
			return false
		}
		pos_val, size_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(size_val) {
			vm.runtime_error(v, "cube_wires() position/size arguments must be vec3.")
			return false
		}
		col, ok := arg_color(v, col_val, "cube_wires")
		if !ok {
			return false
		}
		pos, size := core.as_vec3(pos_val), core.as_vec3(size_val)
		rl.DrawCubeWires(rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)}, f32(size.x), f32(size.y), f32(size.z), col)
		result = core.NIL_VALUE
	case "cube_rotated":
		// raylib has no DrawCube overload that takes a rotation -- draws
		// the window's own shared unit-cube mesh (window_cube_model) via
		// DrawMesh with a scale*rotate*translate transform instead.
		if arg_count != 5 {
			vm.runtime_error(v, "cube_rotated() expects 5 arguments (position, size, axis, angle, color).")
			return false
		}
		pos_val, size_val, axis_val, angle_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(size_val) || !core.is_vec3(axis_val) {
			vm.runtime_error(v, "cube_rotated() position/size/axis arguments must be vec3.")
			return false
		}
		if !core.is_number(angle_val) {
			vm.runtime_error(v, "cube_rotated() angle argument must be a number.")
			return false
		}
		col, ok := arg_color(v, col_val, "cube_rotated")
		if !ok {
			return false
		}
		pos, size, axis_v := core.as_vec3(pos_val), core.as_vec3(size_val), core.as_vec3(axis_val)
		mesh, material := window_cube_model(w)
		if w.shader_mode_active {
			// DrawMesh binds material.shader directly, not the global
			// state rl.BeginShaderMode sets -- see Window_Data's own doc
			// comment on shader_mode_active for why this is here.
			material.shader = w.active_shader
		}
		scale := rl.MatrixScale(f32(size.x), f32(size.y), f32(size.z))
		axis := rl.Vector3Normalize(rl.Vector3{f32(axis_v.x), f32(axis_v.y), f32(axis_v.z)})
		rotation := rl.MatrixRotate(axis, f32(core.as_float(angle_val)) * math.RAD_PER_DEG)
		translation := rl.MatrixTranslate(f32(pos.x), f32(pos.y), f32(pos.z))
		// raylib/OpenGL uses column-vector convention (confirmed directly
		// from Vector3Transform's own source: (m * v4).xyz -- matrix on
		// the left), so composing "scale, then rotate, then translate"
		// needs translation * rotation * scale: transform * v expands as
		// translation * (rotation * (scale * v)), applying scale to the
		// vertex first and translation last. The reverse order, scale *
		// rotation * translation, would apply translation to the mesh's
		// still-local-space vertices first, then rotate the whole
		// already-displaced object around the world origin instead of its
		// own center.
		transform := translation * rotation * scale
		material.maps[rl.MaterialMapIndex.ALBEDO].color = col
		rl.DrawMesh(mesh, material, transform)
		result = core.NIL_VALUE
	case "cube_wires_rotated":
		// rl.DrawCubeWires has no rotation parameter, and rendering the
		// shared solid mesh in wireframe polygon mode would also show its
		// internal triangle diagonals, not clean cube edges -- so this
		// transforms a unit cube's 8 corners directly and draws its 12
		// edges as lines instead (same transform composition as
		// cube_rotated above).
		if arg_count != 5 {
			vm.runtime_error(v, "cube_wires_rotated() expects 5 arguments (position, size, axis, angle, color).")
			return false
		}
		pos_val, size_val, axis_val, angle_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(size_val) || !core.is_vec3(axis_val) {
			vm.runtime_error(v, "cube_wires_rotated() position/size/axis arguments must be vec3.")
			return false
		}
		if !core.is_number(angle_val) {
			vm.runtime_error(v, "cube_wires_rotated() angle argument must be a number.")
			return false
		}
		col, ok := arg_color(v, col_val, "cube_wires_rotated")
		if !ok {
			return false
		}
		pos, size, axis_v := core.as_vec3(pos_val), core.as_vec3(size_val), core.as_vec3(axis_val)
		scale := rl.MatrixScale(f32(size.x), f32(size.y), f32(size.z))
		axis := rl.Vector3Normalize(rl.Vector3{f32(axis_v.x), f32(axis_v.y), f32(axis_v.z)})
		rotation := rl.MatrixRotate(axis, f32(core.as_float(angle_val)) * math.RAD_PER_DEG)
		translation := rl.MatrixTranslate(f32(pos.x), f32(pos.y), f32(pos.z))
		transform := translation * rotation * scale // see cube_rotated's own comment on this order
		corners := [8]rl.Vector3 {
			{-0.5, -0.5, -0.5}, {0.5, -0.5, -0.5}, {0.5, 0.5, -0.5}, {-0.5, 0.5, -0.5},
			{-0.5, -0.5, 0.5}, {0.5, -0.5, 0.5}, {0.5, 0.5, 0.5}, {-0.5, 0.5, 0.5},
		}
		for i in 0 ..< len(corners) {
			corners[i] = rl.Vector3Transform(corners[i], transform)
		}
		edges := [12][2]int{{0, 1}, {1, 2}, {2, 3}, {3, 0}, {4, 5}, {5, 6}, {6, 7}, {7, 4}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
		for e in edges {
			rl.DrawLine3D(corners[e[0]], corners[e[1]], col)
		}
		result = core.NIL_VALUE
	case "sphere":
		if arg_count != 3 {
			vm.runtime_error(v, "sphere() expects 3 arguments (center, radius, color).")
			return false
		}
		center_val, radius_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(center_val) {
			vm.runtime_error(v, "sphere() center argument must be a vec3.")
			return false
		}
		if !core.is_number(radius_val) {
			vm.runtime_error(v, "sphere() radius argument must be a number.")
			return false
		}
		col, ok := arg_color(v, col_val, "sphere")
		if !ok {
			return false
		}
		center := core.as_vec3(center_val)
		rl.DrawSphere(rl.Vector3{f32(center.x), f32(center.y), f32(center.z)}, f32(core.as_float(radius_val)), col)
		result = core.NIL_VALUE
	case "cylinder":
		if arg_count != 5 {
			vm.runtime_error(v, "cylinder() expects 5 arguments (position, radius_top, radius_bottom, height, color).")
			return false
		}
		pos_val, rtop_val, rbot_val, height_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) {
			vm.runtime_error(v, "cylinder() position argument must be a vec3.")
			return false
		}
		if !core.is_number(rtop_val) || !core.is_number(rbot_val) || !core.is_number(height_val) {
			vm.runtime_error(v, "cylinder() radius/height arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "cylinder")
		if !ok {
			return false
		}
		pos := core.as_vec3(pos_val)
		rl.DrawCylinder(
			rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)},
			f32(core.as_float(rtop_val)), f32(core.as_float(rbot_val)), f32(core.as_float(height_val)),
			16, col,
		)
		result = core.NIL_VALUE
	case "grid":
		if arg_count != 2 {
			vm.runtime_error(v, "grid() expects 2 arguments (slices, spacing).")
			return false
		}
		slices_val, spacing_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(slices_val) || !core.is_number(spacing_val) {
			vm.runtime_error(v, "grid() arguments must be numbers.")
			return false
		}
		rl.DrawGrid(c.int(core.as_int(slices_val)), f32(core.as_float(spacing_val)))
		result = core.NIL_VALUE
	case "plane":
		if arg_count != 3 {
			vm.runtime_error(v, "plane() expects 3 arguments (center, size, color).")
			return false
		}
		center_val, size_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(center_val) || !core.is_vec2(size_val) {
			vm.runtime_error(v, "plane() center must be a vec3 and size a vec2.")
			return false
		}
		col, ok := arg_color(v, col_val, "plane")
		if !ok {
			return false
		}
		center, size := core.as_vec3(center_val), core.as_vec2(size_val)
		rl.DrawPlane(rl.Vector3{f32(center.x), f32(center.y), f32(center.z)}, rl.Vector2{f32(size.x), f32(size.y)}, col)
		result = core.NIL_VALUE
	case "ellipse3":
		// Drawn as a flattened cylinder (near-zero height) -- raylib has
		// no dedicated 3D ellipse primitive.
		if arg_count != 4 {
			vm.runtime_error(v, "ellipse3() expects 4 arguments (center, radius_x, radius_z, color).")
			return false
		}
		center_val, rx_val, rz_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(center_val) {
			vm.runtime_error(v, "ellipse3() center argument must be a vec3.")
			return false
		}
		if !core.is_number(rx_val) || !core.is_number(rz_val) {
			vm.runtime_error(v, "ellipse3() radius arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "ellipse3")
		if !ok {
			return false
		}
		center := core.as_vec3(center_val)
		rl.DrawCylinder(
			rl.Vector3{f32(center.x), f32(center.y), f32(center.z)},
			f32(core.as_float(rx_val)), f32(core.as_float(rz_val)), 0.01,
			16, col,
		)
		result = core.NIL_VALUE
	case "triangle3":
		if arg_count != 10 {
			vm.runtime_error(v, "triangle3() expects 10 arguments (x1, y1, z1, x2, y2, z2, x3, y3, z3, color).")
			return false
		}
		x1, y1, z1, x2, y2, z2, x3, y3, z3, col_val :=
			vm.peek(v, 9), vm.peek(v, 8), vm.peek(v, 7), vm.peek(v, 6), vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x1) || !core.is_number(y1) || !core.is_number(z1) ||
		   !core.is_number(x2) || !core.is_number(y2) || !core.is_number(z2) ||
		   !core.is_number(x3) || !core.is_number(y3) || !core.is_number(z3) {
			vm.runtime_error(v, "triangle3() coordinate arguments must be numbers.")
			return false
		}
		col, ok := arg_color(v, col_val, "triangle3")
		if !ok {
			return false
		}
		rl.DrawTriangle3D(
			rl.Vector3{f32(core.as_float(x1)), f32(core.as_float(y1)), f32(core.as_float(z1))},
			rl.Vector3{f32(core.as_float(x2)), f32(core.as_float(y2)), f32(core.as_float(z2))},
			rl.Vector3{f32(core.as_float(x3)), f32(core.as_float(y3)), f32(core.as_float(z3))},
			col,
		)
		result = core.NIL_VALUE
	case "textured_cube":
		if arg_count != 4 {
			vm.runtime_error(v, "textured_cube() expects 4 arguments (texture, position, size, color).")
			return false
		}
		tex_val, pos_val, size_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		texture: rl.Texture2D
		if is_texture_value(tex_val) {
			texture = texture_data_of(tex_val).texture
		} else if is_render_texture_value(tex_val) {
			texture = render_texture_data_of(tex_val).render_texture.texture
		} else {
			vm.runtime_error(v, "textured_cube() first argument must be a texture or render_texture.")
			return false
		}
		if !core.is_vec3(pos_val) || !core.is_vec3(size_val) {
			vm.runtime_error(v, "textured_cube() position/size arguments must be vec3.")
			return false
		}
		col, ok := arg_color(v, col_val, "textured_cube")
		if !ok {
			return false
		}
		pos, size := core.as_vec3(pos_val), core.as_vec3(size_val)
		rl.BeginBlendMode(.ALPHA)
		draw_textured_cube(texture, rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)}, f32(size.x), f32(size.y), f32(size.z), col)
		rl.EndBlendMode()
		result = core.NIL_VALUE

	case:
		vm.runtime_error(v, "Undefined Window method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}

// window_constant answers a `win.KEY_*`/`win.MOUSE_*`/`win.BLEND_*`/
// `win.WRAP_*`/`win.FILTER_*`/`win.BATCH_*` property read, via
// window_vtable's get_property hook (vm/properties.odin's get_property
// .Userdata case). These are exposed directly on the window object
// rather than as module-level constants, so scripts access them as
// `win.KEY_SPACE`/`win.BLEND_ALPHA` etc., not `gfx.KEY_SPACE`. Full
// rl.KeyboardKey coverage except KEY_BACK/KEY_MENU (Android-only buttons
// not exposed by vendor:raylib's Odin binding); full rl.MouseButton/
// BLEND_*/WRAP_*/BATCH_* coverage. FILTER_* covers only POINT/BILINEAR
// (not TRILINEAR/ANISOTROPIC_*, which need mipmaps this codebase never
// generates). Values are plain immutable ints, identical across every
// Window instance, so this is a pure function of the name rather than
// per-object state.
@(private = "file")
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
	case "FILTER_POINT": return core.make_int_value(int(rl.TextureFilter.POINT), true), true
	case "FILTER_BILINEAR": return core.make_int_value(int(rl.TextureFilter.BILINEAR), true), true
	// Ordinal values match Batch_Primitive exactly (Cube=0, Sphere=1,
	// Triangle3=2, Circle3=3).
	case "BATCH_CUBE": return core.make_int_value(int(Batch_Primitive.Cube), true), true
	case "BATCH_SPHERE": return core.make_int_value(int(Batch_Primitive.Sphere), true), true
	case "BATCH_TRIANGLE3": return core.make_int_value(int(Batch_Primitive.Triangle3), true), true
	case "BATCH_CIRCLE3": return core.make_int_value(int(Batch_Primitive.Circle3), true), true
	// Ordinal values match Batch2D_Primitive exactly (Circle=0, Rect=1,
	// Triangle=2, Line=3).
	case "BATCH2D_CIRCLE": return core.make_int_value(int(Batch2D_Primitive.Circle), true), true
	case "BATCH2D_RECT": return core.make_int_value(int(Batch2D_Primitive.Rect), true), true
	case "BATCH2D_TRIANGLE": return core.make_int_value(int(Batch2D_Primitive.Triangle), true), true
	case "BATCH2D_LINE": return core.make_int_value(int(Batch2D_Primitive.Line), true), true
	case "MOUSE_LEFT": return core.make_int_value(int(rl.MouseButton.LEFT), true), true
	case "MOUSE_RIGHT": return core.make_int_value(int(rl.MouseButton.RIGHT), true), true
	case "MOUSE_MIDDLE": return core.make_int_value(int(rl.MouseButton.MIDDLE), true), true
	case "MOUSE_SIDE": return core.make_int_value(int(rl.MouseButton.SIDE), true), true
	case "MOUSE_EXTRA": return core.make_int_value(int(rl.MouseButton.EXTRA), true), true
	case "MOUSE_FORWARD": return core.make_int_value(int(rl.MouseButton.FORWARD), true), true
	case "MOUSE_BACK": return core.make_int_value(int(rl.MouseButton.BACK), true), true
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

// draw_textured_cube builds six manually-specified quads (raylib's
// DrawCube has no textured variant), each vertex carrying its own
// normal/texcoord/position via rlgl's immediate-mode API.
@(private = "file")
draw_textured_cube :: proc(texture: rl.Texture2D, position: rl.Vector3, width, height, length: f32, tint: rl.Color) {
	x, y, z := position.x, position.y, position.z

	rlgl.SetTexture(texture.id)
	rlgl.Begin(rlgl.QUADS)
	rlgl.Color4ub(tint.r, tint.g, tint.b, tint.a)

	// Front Face
	rlgl.Normal3f(0.0, 0.0, 1.0)
	rlgl.TexCoord2f(0.0, 0.0)
	rlgl.Vertex3f(x - width / 2, y - height / 2, z + length / 2)
	rlgl.TexCoord2f(1.0, 0.0)
	rlgl.Vertex3f(x + width / 2, y - height / 2, z + length / 2)
	rlgl.TexCoord2f(1.0, 1.0)
	rlgl.Vertex3f(x + width / 2, y + height / 2, z + length / 2)
	rlgl.TexCoord2f(0.0, 1.0)
	rlgl.Vertex3f(x - width / 2, y + height / 2, z + length / 2)

	// Back Face
	rlgl.Normal3f(0.0, 0.0, -1.0)
	rlgl.TexCoord2f(1.0, 0.0)
	rlgl.Vertex3f(x - width / 2, y - height / 2, z - length / 2)
	rlgl.TexCoord2f(1.0, 1.0)
	rlgl.Vertex3f(x - width / 2, y + height / 2, z - length / 2)
	rlgl.TexCoord2f(0.0, 1.0)
	rlgl.Vertex3f(x + width / 2, y + height / 2, z - length / 2)
	rlgl.TexCoord2f(0.0, 0.0)
	rlgl.Vertex3f(x + width / 2, y - height / 2, z - length / 2)

	// Top Face
	rlgl.Normal3f(0.0, 1.0, 0.0)
	rlgl.TexCoord2f(0.0, 1.0)
	rlgl.Vertex3f(x - width / 2, y + height / 2, z - length / 2)
	rlgl.TexCoord2f(0.0, 0.0)
	rlgl.Vertex3f(x - width / 2, y + height / 2, z + length / 2)
	rlgl.TexCoord2f(1.0, 0.0)
	rlgl.Vertex3f(x + width / 2, y + height / 2, z + length / 2)
	rlgl.TexCoord2f(1.0, 1.0)
	rlgl.Vertex3f(x + width / 2, y + height / 2, z - length / 2)

	// Bottom Face
	rlgl.Normal3f(0.0, -1.0, 0.0)
	rlgl.TexCoord2f(1.0, 1.0)
	rlgl.Vertex3f(x - width / 2, y - height / 2, z - length / 2)
	rlgl.TexCoord2f(0.0, 1.0)
	rlgl.Vertex3f(x + width / 2, y - height / 2, z - length / 2)
	rlgl.TexCoord2f(0.0, 0.0)
	rlgl.Vertex3f(x + width / 2, y - height / 2, z + length / 2)
	rlgl.TexCoord2f(1.0, 0.0)
	rlgl.Vertex3f(x - width / 2, y - height / 2, z + length / 2)

	// Right Face
	rlgl.Normal3f(1.0, 0.0, 0.0)
	rlgl.TexCoord2f(1.0, 0.0)
	rlgl.Vertex3f(x + width / 2, y - height / 2, z - length / 2)
	rlgl.TexCoord2f(1.0, 1.0)
	rlgl.Vertex3f(x + width / 2, y + height / 2, z - length / 2)
	rlgl.TexCoord2f(0.0, 1.0)
	rlgl.Vertex3f(x + width / 2, y + height / 2, z + length / 2)
	rlgl.TexCoord2f(0.0, 0.0)
	rlgl.Vertex3f(x + width / 2, y - height / 2, z + length / 2)

	// Left Face
	rlgl.Normal3f(-1.0, 0.0, 0.0)
	rlgl.TexCoord2f(0.0, 0.0)
	rlgl.Vertex3f(x - width / 2, y - height / 2, z - length / 2)
	rlgl.TexCoord2f(1.0, 0.0)
	rlgl.Vertex3f(x - width / 2, y - height / 2, z + length / 2)
	rlgl.TexCoord2f(1.0, 1.0)
	rlgl.Vertex3f(x - width / 2, y + height / 2, z + length / 2)
	rlgl.TexCoord2f(0.0, 1.0)
	rlgl.Vertex3f(x - width / 2, y + height / 2, z - length / 2)

	rlgl.End()
	rlgl.SetTexture(0)
}
