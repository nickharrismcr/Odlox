package natives

import "../core"
import "../vm"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"

// gfx_texture: Texture_Data (a GPU-loaded raylib texture, optionally
// sliced into equal-width horizontal animation frames) and
// Render_Texture_Data (an off-screen render target/FBO), construction,
// and method dispatch for both.

Texture_Data :: struct {
	width, height:   int,
	texture:         rl.Texture2D,
	frames:          int,
	frame_width:     int,
	start_frame:     int,
	end_frame:       int,
	frame_rects:     [dynamic]rl.Rectangle,
	ticks_per_frame: int, // 0 means no animation
	ticks:           int, // ticks since last frame change
	current_frame:   int,
	freed:           bool, // idempotent-unload guard, shared by .unload() and GC
	owns_texture:    bool, // false for texture_data_from_texture2d -- see its own doc comment
}

// Render_Texture_Data wraps a raylib off-screen render target (an FBO),
// including a persistent array_texture used by draw_array_fast:
// recreating (Load/Unload) a texture every frame races with the GPU
// driver's double-buffered pipeline -- the new texture can reuse an ID
// still referenced by an in-flight draw from the previous frame,
// producing stray stale-colour pixels. Updating one long-lived texture
// in place avoids that.
Render_Texture_Data :: struct {
	width, height:  int,
	render_texture: rl.RenderTexture2D,
	freed:          bool, // idempotent-unload guard, same convention as Texture_Data

	array_texture:       rl.Texture2D,
	array_texture_w:     int,
	array_texture_h:     int,
	array_texture_valid: bool,
}

@(private = "file")
texture_vtable := core.Userdata_Vtable {
	tag       = "Texture",
	free      = texture_data_free,
	to_string = texture_to_string,
	size      = texture_data_size,
	invoke    = texture_invoke,
}

@(private = "file")
render_texture_vtable := core.Userdata_Vtable {
	tag       = "RenderTexture",
	free      = render_texture_data_free,
	to_string = render_texture_to_string,
	size      = render_texture_data_size,
	invoke    = render_texture_invoke,
}

@(private = "file")
texture_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	t := cast(^Texture_Data)data
	return fmt.aprintf("<Texture %dx%d>", t.width, t.height, allocator = allocator)
}

@(private = "file")
texture_data_size :: proc(data: rawptr) -> int {
	t := cast(^Texture_Data)data
	return size_of(Texture_Data) + len(t.frame_rects) * size_of(rl.Rectangle)
}

@(private = "file")
render_texture_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	rt := cast(^Render_Texture_Data)data
	return fmt.aprintf("<RenderTexture %dx%d>", rt.width, rt.height, allocator = allocator)
}

// Dominated by the optional array_texture (draw_array_fast) when
// present -- a fullscreen fractal, say -- same reasoning as
// Image/Texture above.
@(private = "file")
render_texture_data_size :: proc(data: rawptr) -> int {
	rt := cast(^Render_Texture_Data)data
	size := size_of(Render_Texture_Data)
	if rt.array_texture_valid {
		size += rt.array_texture_w * rt.array_texture_h * 4
	}
	return size
}

// is_texture_value/texture_data_of: package-private -- gfx_batch_instanced,
// gfx.odin's own batch_instanced() constructor, and gfx_window.odin all
// need to check "is this argument a Texture" and unwrap it.
@(private)
is_texture_value :: proc(v: core.Value) -> bool {
	return v.type == .Obj && v.obj_type == .Userdata && core.as_userdata(v).vtable == &texture_vtable
}

@(private)
texture_data_of :: proc(v: core.Value) -> ^Texture_Data {
	return cast(^Texture_Data)core.as_userdata(v).data
}

@(private)
is_render_texture_value :: proc(v: core.Value) -> bool {
	return v.type == .Obj && v.obj_type == .Userdata && core.as_userdata(v).vtable == &render_texture_vtable
}

@(private)
render_texture_data_of :: proc(v: core.Value) -> ^Render_Texture_Data {
	return cast(^Render_Texture_Data)core.as_userdata(v).data
}

@(private = "file")
make_texture_data :: proc(image: rl.Image, frames, start_frame, end_frame: int) -> ^Texture_Data {
	texture := rl.LoadTextureFromImage(image)
	w, h := int(texture.width), int(texture.height)

	data := new(Texture_Data)
	data.width = w
	data.height = h
	data.texture = texture
	data.frames = frames
	data.frame_width = w / frames
	data.start_frame = start_frame
	data.end_frame = end_frame
	data.owns_texture = true
	for f := start_frame; f <= end_frame; f += 1 {
		x1 := f32((f - 1) * data.frame_width)
		append(&data.frame_rects, rl.Rectangle{x1, 0, f32(data.frame_width), f32(h)})
	}
	return data
}

