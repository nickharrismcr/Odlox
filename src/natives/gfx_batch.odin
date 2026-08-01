package natives

import "../core"
import "../vm"
import "core:fmt"
import "core:math"
import "core:mem"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// gfx_batch: Batch_Data accumulates many same-kind 3D primitives (cubes,
// spheres, 3-point triangles, or flat circles) and draws them all in one
// .draw() call instead of one native-method-dispatch round trip per
// primitive per frame.

// Batch_Primitive: package-private since gfx_window.odin's
// window_constant (win.BATCH_CUBE etc.) and gfx.odin's batch()
// constructor both need it.
@(private)
Batch_Primitive :: enum {
	Cube,
	Sphere,
	Triangle3,
	Circle3,
}

// Batch_Entry backs BATCH_CUBE/BATCH_SPHERE. size.x doubles as radius
// for spheres. Cubes and spheres in a batch are axis-aligned only -- no
// per-entry rotation.
Batch_Entry :: struct {
	position: rl.Vector3,
	size:     rl.Vector3,
	color:    rl.Color,
}

Triangle_Batch_Entry :: struct {
	point1, point2, point3: rl.Vector3,
	color:                  rl.Color,
}

// Circle_Batch_Entry is a flat, filled circle (e.g. a ground shadow).
// axis={0,1,0}, angle=0 is a flat, +Y-facing disc; axis/angle orient it
// otherwise, same axis-angle convention as Window's cube_rotated.
Circle_Batch_Entry :: struct {
	center: rl.Vector3,
	radius: f32,
	axis:   rl.Vector3,
	angle:  f32, // degrees
	color:  rl.Color,
}

Batch_Data :: struct {
	batch_type: Batch_Primitive,
	entries:    [dynamic]Batch_Entry, // BATCH_CUBE/BATCH_SPHERE
	triangles:  [dynamic]Triangle_Batch_Entry, // BATCH_TRIANGLE3
	circles:    [dynamic]Circle_Batch_Entry, // BATCH_CIRCLE3

	// circle_mesh/circle_material back BATCH_CIRCLE3: a single shared
	// unit quad (lazily created, cached per-batch) drawn once per entry
	// via rl.DrawMesh with a per-entry scale/rotate/translate transform,
	// instead of rebuilding a triangle-fan circle approximation from
	// scratch every frame. The quad's own shape is a plain square --
	// set_circle_texture supplies a texture (e.g. a pre-rendered filled
	// circle) so it reads as a circle; without one it draws as a
	// flat-colored square. Never explicitly unloaded -- process exit
	// tears down the GL context regardless.
	circle_mesh:       rl.Mesh,
	circle_material:   rl.Material,
	circle_mesh_ready: bool,
}

@(private = "file")
batch_vtable := core.Userdata_Vtable {
	tag       = "Batch",
	free      = batch_data_free,
	to_string = batch_to_string,
	size      = batch_data_size,
	invoke    = batch_invoke,
}

@(private = "file")
batch_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	b := cast(^Batch_Data)data
	type_name := "CUBE"
	#partial switch b.batch_type {
	case .Sphere: type_name = "SPHERE"
	case .Triangle3: type_name = "TRIANGLE3"
	case .Circle3: type_name = "CIRCLE3"
	}
	return fmt.aprintf("<Batch %s [%d entries]>", type_name, batch_count(b), allocator = allocator)
}

@(private = "file")
batch_data_size :: proc(data: rawptr) -> int {
	b := cast(^Batch_Data)data
	return size_of(Batch_Data) +
		len(b.entries) * size_of(Batch_Entry) +
		len(b.triangles) * size_of(Triangle_Batch_Entry) +
		len(b.circles) * size_of(Circle_Batch_Entry)
}

@(private = "file")
batch_data_free :: proc(data: rawptr) {
	b := cast(^Batch_Data)data
	delete(b.entries)
	delete(b.triangles)
	delete(b.circles)
	free(b)
}

@(private = "file")
batch_add :: proc(b: ^Batch_Data, pos, size: ^core.Vec3_Object, color: ^core.Vec4_Object) -> int {
	append(&b.entries, Batch_Entry{
		position = rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)},
		size     = rl.Vector3{f32(size.x), f32(size.y), f32(size.z)},
		color    = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.entries) - 1
}

