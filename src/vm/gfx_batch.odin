package vm

import "../core"
import rl "vendor:raylib"

// gfx_batch: method dispatch for Batch_Object. Construction lives in
// natives/gfx.odin, same split as every other gfx native type; the real
// per-entry data manipulation and the actual raylib draw calls live in
// core/obj_batch.odin, since none of it needs VM state -- this file is
// purely argument marshalling/validation plus gc_track for the vec3/vec4
// values a few methods hand back.
invoke_builtin_batch :: proc(vm: ^VM, b: ^core.Batch_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "add":
		if arg_count != 3 {
			runtime_error(vm, "add() expects 3 arguments (position, size, color).")
			return false
		}
		pos_val, size_val, col_val := peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(size_val) || !core.is_vec4(col_val) {
			runtime_error(vm, "add() expects (vec3 position, vec3 size, vec4 color).")
			return false
		}
		idx := core.batch_add(b, core.as_vec3(pos_val), core.as_vec3(size_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "add_triangle3":
		if b.batch_type != .Triangle3 {
			runtime_error(vm, "add_triangle3() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 4 {
			runtime_error(vm, "add_triangle3() expects 4 arguments (point1, point2, point3, color).")
			return false
		}
		p1_val, p2_val, p3_val, col_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_vec3(p1_val) || !core.is_vec3(p2_val) || !core.is_vec3(p3_val) || !core.is_vec4(col_val) {
			runtime_error(vm, "add_triangle3() expects (vec3, vec3, vec3, vec4 color).")
			return false
		}
		idx := core.batch_add_triangle3(b, core.as_vec3(p1_val), core.as_vec3(p2_val), core.as_vec3(p3_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "add_circle3":
		if b.batch_type != .Circle3 {
			runtime_error(vm, "add_circle3() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 5 {
			runtime_error(vm, "add_circle3() expects 5 arguments (center, radius, axis, angle, color).")
			return false
		}
		center_val, radius_val, axis_val, angle_val, col_val := peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_vec3(center_val) || !core.is_number(radius_val) || !core.is_vec3(axis_val) ||
		   !core.is_number(angle_val) || !core.is_vec4(col_val) {
			runtime_error(vm, "add_circle3() expects (vec3 center, number radius, vec3 axis, number angle, vec4 color).")
			return false
		}
		idx := core.batch_add_circle3(b, core.as_vec3(center_val), core.as_float(radius_val), core.as_vec3(axis_val), core.as_float(angle_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "set_circle_texture":
		if b.batch_type != .Circle3 {
			runtime_error(vm, "set_circle_texture() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 1 {
			runtime_error(vm, "set_circle_texture() expects 1 argument (texture).")
			return false
		}
		tex_val := peek(vm, 0)
		if tex_val.type != .Obj || tex_val.obj_type != .Texture {
			runtime_error(vm, "set_circle_texture() argument must be a texture.")
			return false
		}
		core.batch_set_circle_texture(b, core.as_texture(tex_val).texture)
		result = core.NIL_VALUE
	case "set_circle3_full":
		if b.batch_type != .Circle3 {
			runtime_error(vm, "set_circle3_full() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 6 {
			runtime_error(vm, "set_circle3_full() expects 6 arguments (index, x, y, z, radius, color).")
			return false
		}
		idx_val, x_val, y_val, z_val, radius_val, col_val := peek(vm, 5), peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) || !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(z_val) ||
		   !core.is_number(radius_val) || !core.is_vec4(col_val) {
			runtime_error(vm, "set_circle3_full() expects (int index, number x, number y, number z, number radius, vec4 color).")
			return false
		}
		if !core.batch_set_circle3_full(b, core.as_int(idx_val), core.as_float(x_val), core.as_float(y_val), core.as_float(z_val), core.as_float(radius_val), core.as_vec4(col_val)) {
			runtime_error(vm, "set_circle3_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_circle3_color":
		if b.batch_type != .Circle3 {
			runtime_error(vm, "set_circle3_color() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 2 {
			runtime_error(vm, "set_circle3_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			runtime_error(vm, "set_circle3_color() expects (int index, vec4 color).")
			return false
		}
		if !core.batch_set_circle3_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			runtime_error(vm, "set_circle3_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_position":
		if arg_count != 2 {
			runtime_error(vm, "set_position() expects 2 arguments (index, position).")
			return false
		}
		idx_val, pos_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) || !core.is_vec3(pos_val) {
			runtime_error(vm, "set_position() expects (int index, vec3 position).")
			return false
		}
		if !core.batch_set_position(b, core.as_int(idx_val), core.as_vec3(pos_val)) {
			runtime_error(vm, "set_position(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_color":
		if arg_count != 2 {
			runtime_error(vm, "set_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			runtime_error(vm, "set_color() expects (int index, vec4 color).")
			return false
		}
		if !core.batch_set_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			runtime_error(vm, "set_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_size":
		if arg_count != 2 {
			runtime_error(vm, "set_size() expects 2 arguments (index, size).")
			return false
		}
		idx_val, size_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) || !core.is_vec3(size_val) {
			runtime_error(vm, "set_size() expects (int index, vec3 size).")
			return false
		}
		if !core.batch_set_size(b, core.as_int(idx_val), core.as_vec3(size_val)) {
			runtime_error(vm, "set_size(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "get_position":
		if arg_count != 1 {
			runtime_error(vm, "get_position() expects 1 argument (index).")
			return false
		}
		idx_val := peek(vm, 0)
		if !core.is_int(idx_val) {
			runtime_error(vm, "get_position() argument must be an integer.")
			return false
		}
		p, ok := core.batch_get_position(b, core.as_int(idx_val))
		if !ok {
			runtime_error(vm, "get_position(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		v := core.make_vec3_value(f64(p.x), f64(p.y), f64(p.z))
		gc_track(vm, v.obj)
		result = v
	case "get_color":
		if arg_count != 1 {
			runtime_error(vm, "get_color() expects 1 argument (index).")
			return false
		}
		idx_val := peek(vm, 0)
		if !core.is_int(idx_val) {
			runtime_error(vm, "get_color() argument must be an integer.")
			return false
		}
		col, ok := core.batch_get_color(b, core.as_int(idx_val))
		if !ok {
			runtime_error(vm, "get_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		v := core.make_vec4_value(f64(col.r), f64(col.g), f64(col.b), f64(col.a))
		gc_track(vm, v.obj)
		result = v
	case "get_size":
		if arg_count != 1 {
			runtime_error(vm, "get_size() expects 1 argument (index).")
			return false
		}
		idx_val := peek(vm, 0)
		if !core.is_int(idx_val) {
			runtime_error(vm, "get_size() argument must be an integer.")
			return false
		}
		size, ok := core.batch_get_size(b, core.as_int(idx_val))
		if !ok {
			runtime_error(vm, "get_size(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		v := core.make_vec3_value(f64(size.x), f64(size.y), f64(size.z))
		gc_track(vm, v.obj)
		result = v
	case "draw":
		if arg_count != 0 {
			runtime_error(vm, "draw() takes no arguments.")
			return false
		}
		core.batch_draw(b)
		result = core.NIL_VALUE
	case "draw_frustum_culled":
		if arg_count != 4 {
			runtime_error(vm, "draw_frustum_culled() expects 4 arguments (camera_position, camera_forward, max_distance, fov_degrees).")
			return false
		}
		pos_val, fwd_val, dist_val, fov_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(fwd_val) || !core.is_number(dist_val) || !core.is_number(fov_val) {
			runtime_error(vm, "draw_frustum_culled() expects (vec3 camera_position, vec3 camera_forward, number max_distance, number fov_degrees).")
			return false
		}
		pos, fwd := core.as_vec3(pos_val), core.as_vec3(fwd_val)
		core.batch_draw_frustum_culled(
			b,
			rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)},
			rl.Vector3{f32(fwd.x), f32(fwd.y), f32(fwd.z)},
			f32(core.as_float(dist_val)), f32(core.as_float(fov_val)),
		)
		result = core.NIL_VALUE
	case "clear":
		if arg_count != 0 {
			runtime_error(vm, "clear() takes no arguments.")
			return false
		}
		core.batch_clear(b)
		result = core.NIL_VALUE
	case "count":
		if arg_count != 0 {
			runtime_error(vm, "count() takes no arguments.")
			return false
		}
		result = core.make_int_value(core.batch_count(b), true)
	case "reserve":
		if arg_count != 1 {
			runtime_error(vm, "reserve() expects 1 argument (capacity).")
			return false
		}
		cap_val := peek(vm, 0)
		if !core.is_int(cap_val) {
			runtime_error(vm, "reserve() argument must be an integer.")
			return false
		}
		core.batch_reserve(b, core.as_int(cap_val))
		result = core.NIL_VALUE
	case "is_valid_index":
		if arg_count != 1 {
			runtime_error(vm, "is_valid_index() expects 1 argument (index).")
			return false
		}
		idx_val := peek(vm, 0)
		if !core.is_int(idx_val) {
			runtime_error(vm, "is_valid_index() argument must be an integer.")
			return false
		}
		result = core.make_bool_value(core.batch_is_valid_index(b, core.as_int(idx_val)))
	case "set_triangle3":
		if b.batch_type != .Triangle3 {
			runtime_error(vm, "set_triangle3() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 4 {
			runtime_error(vm, "set_triangle3() expects 4 arguments (index, point1, point2, point3).")
			return false
		}
		idx_val, p1_val, p2_val, p3_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) || !core.is_vec3(p1_val) || !core.is_vec3(p2_val) || !core.is_vec3(p3_val) {
			runtime_error(vm, "set_triangle3() expects (int index, vec3, vec3, vec3).")
			return false
		}
		if !core.batch_set_triangle3(b, core.as_int(idx_val), core.as_vec3(p1_val), core.as_vec3(p2_val), core.as_vec3(p3_val)) {
			runtime_error(vm, "set_triangle3(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_triangle3_full":
		if b.batch_type != .Triangle3 {
			runtime_error(vm, "set_triangle3_full() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 11 {
			runtime_error(vm, "set_triangle3_full() expects 11 arguments (index, x1, y1, z1, x2, y2, z2, x3, y3, z3, color).")
			return false
		}
		idx_val, x1, y1, z1, x2, y2, z2, x3, y3, z3, col_val :=
			peek(vm, 10), peek(vm, 9), peek(vm, 8), peek(vm, 7), peek(vm, 6), peek(vm, 5), peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) ||
		   !core.is_number(x1) || !core.is_number(y1) || !core.is_number(z1) ||
		   !core.is_number(x2) || !core.is_number(y2) || !core.is_number(z2) ||
		   !core.is_number(x3) || !core.is_number(y3) || !core.is_number(z3) ||
		   !core.is_vec4(col_val) {
			runtime_error(vm, "set_triangle3_full() expects (int index, 9 numbers, vec4 color).")
			return false
		}
		ok := core.batch_set_triangle3_full(
			b, core.as_int(idx_val),
			core.as_float(x1), core.as_float(y1), core.as_float(z1),
			core.as_float(x2), core.as_float(y2), core.as_float(z2),
			core.as_float(x3), core.as_float(y3), core.as_float(z3),
			core.as_vec4(col_val),
		)
		if !ok {
			runtime_error(vm, "set_triangle3_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_triangle3_color":
		if b.batch_type != .Triangle3 {
			runtime_error(vm, "set_triangle3_color() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 2 {
			runtime_error(vm, "set_triangle3_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			runtime_error(vm, "set_triangle3_color() expects (int index, vec4 color).")
			return false
		}
		if !core.batch_set_triangle3_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			runtime_error(vm, "set_triangle3_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined Batch method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