// texture_data_from_texture2d wraps an already-loaded GPU texture this
// Texture_Data does *not* own (e.g. render_texture.get_texture() pulling
// out the render_texture's own live rl.Texture2D) as a single-frame,
// non-animated Texture_Data. owns_texture is left false, so
// texture_unload below never calls rl.UnloadTexture on it: a script that
// calls get_texture() every frame makes the previous frame's wrapper
// unreachable and GC-collectible, and without owns_texture, reaping one
// of these transient wrappers would unload the render_texture's own
// shared GPU texture out from under it.
@(private = "file")
texture_data_from_texture2d :: proc(texture: rl.Texture2D) -> ^Texture_Data {
	w, h := int(texture.width), int(texture.height)
	data := new(Texture_Data)
	data.width = w
	data.height = h
	data.texture = texture
	data.frames = 1
	data.frame_width = w
	data.start_frame = 1
	data.end_frame = 1
	data.owns_texture = false
	append(&data.frame_rects, rl.Rectangle{0, 0, f32(w), f32(h)})
	return data
}

// texture_frame_rect/texture_animate: package-private since
// gfx_window.odin's draw_texture-family methods need them too.
@(private)
texture_frame_rect :: proc(t: ^Texture_Data) -> rl.Rectangle {
	return t.frame_rects[t.current_frame]
}

@(private)
texture_animate :: proc(t: ^Texture_Data) {
	if t.ticks_per_frame == 0 {
		return
	}
	t.ticks += 1
	if t.ticks == t.ticks_per_frame {
		t.ticks = 0
		t.current_frame = (t.current_frame + 1) % t.frames
	}
}

// texture_unload is the single place GPU teardown for a texture
// happens -- shared by the Lox-visible unload() method and GC-triggered
// cleanup, guarded by freed so whichever runs first wins, not a double
// UnloadTexture. A borrowed texture (owns_texture == false, see
// texture_data_from_texture2d) never calls rl.UnloadTexture at all --
// the GPU resource belongs to whatever created it (a render_texture, so
// far), and unloading it here would destroy that owner's still-live
// texture out from under it. freed is still set either way, so a script
// calling .unload() on a borrowed Texture is a harmless no-op rather
// than an error.
@(private = "file")
texture_unload :: proc(t: ^Texture_Data) {
	if t.freed {
		return
	}
	t.freed = true
	if t.owns_texture {
		rl.UnloadTexture(t.texture)
	}
}

@(private = "file")
texture_data_free :: proc(data: rawptr) {
	t := cast(^Texture_Data)data
	texture_unload(t)
	delete(t.frame_rects)
	free(t)
}

@(private = "file")
render_texture_unload :: proc(rt: ^Render_Texture_Data) {
	if rt.freed {
		return
	}
	rt.freed = true
	rl.UnloadRenderTexture(rt.render_texture)
	if rt.array_texture_valid {
		rl.UnloadTexture(rt.array_texture)
	}
}

@(private = "file")
render_texture_data_free :: proc(data: rawptr) {
	render_texture_unload(cast(^Render_Texture_Data)data)
	free(data)
}