@(private = "file")
batch_add_triangle3 :: proc(b: ^Batch_Data, p1, p2, p3: ^core.Vec3_Object, color: ^core.Vec4_Object) -> int {
	append(&b.triangles, Triangle_Batch_Entry{
		point1 = rl.Vector3{f32(p1.x), f32(p1.y), f32(p1.z)},
		point2 = rl.Vector3{f32(p2.x), f32(p2.y), f32(p2.z)},
		point3 = rl.Vector3{f32(p3.x), f32(p3.y), f32(p3.z)},
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.triangles) - 1
}

@(private = "file")
batch_add_circle3 :: proc(b: ^Batch_Data, center: ^core.Vec3_Object, radius: f64, axis: ^core.Vec3_Object, angle: f64, color: ^core.Vec4_Object) -> int {
	append(&b.circles, Circle_Batch_Entry{
		center = rl.Vector3{f32(center.x), f32(center.y), f32(center.z)},
		radius = f32(radius),
		axis   = rl.Vector3{f32(axis.x), f32(axis.y), f32(axis.z)},
		angle  = f32(angle),
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.circles) - 1
}

@(private = "file")
batch_set_circle3_full :: proc(b: ^Batch_Data, index: int, x, y, z, radius: f64, color: ^core.Vec4_Object) -> bool {
	if index < 0 || index >= len(b.circles) {
		return false
	}
	b.circles[index] = Circle_Batch_Entry{
		center = rl.Vector3{f32(x), f32(y), f32(z)},
		radius = f32(radius),
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	}
	return true
}

@(private = "file")
batch_set_circle3_color :: proc(b: ^Batch_Data, index: int, color: ^core.Vec4_Object) -> bool {
	if index < 0 || index >= len(b.circles) {
		return false
	}
	b.circles[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

@(private = "file")
batch_set_position :: proc(b: ^Batch_Data, index: int, pos: ^core.Vec3_Object) -> bool {
	if index < 0 || index >= len(b.entries) {
		return false
	}
	b.entries[index].position = rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)}
	return true
}

@(private = "file")
batch_set_color :: proc(b: ^Batch_Data, index: int, color: ^core.Vec4_Object) -> bool {
	if index < 0 || index >= len(b.entries) {
		return false
	}
	b.entries[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

@(private = "file")
batch_set_size :: proc(b: ^Batch_Data, index: int, size: ^core.Vec3_Object) -> bool {
	if index < 0 || index >= len(b.entries) {
		return false
	}
	b.entries[index].size = rl.Vector3{f32(size.x), f32(size.y), f32(size.z)}
	return true
}

@(private = "file")
batch_set_triangle3 :: proc(b: ^Batch_Data, index: int, p1, p2, p3: ^core.Vec3_Object) -> bool {
	if index < 0 || index >= len(b.triangles) {
		return false
	}
	color := b.triangles[index].color // preserved
	b.triangles[index] = Triangle_Batch_Entry{
		point1 = rl.Vector3{f32(p1.x), f32(p1.y), f32(p1.z)},
		point2 = rl.Vector3{f32(p2.x), f32(p2.y), f32(p2.z)},
		point3 = rl.Vector3{f32(p3.x), f32(p3.y), f32(p3.z)},
		color  = color,
	}
	return true
}

@(private = "file")
batch_set_triangle3_full :: proc(b: ^Batch_Data, index: int, x1, y1, z1, x2, y2, z2, x3, y3, z3: f64, color: ^core.Vec4_Object) -> bool {
	if index < 0 || index >= len(b.triangles) {
		return false
	}
	b.triangles[index] = Triangle_Batch_Entry{
		point1 = rl.Vector3{f32(x1), f32(y1), f32(z1)},
		point2 = rl.Vector3{f32(x2), f32(y2), f32(z2)},
		point3 = rl.Vector3{f32(x3), f32(y3), f32(z3)},
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	}
	return true
}

@(private = "file")
batch_set_triangle3_color :: proc(b: ^Batch_Data, index: int, color: ^core.Vec4_Object) -> bool {
	if index < 0 || index >= len(b.triangles) {
		return false
	}
	b.triangles[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

@(private = "file")
batch_get_position :: proc(b: ^Batch_Data, index: int) -> (rl.Vector3, bool) {
	if index < 0 || index >= len(b.entries) {
		return {}, false
	}
	return b.entries[index].position, true
}

@(private = "file")
batch_get_color :: proc(b: ^Batch_Data, index: int) -> (rl.Color, bool) {
	if index < 0 || index >= len(b.entries) {
		return {}, false
	}
	return b.entries[index].color, true
}

@(private = "file")
batch_get_size :: proc(b: ^Batch_Data, index: int) -> (rl.Vector3, bool) {
	if index < 0 || index >= len(b.entries) {
		return {}, false
	}
	return b.entries[index].size, true
}

@(private = "file")
batch_is_valid_index :: proc(b: ^Batch_Data, index: int) -> bool {
	return index >= 0 && index < len(b.entries)
}

@(private = "file")
batch_clear :: proc(b: ^Batch_Data) {
	clear(&b.entries)
	clear(&b.triangles)
	clear(&b.circles)
}

@(private = "file")
batch_reserve :: proc(b: ^Batch_Data, capacity: int) {
	if capacity > len(b.entries) {
		reserve(&b.entries, capacity)
	}
}

@(private = "file")
batch_count :: proc(b: ^Batch_Data) -> int {
	switch b.batch_type {
	case .Triangle3: return len(b.triangles)
	case .Circle3: return len(b.circles)
	case .Cube, .Sphere: return len(b.entries)
	}
	return len(b.entries)
}

@(private = "file")
batch_circle_quad :: proc(b: ^Batch_Data) -> (rl.Mesh, rl.Material) {
	if !b.circle_mesh_ready {
		b.circle_mesh = rl.GenMeshPlane(1, 1, 1, 1)
		if b.circle_mesh.vaoId == 0 {
			rl.UploadMesh(&b.circle_mesh, false)
		}
		b.circle_material = rl.LoadMaterialDefault()
		b.circle_mesh_ready = true
	}
	return b.circle_mesh, b.circle_material
}

@(private = "file")
batch_set_circle_texture :: proc(b: ^Batch_Data, texture: rl.Texture2D) {
	_, material := batch_circle_quad(b)
	material.maps[rl.MaterialMapIndex.ALBEDO].texture = texture
}

@(private = "file")
batch_draw_circle3 :: proc(b: ^Batch_Data, entry: Circle_Batch_Entry) {
	mesh, material := batch_circle_quad(b)
	scale := rl.MatrixScale(entry.radius * 2, 1, entry.radius * 2)
	rotation := rl.MatrixRotate(entry.axis, entry.angle * math.RAD_PER_DEG)
	translation := rl.MatrixTranslate(entry.center.x, entry.center.y, entry.center.z)
	transform := translation * rotation * scale // column-vector convention -- see gfx_window.odin's cube_rotated comment
	material.maps[rl.MaterialMapIndex.ALBEDO].color = entry.color
	rl.DrawMesh(mesh, material, transform)
}

// batch_draw renders every entry in the batch. The BATCH_CIRCLE3 branch
// flushes rlgl's own internal render batch before drawing (rl.DrawMesh,
// used here and by cube_rotated, does not flush it itself) and disables
// depth writes for the duration: immediate-mode primitives drawn earlier
// in the frame (win.plane, win.cube, ...) only *queue* vertices into
// rlgl's batch, not send them to the GPU; without an explicit flush
// here, a translucent shadow quad can rasterize before, say, the floor
// it should sit on top of, and since alpha=0 still writes to the depth
// buffer, that gap becomes permanent once the floor's own already-queued
// draw later fails the depth test against it.
@(private = "file")
batch_draw :: proc(b: ^Batch_Data) {
	switch b.batch_type {
	case .Cube:
		for e in b.entries {
			rl.DrawCube(e.position, e.size.x, e.size.y, e.size.z, e.color)
		}
	case .Sphere:
		for e in b.entries {
			rl.DrawSphere(e.position, e.size.x, e.color)
		}
	case .Triangle3:
		for e in b.triangles {
			rl.DrawTriangle3D(e.point1, e.point2, e.point3, e.color)
		}
	case .Circle3:
		rlgl.DrawRenderBatchActive()
		rlgl.DisableDepthMask()
		for e in b.circles {
			batch_draw_circle3(b, e)
		}
		rlgl.EnableDepthMask()
	}
}

// batch_draw_frustum_culled performs a simple, approximate view-cone
// test (not a real clip-space frustum), applied per entry before each
// draw call. Only BATCH_CUBE/BATCH_SPHERE support this -- calling it on
// a TRIANGLE3/CIRCLE3 batch silently draws nothing.
@(private = "file")
batch_draw_frustum_culled :: proc(b: ^Batch_Data, camera_pos, camera_forward: rl.Vector3, max_distance, fov_degrees: f32) {
	max_distance_sq := max_distance * max_distance
	padded_fov := fov_degrees + 10.0
	fov_radians := padded_fov * 3.14159 / 180.0

	switch b.batch_type {
	case .Cube:
		for e in b.entries {
			if batch_frustum_visible(e, camera_pos, camera_forward, max_distance_sq, fov_radians) {
				rl.DrawCube(e.position, e.size.x, e.size.y, e.size.z, e.color)
			}
		}
	case .Sphere:
		for e in b.entries {
			if batch_frustum_visible(e, camera_pos, camera_forward, max_distance_sq, fov_radians) {
				rl.DrawSphere(e.position, e.size.x, e.color)
			}
		}
	case .Triangle3, .Circle3:
	}
}

@(private = "file")
batch_frustum_visible :: proc(e: Batch_Entry, camera_pos, camera_forward: rl.Vector3, max_distance_sq, fov_radians: f32) -> bool {
	dx := e.position.x - camera_pos.x
	dy := e.position.y - camera_pos.y
	dz := e.position.z - camera_pos.z
	distance_sq := dx * dx + dy * dy + dz * dz
	if distance_sq > max_distance_sq {
		return false
	}
	distance := math.sqrt(distance_sq)
	if distance <= 0.001 {
		return true
	}
	obj_dir := rl.Vector3{dx / distance, dy / distance, dz / distance}
	dot := obj_dir.x * camera_forward.x + obj_dir.y * camera_forward.y + obj_dir.z * camera_forward.z
	object_radius := (e.size.x + e.size.y + e.size.z) / 3.0
	size_angle_offset := math.atan(object_radius / distance)
	adjusted_min_dot := math.cos(fov_radians / 2.0 + size_angle_offset)
	return dot >= adjusted_min_dot
}

// gfx_batch: the single argument is a win.BATCH_* constant (a plain int
// -- see gfx_window.odin's window_constant for Batch_Primitive's ordinal
// values), not validated against a fixed enum range here: an
// out-of-range int just becomes an unreachable Batch_Primitive value
// that every dispatch site's own switch statement falls through on
// harmlessly.
@(private)
gfx_batch :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "batch() expects 1 argument (a win.BATCH_* constant).")
		return core.NIL_VALUE
	}
	type_val := v.stack[arg_stack_ptr]
	if !core.is_int(type_val) {
		vm.runtime_error(v, "batch() argument must be a win.BATCH_* constant.")
		return core.NIL_VALUE
	}
	data := new(Batch_Data)
	data.batch_type = Batch_Primitive(core.as_int(type_val))
	o := core.make_userdata_object(&batch_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
batch_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	b := cast(^Batch_Data)data
	result: core.Value
	switch name {
	case "add":
		if arg_count != 3 {
			vm.runtime_error(v, "add() expects 3 arguments (position, size, color).")
			return false
		}
		pos_val, size_val, col_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(size_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "add() expects (vec3 position, vec3 size, vec4 color).")
			return false
		}
		idx := batch_add(b, core.as_vec3(pos_val), core.as_vec3(size_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "add_triangle3":
		if b.batch_type != .Triangle3 {
			vm.runtime_error(v, "add_triangle3() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 4 {
			vm.runtime_error(v, "add_triangle3() expects 4 arguments (point1, point2, point3, color).")
			return false
		}
		p1_val, p2_val, p3_val, col_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(p1_val) || !core.is_vec3(p2_val) || !core.is_vec3(p3_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "add_triangle3() expects (vec3, vec3, vec3, vec4 color).")
			return false
		}
		idx := batch_add_triangle3(b, core.as_vec3(p1_val), core.as_vec3(p2_val), core.as_vec3(p3_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "add_circle3":
		if b.batch_type != .Circle3 {
			vm.runtime_error(v, "add_circle3() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 5 {
			vm.runtime_error(v, "add_circle3() expects 5 arguments (center, radius, axis, angle, color).")
			return false
		}
		center_val, radius_val, axis_val, angle_val, col_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(center_val) || !core.is_number(radius_val) || !core.is_vec3(axis_val) ||
		   !core.is_number(angle_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "add_circle3() expects (vec3 center, number radius, vec3 axis, number angle, vec4 color).")
			return false
		}
		idx := batch_add_circle3(b, core.as_vec3(center_val), core.as_float(radius_val), core.as_vec3(axis_val), core.as_float(angle_val), core.as_vec4(col_val))
		result = core.make_int_value(idx, true)
	case "set_circle_texture":
		if b.batch_type != .Circle3 {
			vm.runtime_error(v, "set_circle_texture() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 1 {
			vm.runtime_error(v, "set_circle_texture() expects 1 argument (texture).")
			return false
		}
		tex_val := vm.peek(v, 0)
		if !is_texture_value(tex_val) {
			vm.runtime_error(v, "set_circle_texture() argument must be a texture.")
			return false
		}
		batch_set_circle_texture(b, texture_data_of(tex_val).texture)
		result = core.NIL_VALUE
	case "set_circle3_full":
		if b.batch_type != .Circle3 {
			vm.runtime_error(v, "set_circle3_full() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 6 {
			vm.runtime_error(v, "set_circle3_full() expects 6 arguments (index, x, y, z, radius, color).")
			return false
		}
		idx_val, x_val, y_val, z_val, radius_val, col_val := vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_number(x_val) || !core.is_number(y_val) || !core.is_number(z_val) ||
		   !core.is_number(radius_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_circle3_full() expects (int index, number x, number y, number z, number radius, vec4 color).")
			return false
		}
		if !batch_set_circle3_full(b, core.as_int(idx_val), core.as_float(x_val), core.as_float(y_val), core.as_float(z_val), core.as_float(radius_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_circle3_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_circle3_color":
		if b.batch_type != .Circle3 {
			vm.runtime_error(v, "set_circle3_color() can only be used with a BATCH_CIRCLE3 batch.")
			return false
		}
		if arg_count != 2 {
			vm.runtime_error(v, "set_circle3_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_circle3_color() expects (int index, vec4 color).")
			return false
		}
		if !batch_set_circle3_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_circle3_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_position":
		if arg_count != 2 {
			vm.runtime_error(v, "set_position() expects 2 arguments (index, position).")
			return false
		}
		idx_val, pos_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec3(pos_val) {
			vm.runtime_error(v, "set_position() expects (int index, vec3 position).")
			return false
		}
		if !batch_set_position(b, core.as_int(idx_val), core.as_vec3(pos_val)) {
			vm.runtime_error(v, "set_position(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_color":
		if arg_count != 2 {
			vm.runtime_error(v, "set_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_color() expects (int index, vec4 color).")
			return false
		}
		if !batch_set_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_size":
		if arg_count != 2 {
			vm.runtime_error(v, "set_size() expects 2 arguments (index, size).")
			return false
		}
		idx_val, size_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec3(size_val) {
			vm.runtime_error(v, "set_size() expects (int index, vec3 size).")
			return false
		}
		if !batch_set_size(b, core.as_int(idx_val), core.as_vec3(size_val)) {
			vm.runtime_error(v, "set_size(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "get_position":
		if arg_count != 1 {
			vm.runtime_error(v, "get_position() expects 1 argument (index).")
			return false
		}
		idx_val := vm.peek(v, 0)
		if !core.is_int(idx_val) {
			vm.runtime_error(v, "get_position() argument must be an integer.")
			return false
		}
		p, ok := batch_get_position(b, core.as_int(idx_val))
		if !ok {
			vm.runtime_error(v, "get_position(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		o := vm.alloc_vec3(v, f64(p.x), f64(p.y), f64(p.z))
		result = core.Value{type = .Vec3, obj_type = .Vec3, obj = &o.obj}
	case "get_color":
		if arg_count != 1 {
			vm.runtime_error(v, "get_color() expects 1 argument (index).")
			return false
		}
		idx_val := vm.peek(v, 0)
		if !core.is_int(idx_val) {
			vm.runtime_error(v, "get_color() argument must be an integer.")
			return false
		}
		col, ok := batch_get_color(b, core.as_int(idx_val))
		if !ok {
			vm.runtime_error(v, "get_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		o := vm.alloc_vec4(v, f64(col.r), f64(col.g), f64(col.b), f64(col.a))
		result = core.Value{type = .Vec4, obj_type = .Vec4, obj = &o.obj}
	case "get_size":
		if arg_count != 1 {
			vm.runtime_error(v, "get_size() expects 1 argument (index).")
			return false
		}
		idx_val := vm.peek(v, 0)
		if !core.is_int(idx_val) {
			vm.runtime_error(v, "get_size() argument must be an integer.")
			return false
		}
		size, ok := batch_get_size(b, core.as_int(idx_val))
		if !ok {
			vm.runtime_error(v, "get_size(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		o := vm.alloc_vec3(v, f64(size.x), f64(size.y), f64(size.z))
		result = core.Value{type = .Vec3, obj_type = .Vec3, obj = &o.obj}
	case "draw":
		if arg_count != 0 {
			vm.runtime_error(v, "draw() takes no arguments.")
			return false
		}
		batch_draw(b)
		result = core.NIL_VALUE
	case "draw_frustum_culled":
		if arg_count != 4 {
			vm.runtime_error(v, "draw_frustum_culled() expects 4 arguments (camera_position, camera_forward, max_distance, fov_degrees).")
			return false
		}
		pos_val, fwd_val, dist_val, fov_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) || !core.is_vec3(fwd_val) || !core.is_number(dist_val) || !core.is_number(fov_val) {
			vm.runtime_error(v, "draw_frustum_culled() expects (vec3 camera_position, vec3 camera_forward, number max_distance, number fov_degrees).")
			return false
		}
		pos, fwd := core.as_vec3(pos_val), core.as_vec3(fwd_val)
		batch_draw_frustum_culled(
			b,
			rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)},
			rl.Vector3{f32(fwd.x), f32(fwd.y), f32(fwd.z)},
			f32(core.as_float(dist_val)), f32(core.as_float(fov_val)),
		)
		result = core.NIL_VALUE
	case "clear":
		if arg_count != 0 {
			vm.runtime_error(v, "clear() takes no arguments.")
			return false
		}
		batch_clear(b)
		result = core.NIL_VALUE
	case "count":
		if arg_count != 0 {
			vm.runtime_error(v, "count() takes no arguments.")
			return false
		}
		result = core.make_int_value(batch_count(b), true)
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
		batch_reserve(b, core.as_int(cap_val))
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
		result = core.make_bool_value(batch_is_valid_index(b, core.as_int(idx_val)))
	case "set_triangle3":
		if b.batch_type != .Triangle3 {
			vm.runtime_error(v, "set_triangle3() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 4 {
			vm.runtime_error(v, "set_triangle3() expects 4 arguments (index, point1, point2, point3).")
			return false
		}
		idx_val, p1_val, p2_val, p3_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec3(p1_val) || !core.is_vec3(p2_val) || !core.is_vec3(p3_val) {
			vm.runtime_error(v, "set_triangle3() expects (int index, vec3, vec3, vec3).")
			return false
		}
		if !batch_set_triangle3(b, core.as_int(idx_val), core.as_vec3(p1_val), core.as_vec3(p2_val), core.as_vec3(p3_val)) {
			vm.runtime_error(v, "set_triangle3(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_triangle3_full":
		if b.batch_type != .Triangle3 {
			vm.runtime_error(v, "set_triangle3_full() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 11 {
			vm.runtime_error(v, "set_triangle3_full() expects 11 arguments (index, x1, y1, z1, x2, y2, z2, x3, y3, z3, color).")
			return false
		}
		idx_val, x1, y1, z1, x2, y2, z2, x3, y3, z3, col_val :=
			vm.peek(v, 10), vm.peek(v, 9), vm.peek(v, 8), vm.peek(v, 7), vm.peek(v, 6), vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) ||
		   !core.is_number(x1) || !core.is_number(y1) || !core.is_number(z1) ||
		   !core.is_number(x2) || !core.is_number(y2) || !core.is_number(z2) ||
		   !core.is_number(x3) || !core.is_number(y3) || !core.is_number(z3) ||
		   !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_triangle3_full() expects (int index, 9 numbers, vec4 color).")
			return false
		}
		ok := batch_set_triangle3_full(
			b, core.as_int(idx_val),
			core.as_float(x1), core.as_float(y1), core.as_float(z1),
			core.as_float(x2), core.as_float(y2), core.as_float(z2),
			core.as_float(x3), core.as_float(y3), core.as_float(z3),
			core.as_vec4(col_val),
		)
		if !ok {
			vm.runtime_error(v, "set_triangle3_full(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case "set_triangle3_color":
		if b.batch_type != .Triangle3 {
			vm.runtime_error(v, "set_triangle3_color() can only be used with a BATCH_TRIANGLE3 batch.")
			return false
		}
		if arg_count != 2 {
			vm.runtime_error(v, "set_triangle3_color() expects 2 arguments (index, color).")
			return false
		}
		idx_val, col_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(idx_val) || !core.is_vec4(col_val) {
			vm.runtime_error(v, "set_triangle3_color() expects (int index, vec4 color).")
			return false
		}
		if !batch_set_triangle3_color(b, core.as_int(idx_val), core.as_vec4(col_val)) {
			vm.runtime_error(v, "set_triangle3_color(): index out of range: %d.", core.as_int(idx_val))
			return false
		}
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Undefined Batch method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
