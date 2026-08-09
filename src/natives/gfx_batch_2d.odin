package natives

import "../core"
import "../vm"
import "core:fmt"
import "core:mem"
import rl "vendor:raylib"

// gfx_batch_2d: Batch2D_Data accumulates many same-kind 2D primitives
// (filled circles, axis-aligned rects, triangles, or line segments) and
// draws them all in one .draw() call instead of one native-method-
// dispatch round trip (win.circle_fill/rectangle/triangle/line_ex) per
// primitive per frame -- the 2D counterpart to gfx_batch.odin's 3D
// Batch_Data. Positions/sizes are vec2, colors vec4, matching gfx_batch's
// own vec3/vec4 add() convention rather than window primitives' raw
// x/y/w/h floats.

// Batch2D_Primitive: package-private since gfx_window.odin's
// window_constant (win.BATCH2D_CIRCLE etc.) and gfx.odin's batch2d()
// constructor both need it.
@(private)
Batch2D_Primitive :: enum {
	Circle,
	Rect,
	Triangle,
	Line,
}

// Rect entries are axis-aligned only -- no per-entry rotation, same
// restriction as Batch_Entry's Cube/Sphere case in gfx_batch.odin.
Circle2D_Batch_Entry :: struct {
	position: rl.Vector2,
	radius:   f32,
	color:    rl.Color,
}

Rect_Batch_Entry :: struct {
	position: rl.Vector2, // top-left
	size:     rl.Vector2, // width, height
	color:    rl.Color,
}

Triangle2D_Batch_Entry :: struct {
	point1, point2, point3: rl.Vector2,
	color:                  rl.Color,
}

Line_Batch_Entry :: struct {
	point1, point2: rl.Vector2,
	thickness:      f32,
	color:          rl.Color,
}

Batch2D_Data :: struct {
	batch_type: Batch2D_Primitive,
	circles:    [dynamic]Circle2D_Batch_Entry,
	rects:      [dynamic]Rect_Batch_Entry,
	triangles:  [dynamic]Triangle2D_Batch_Entry,
	lines:      [dynamic]Line_Batch_Entry,
}

@(private = "file")
batch2d_vtable := core.Userdata_Vtable {
	tag       = "Batch2D",
	free      = batch2d_data_free,
	to_string = batch2d_to_string,
	size      = batch2d_data_size,
	invoke    = batch2d_invoke,
}

@(private = "file")
batch2d_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	b := cast(^Batch2D_Data)data
	type_name := "CIRCLE"
	#partial switch b.batch_type {
	case .Rect: type_name = "RECT"
	case .Triangle: type_name = "TRIANGLE"
	case .Line: type_name = "LINE"
	}
	return fmt.aprintf("<Batch2D %s [%d entries]>", type_name, batch2d_count(b), allocator = allocator)
}

@(private = "file")
batch2d_data_size :: proc(data: rawptr) -> int {
	b := cast(^Batch2D_Data)data
	return size_of(Batch2D_Data) +
		len(b.circles) * size_of(Circle2D_Batch_Entry) +
		len(b.rects) * size_of(Rect_Batch_Entry) +
		len(b.triangles) * size_of(Triangle2D_Batch_Entry) +
		len(b.lines) * size_of(Line_Batch_Entry)
}

@(private = "file")
batch2d_data_free :: proc(data: rawptr) {
	b := cast(^Batch2D_Data)data
	delete(b.circles)
	delete(b.rects)
	delete(b.triangles)
	delete(b.lines)
	free(b)
}