// gfx_texture uploads an already-loaded Image to the GPU, optionally
// sliced into `frames` equal-width horizontal animation frames. Requires
// a window to already exist (see window_created's doc comment in
// gfx.odin).
@(private)
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
	if !is_image_value(img_val) {
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
	img := image_data_of(img_val)
	data := make_texture_data(img.image, frames, start_frame, end_frame)
	o := core.make_userdata_object(&texture_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private)
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
	width, height := core.as_int(w_val), core.as_int(h_val)
	data := new(Render_Texture_Data)
	data.width = width
	data.height = height
	data.render_texture = rl.LoadRenderTexture(i32(width), i32(height))
	o := core.make_userdata_object(&render_texture_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
texture_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	t := cast(^Texture_Data)data
	result: core.Value
	switch name {
	case "width":
		if arg_count != 0 {
			vm.runtime_error(v, "width() takes no arguments.")
			return false
		}
		result = core.make_int_value(t.width, true)
	case "height":
		if arg_count != 0 {
			vm.runtime_error(v, "height() takes no arguments.")
			return false
		}
		result = core.make_int_value(t.height, true)
	case "frame_width":
		if arg_count != 0 {
			vm.runtime_error(v, "frame_width() takes no arguments.")
			return false
		}
		result = core.make_int_value(t.frame_width, true)
	case "animate":
		if arg_count != 1 {
			vm.runtime_error(v, "animate() expects 1 argument (ticks_per_frame).")
			return false
		}
		ticks_val := vm.peek(v, 0)
		if !core.is_number(ticks_val) {
			vm.runtime_error(v, "animate() argument must be a number.")
			return false
		}
		t.ticks_per_frame = core.as_int(ticks_val)
		result = core.NIL_VALUE
	case "set_wrap_mode":
		if arg_count != 1 {
			vm.runtime_error(v, "set_wrap_mode() expects 1 argument (wrap_mode).")
			return false
		}
		wrap_val := vm.peek(v, 0)
		if !core.is_number(wrap_val) {
			vm.runtime_error(v, "set_wrap_mode() argument must be a number.")
			return false
		}
		rl.SetTextureWrap(t.texture, rl.TextureWrap(core.as_int(wrap_val)))
		result = core.NIL_VALUE
	case "unload":
		if arg_count != 0 {
			vm.runtime_error(v, "unload() takes no arguments.")
			return false
		}
		texture_unload(t)
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Undefined Texture method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}

// render_texture_invoke: width/height/unload, a mirror of Window's own
// 2D primitive set (clear/pixel/line/line_ex/triangle/rectangle/circle/
// circle_fill/text/draw_texture), letting a script draw directly onto a
// render_texture the same way it draws onto the window, not only via
// win.begin_texture_mode/end_texture_mode/win.<primitive> (still
// supported separately in gfx_window.odin) -- plus
// get_texture()/draw_texture_pro() and draw_array_fast() for
// bulk-uploading a computed float_array into a render_texture every
// frame. Each drawing call here brackets *just that one draw* in its own
// BeginTextureMode/EndTextureMode, not a persistent mode switch -- unlike
// Window's own drawing methods, which draw against whatever the current
// global GL target already is. text() is narrower than Window's own:
// (x, y, string) only, fixed font size 10, hardcoded white, not Window's
// (string, x, y, size, color).
@(private = "file")
render_texture_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	rt := cast(^Render_Texture_Data)data
	result: core.Value
	switch name {
	case "width":
		if arg_count != 0 {
			vm.runtime_error(v, "width() takes no arguments.")
			return false
		}
		result = core.make_int_value(rt.width, true)
	case "height":
		if arg_count != 0 {
			vm.runtime_error(v, "height() takes no arguments.")
			return false
		}
		result = core.make_int_value(rt.height, true)
	case "unload":
		if arg_count != 0 {
			vm.runtime_error(v, "unload() takes no arguments.")
			return false
		}
		render_texture_unload(rt)
		result = core.NIL_VALUE
	case "clear":
		if arg_count != 1 {
			vm.runtime_error(v, "clear() expects 1 argument (color).")
			return false
		}
		col, ok := arg_color(v, vm.peek(v, 0), "clear")
		if !ok {
			return false
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.ClearBackground(col)
		rl.EndTextureMode()
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
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawPixel(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), col)
		rl.EndTextureMode()
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
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawLineEx(p1, p2, f32(core.as_float(thick_val)), col)
		rl.EndTextureMode()
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
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawTriangle(p1, p2, p3, col)
		rl.EndTextureMode()
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
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawCircleLines(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
		rl.EndTextureMode()
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
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawCircle(c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), f32(core.as_float(r_val)), col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "text":
		// Narrower than Window's own text(): (x, y, string) only, fixed
		// font size 10, hardcoded white, not Window's
		// (string, x, y, size, color) shape.
		if arg_count != 3 {
			vm.runtime_error(v, "text() expects 3 arguments (x, y, text).")
			return false
		}
		x_val, y_val, text_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(x_val) || !core.is_number(y_val) {
			vm.runtime_error(v, "text() x/y arguments must be numbers.")
			return false
		}
		if !core.is_string(text_val) {
			vm.runtime_error(v, "text() third argument must be a string.")
			return false
		}
		ctext := strings.clone_to_cstring(core.string_get(core.as_string(text_val)))
		defer delete(ctext)
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawText(ctext, c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), 10, rl.WHITE)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "draw_texture":
		// Narrower than Window's own draw_texture: 3 args (texture, x, y),
		// always tinted rl.White, no frame-rect/animation support at all.
		if arg_count != 3 {
			vm.runtime_error(v, "draw_texture() expects 3 arguments (texture, x, y).")
			return false
		}
		tex_val, x_val, y_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !is_texture_value(tex_val) {
			vm.runtime_error(v, "draw_texture() first argument must be a texture.")
			return false
		}
		if !core.is_number(x_val) || !core.is_number(y_val) {
			vm.runtime_error(v, "draw_texture() x/y arguments must be numbers.")
			return false
		}
		t := texture_data_of(tex_val)
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawTexture(t.texture, c.int(int(core.as_float(x_val))), c.int(int(core.as_float(y_val))), rl.WHITE)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "get_texture":
		// A pixel readback (LoadImageFromTexture/UnloadImage, result
		// discarded) forces the GPU driver to finish any prior writes to
		// this render texture before the caller starts sampling it
		// elsewhere. This render texture's own drawing methods each open
		// and close their own texture-mode context, so without an
		// explicit sync point here the GPU can still be mid-flight on
		// those writes when the returned Texture starts getting drawn
		// from -- relevant for a script that re-samples a live-painted
		// canvas into a texture every frame.
		if arg_count != 0 {
			vm.runtime_error(v, "get_texture() takes no arguments.")
			return false
		}
		sync_img := rl.LoadImageFromTexture(rt.render_texture.texture)
		rl.UnloadImage(sync_img)
		tdata := texture_data_from_texture2d(rt.render_texture.texture)
		o := core.make_userdata_object(&texture_vtable, tdata)
		vm.gc_track(v, &o.obj)
		result = core.make_object_value(&o.obj, true)
	case "draw_texture_pro":
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
		if !is_texture_value(tex_val) {
			vm.runtime_error(v, "draw_texture_pro() first argument must be a texture.")
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
		t := texture_data_of(tex_val)
		src := rl.Rectangle{f32(core.as_float(src_x)), f32(core.as_float(src_y)), f32(core.as_float(src_w)), f32(core.as_float(src_h))}
		dst := rl.Rectangle{f32(core.as_float(dst_x)), f32(core.as_float(dst_y)), f32(core.as_float(dst_w)), f32(core.as_float(dst_h))}
		origin := rl.Vector2{f32(core.as_float(org_x)), f32(core.as_float(org_y))}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawTexturePro(t.texture, src, dst, origin, f32(core.as_float(rot_val)), col)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case "draw_array_fast":
		// Bulk-uploads a float_array (each cell a packed-RGB float, same
		// encoding as gfx.encode_rgba/decode_rgba) as one texture and
		// blits it in a single draw, instead of one draw call per cell --
		// useful for a script that rewrites an entire computed image
		// every frame. Reuses rt's own array_texture across calls (Load
		// only on the first call or a size change; Update otherwise)
		// rather than loading/unloading a fresh GPU texture every frame --
		// see Render_Texture_Data's own doc comment for why that
		// specifically matters here (a driver race, not just a
		// performance nicety).
		if arg_count != 1 {
			vm.runtime_error(v, "draw_array_fast() expects 1 argument (float_array).")
			return false
		}
		arr_val := vm.peek(v, 0)
		if arr_val.type != .Obj || arr_val.obj_type != .Float_Array {
			vm.runtime_error(v, "draw_array_fast() argument must be a float_array.")
			return false
		}
		arr := core.as_float_array(arr_val)
		pixels := make([]rl.Color, arr.width * arr.height)
		defer delete(pixels)
		for f, i in arr.data {
			packed := u32(f)
			pixels[i] = rl.Color{u8((packed >> 16) & 0xFF), u8((packed >> 8) & 0xFF), u8(packed & 0xFF), 255}
		}
		if !rt.array_texture_valid || rt.array_texture_w != arr.width || rt.array_texture_h != arr.height {
			if rt.array_texture_valid {
				rl.UnloadTexture(rt.array_texture)
			}
			img := rl.Image {
				data    = raw_data(pixels),
				width   = c.int(arr.width),
				height  = c.int(arr.height),
				mipmaps = 1,
				format  = .UNCOMPRESSED_R8G8B8A8,
			}
			rt.array_texture = rl.LoadTextureFromImage(img)
			rt.array_texture_w = arr.width
			rt.array_texture_h = arr.height
			rt.array_texture_valid = true
		} else {
			rl.UpdateTexture(rt.array_texture, raw_data(pixels))
		}
		rl.BeginTextureMode(rt.render_texture)
		rl.DrawTexture(rt.array_texture, 0, 0, rl.WHITE)
		rl.EndTextureMode()
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Undefined RenderTexture method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