@(private = "file")
batch2d_add_circle :: proc(b: ^Batch2D_Data, pos: core.Vec2, radius: f64, color: core.Vec4) -> int {
	append(&b.circles, Circle2D_Batch_Entry{
		position = rl.Vector2{f32(pos.x), f32(pos.y)},
		radius   = f32(radius),
		color    = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.circles) - 1
}

@(private = "file")
batch2d_add_rect :: proc(b: ^Batch2D_Data, pos, size: core.Vec2, color: core.Vec4) -> int {
	append(&b.rects, Rect_Batch_Entry{
		position = rl.Vector2{f32(pos.x), f32(pos.y)},
		size     = rl.Vector2{f32(size.x), f32(size.y)},
		color    = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.rects) - 1
}

@(private = "file")
batch2d_add_triangle :: proc(b: ^Batch2D_Data, p1, p2, p3: core.Vec2, color: core.Vec4) -> int {
	append(&b.triangles, Triangle2D_Batch_Entry{
		point1 = rl.Vector2{f32(p1.x), f32(p1.y)},
		point2 = rl.Vector2{f32(p2.x), f32(p2.y)},
		point3 = rl.Vector2{f32(p3.x), f32(p3.y)},
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.triangles) - 1
}

@(private = "file")
batch2d_add_line :: proc(b: ^Batch2D_Data, p1, p2: core.Vec2, thickness: f64, color: core.Vec4) -> int {
	append(&b.lines, Line_Batch_Entry{
		point1    = rl.Vector2{f32(p1.x), f32(p1.y)},
		point2    = rl.Vector2{f32(p2.x), f32(p2.y)},
		thickness = f32(thickness),
		color     = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.lines) - 1
}

@(private = "file")
batch2d_set_circle_full :: proc(b: ^Batch2D_Data, index: int, pos: core.Vec2, radius: f64, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.circles) {
		return false
	}
	b.circles[index] = Circle2D_Batch_Entry{
		position = rl.Vector2{f32(pos.x), f32(pos.y)},
		radius   = f32(radius),
		color    = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	}
	return true
}

@(private = "file")
batch2d_set_circle_color :: proc(b: ^Batch2D_Data, index: int, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.circles) {
		return false
	}
	b.circles[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

@(private = "file")
batch2d_set_rect_full :: proc(b: ^Batch2D_Data, index: int, pos, size: core.Vec2, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.rects) {
		return false
	}
	b.rects[index] = Rect_Batch_Entry{
		position = rl.Vector2{f32(pos.x), f32(pos.y)},
		size     = rl.Vector2{f32(size.x), f32(size.y)},
		color    = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	}
	return true
}

@(private = "file")
batch2d_set_rect_color :: proc(b: ^Batch2D_Data, index: int, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.rects) {
		return false
	}
	b.rects[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

@(private = "file")
batch2d_set_triangle_full :: proc(b: ^Batch2D_Data, index: int, p1, p2, p3: core.Vec2, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.triangles) {
		return false
	}
	b.triangles[index] = Triangle2D_Batch_Entry{
		point1 = rl.Vector2{f32(p1.x), f32(p1.y)},
		point2 = rl.Vector2{f32(p2.x), f32(p2.y)},
		point3 = rl.Vector2{f32(p3.x), f32(p3.y)},
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	}
	return true
}

@(private = "file")
batch2d_set_triangle_color :: proc(b: ^Batch2D_Data, index: int, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.triangles) {
		return false
	}
	b.triangles[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

@(private = "file")
batch2d_set_line_full :: proc(b: ^Batch2D_Data, index: int, p1, p2: core.Vec2, thickness: f64, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.lines) {
		return false
	}
	b.lines[index] = Line_Batch_Entry{
		point1    = rl.Vector2{f32(p1.x), f32(p1.y)},
		point2    = rl.Vector2{f32(p2.x), f32(p2.y)},
		thickness = f32(thickness),
		color     = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	}
	return true
}

@(private = "file")
batch2d_set_line_color :: proc(b: ^Batch2D_Data, index: int, color: core.Vec4) -> bool {
	if index < 0 || index >= len(b.lines) {
		return false
	}
	b.lines[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

@(private = "file")
batch2d_is_valid_index :: proc(b: ^Batch2D_Data, index: int) -> bool {
	switch b.batch_type {
	case .Circle: return index >= 0 && index < len(b.circles)
	case .Rect: return index >= 0 && index < len(b.rects)
	case .Triangle: return index >= 0 && index < len(b.triangles)
	case .Line: return index >= 0 && index < len(b.lines)
	}
	return false
}

@(private = "file")
batch2d_clear :: proc(b: ^Batch2D_Data) {
	clear(&b.circles)
	clear(&b.rects)
	clear(&b.triangles)
	clear(&b.lines)
}

@(private = "file")
batch2d_reserve :: proc(b: ^Batch2D_Data, capacity: int) {
	switch b.batch_type {
	case .Circle:
		if capacity > len(b.circles) {
			reserve(&b.circles, capacity)
		}
	case .Rect:
		if capacity > len(b.rects) {
			reserve(&b.rects, capacity)
		}
	case .Triangle:
		if capacity > len(b.triangles) {
			reserve(&b.triangles, capacity)
		}
	case .Line:
		if capacity > len(b.lines) {
			reserve(&b.lines, capacity)
		}
	}
}

@(private = "file")
batch2d_count :: proc(b: ^Batch2D_Data) -> int {
	switch b.batch_type {
	case .Circle: return len(b.circles)
	case .Rect: return len(b.rects)
	case .Triangle: return len(b.triangles)
	case .Line: return len(b.lines)
	}
	return 0
}

// batch2d_draw renders every entry in the batch. Unlike gfx_batch's
// BATCH_CIRCLE3, no rlgl render-batch flush/depth-mask dance is needed
// here -- these are all plain 2D immediate-mode draws (rlgl triangle
// fans/quads against the default white texture), the same kind rlgl
// already coalesces into one GPU submission on its own when state
// doesn't change between calls. What this collapses is the Lox-VM-to-
// native call boundary (one native dispatch per entry becomes one
// dispatch for the whole batch), not the GPU draw-call count itself.
@(private = "file")
batch2d_draw :: proc(b: ^Batch2D_Data) {
	switch b.batch_type {
	case .Circle:
		for e in b.circles {
			rl.DrawCircleV(e.position, e.radius, e.color)
		}
	case .Rect:
		for e in b.rects {
			rl.DrawRectangleV(e.position, e.size, e.color)
		}
	case .Triangle:
		for e in b.triangles {
			rl.DrawTriangle(e.point1, e.point2, e.point3, e.color)
		}
	case .Line:
		for e in b.lines {
			rl.DrawLineEx(e.point1, e.point2, e.thickness, e.color)
		}
	}
}

// gfx_batch_2d: the single argument is a win.BATCH2D_* constant (a plain
// int -- see gfx_window.odin's window_constant for Batch2D_Primitive's
// ordinal values), not validated against a fixed enum range here, same
// as gfx_batch's own win.BATCH_* argument.
@(private)
gfx_batch_2d :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "batch2d() expects 1 argument (a win.BATCH2D_* constant).")
		return core.NIL_VALUE
	}
	type_val := v.stack[arg_stack_ptr]
	if !core.is_int(type_val) {
		vm.runtime_error(v, "batch2d() argument must be a win.BATCH2D_* constant.")
		return core.NIL_VALUE
	}
	data := new(Batch2D_Data)
	data.batch_type = Batch2D_Primitive(core.as_int(type_val))
	o := core.make_userdata_object(&batch2d_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
batch2d_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	b := cast(^Batch2D_Data)data
	result: core.Value
	switch name {
	case "add_circle":
		if b.batch_type != .Circle {
			vm.runtime_error(v, "add_circle() can only be used with a BATCH2D_CIRCLE batch.")
			return false
		}
		if arg_count != 3 {
			vm.runtime_error(v, "add_circle() expects 3 arguments (position, radius, color).")
			return false
		}
		pos_val, radius_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec2(pos_val) || !core.is_number(radius_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "add_circle() expects (vec2 position, number radius, vec4 color).")
			return false
		}
		idx := batch2d_add_circle(b, core.as_vec2(pos_val), core.as_float(radius_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "add_rect":
		if b.batch_type != .Rect {
			vm.runtime_error(v, "add_rect() can only be used with a BATCH2D_RECT batch.")
			return false
		}
		if arg_count != 3 {
			vm.runtime_error(v, "add_rect() expects 3 arguments (position, size, color).")
			return false
		}
		pos_val, size_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec2(pos_val) || !core.is_vec2(size_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "add_rect() expects (vec2 position, vec2 size, vec4 color).")
			return false
		}
		idx := batch2d_add_rect(b, core.as_vec2(pos_val), core.as_vec2(size_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "add_triangle":
		if b.batch_type != .Triangle {
			vm.runtime_error(v, "add_triangle() can only be used with a BATCH2D_TRIANGLE batch.")
			return false
		}
		if arg_count != 4 {
			vm.runtime_error(v, "add_triangle() expects 4 arguments (point1, point2, point3, color).")
			return false
		}
		p1_val, p2_val, p3_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec2(p1_val) || !core.is_vec2(p2_val) || !core.is_vec2(p3_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "add_triangle() expects (vec2, vec2, vec2, vec4 color).")
			return false
		}
		idx := batch2d_add_triangle(b, core.as_vec2(p1_val), core.as_vec2(p2_val), core.as_vec2(p3_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "add_line":
		if b.batch_type != .Line {
			vm.runtime_error(v, "add_line() can only be used with a BATCH2D_LINE batch.")
			return false
		}
		if arg_count != 4 {
			vm.runtime_error(v, "add_line() expects 4 arguments (point1, point2, thickness, color).")
			return false
		}
		p1_val, p2_val, thick_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec2(p1_val) || !core.is_vec2(p2_val) || !core.is_number(thick_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "add_line() expects (vec2 point1, vec2 point2, number thickness, vec4 color).")
			return false
		}
		idx := batch2d_add_line(b, core.as_vec2(p1_val), core.as_vec2(p2_val), core.as_float(thick_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "set_circle_full":
		if b.batch_type != .Circle {
			vm.runtime_error(v, "set_circle_full() can only be used with a BATCH2D_CIRCLE batch.")
			return false
		}
		if arg_count != 4 {
			vm.runtime_error(v, "set_circle_full() expects 4 arguments (index, position, radius, color).")
			return false
		}
		idx_val, pos_val, radius_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec2(pos_val) || !core.is_number(radius_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_circle_full() expects (int index, vec2 position, number radius, vec4 color).")
			return false
		}
		if !batch2d_set_circle_full(b, core.as_int(idx_val), core.as_vec2(pos_val), core.as_float(radius_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_circle_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_circle_color":
		if b.batch_type != .Circle {
			vm.runtime_error(v, "set_circle_color() can only be used with a BATCH2D_CIRCLE batch.")
			return false
		}
		if arg_count != 2 {
			vm.runtime_error(v, "set_circle_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_circle_color() expects (int index, vec4 color).")
			return false
		}
		if !batch2d_set_circle_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_circle_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_rect_full":
		if b.batch_type != .Rect {
			vm.runtime_error(v, "set_rect_full() can only be used with a BATCH2D_RECT batch.")
			return false
		}
		if arg_count != 4 {
			vm.runtime_error(v, "set_rect_full() expects 4 arguments (index, position, size, color).")
			return false
		}
		idx_val, pos_val, size_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec2(pos_val) || !core.is_vec2(size_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_rect_full() expects (int index, vec2 position, vec2 size, vec4 color).")
			return false
		}
		if !batch2d_set_rect_full(b, core.as_int(idx_val), core.as_vec2(pos_val), core.as_vec2(size_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_rect_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_rect_color":
		if b.batch_type != .Rect {
			vm.runtime_error(v, "set_rect_color() can only be used with a BATCH2D_RECT batch.")
			return false
		}
		if arg_count != 2 {
			vm.runtime_error(v, "set_rect_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_rect_color() expects (int index, vec4 color).")
			return false
		}
		if !batch2d_set_rect_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_rect_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_triangle_full":
		if b.batch_type != .Triangle {
			vm.runtime_error(v, "set_triangle_full() can only be used with a BATCH2D_TRIANGLE batch.")
			return false
		}
		if arg_count != 5 {
			vm.runtime_error(v, "set_triangle_full() expects 5 arguments (index, point1, point2, point3, color).")
			return false
		}
		idx_val, p1_val, p2_val, p3_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec2(p1_val) || !core.is_vec2(p2_val) || !core.is_vec2(p3_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_triangle_full() expects (int index, vec2, vec2, vec2, vec4 color).")
			return false
		}
		if !batch2d_set_triangle_full(b, core.as_int(idx_val), core.as_vec2(p1_val), core.as_vec2(p2_val), core.as_vec2(p3_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_triangle_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_triangle_color":
		if b.batch_type != .Triangle {
			vm.runtime_error(v, "set_triangle_color() can only be used with a BATCH2D_TRIANGLE batch.")
			return false
		}
		if arg_count != 2 {
			vm.runtime_error(v, "set_triangle_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_triangle_color() expects (int index, vec4 color).")
			return false
		}
		if !batch2d_set_triangle_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_triangle_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_line_full":
		if b.batch_type != .Line {
			vm.runtime_error(v, "set_line_full() can only be used with a BATCH2D_LINE batch.")
			return false
		}
		if arg_count != 5 {
			vm.runtime_error(v, "set_line_full() expects 5 arguments (index, point1, point2, thickness, color).")
			return false
		}
		idx_val, p1_val, p2_val, thick_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec2(p1_val) || !core.is_vec2(p2_val) || !core.is_number(thick_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_line_full() expects (int index, vec2 point1, vec2 point2, number thickness, vec4 color).")
			return false
		}
		if !batch2d_set_line_full(b, core.as_int(idx_val), core.as_vec2(p1_val), core.as_vec2(p2_val), core.as_float(thick_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_line_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_line_color":
		if b.batch_type != .Line {
			vm.runtime_error(v, "set_line_color() can only be used with a BATCH2D_LINE batch.")
			return false
		}
		if arg_count != 2 {
			vm.runtime_error(v, "set_line_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_line_color() expects (int index, vec4 color).")
			return false
		}
		if !batch2d_set_line_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_line_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "is_valid_index":
		if arg_count != 1 {
			vm.runtime_error(v, "is_valid_index() expects 1 argument (index).")
			return false
		}
		idx_val := vm.peek(v, 0)
		if !core.is_int(idx_val) {
			vm.runtime_error(v, "is_valid_index() argument must be an integer.")
			return false
		}
		result = core.make_bool_value(batch2d_is_valid_index(b, core.as_int(idx_val)))
	case "clear":
		if arg_count != 0 {
			vm.runtime_error(v, "clear() takes no arguments.")
			return false
		}
		batch2d_clear(b)
		result = core.NIL_VALUE
	case "count":
		if arg_count != 0 {
			vm.runtime_error(v, "count() takes no arguments.")
			return false
		}
		result = core.make_int_value(batch2d_count(b), true)
	case "reserve":
		if arg_count != 1 {
			vm.runtime_error(v, "reserve() expects 1 argument (capacity).")
			return false
		}
		cap_val := vm.peek(v, 0)
		if !core.is_int(cap_val) {
			vm.runtime_error(v, "reserve() argument must be an integer.")
			return false
		}
		batch2d_reserve(b, core.as_int(cap_val))
		result = core.NIL_VALUE
	case "draw":
		if arg_count != 0 {
			vm.runtime_error(v, "draw() takes no arguments.")
			return false
		}
		batch2d_draw(b)
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Undefined Batch2D method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
