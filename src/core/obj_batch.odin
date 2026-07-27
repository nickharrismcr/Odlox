package core

import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// Batch_Object accumulates many same-kind 3D primitives (cubes, spheres,
// 3-point triangles, or flat circles) and draws them all in one .draw()
// call instead of one native-method-dispatch round trip per primitive
// per frame -- ported from glox's obj_builtin_batch.go/batch_methods.go.
Batch_Primitive :: enum {
	Cube,
	Sphere,
	Triangle3,
	Circle3,
}

// Batch_Entry backs BATCH_CUBE/BATCH_SPHERE (size.x doubles as radius
// for spheres, matching glox's own Draw() exactly). glox's own
// BatchEntry also carries a Rotation field that is stored on
// construction but never read anywhere -- no method ever sets it after
// the zero-value default, and Draw() never applies it -- structurally
// dead state with no observable effect from Lox. Omitted here rather
// than ported as an unreachable field with nothing to read or write it.
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
// otherwise, same axis-angle convention as cube_rotated.
Circle_Batch_Entry :: struct {
	center: rl.Vector3,
	radius: f32,
	axis:   rl.Vector3,
	angle:  f32, // degrees
	color:  rl.Color,
}

Batch_Object :: struct {
	using obj:      Obj,
	batch_type:     Batch_Primitive,
	entries:        [dynamic]Batch_Entry, // BATCH_CUBE/BATCH_SPHERE
	triangles:      [dynamic]Triangle_Batch_Entry, // BATCH_TRIANGLE3
	circles:        [dynamic]Circle_Batch_Entry, // BATCH_CIRCLE3

	// circle_mesh/circle_material back BATCH_CIRCLE3: a single shared
	// unit quad (lazily created, cached per-batch) drawn once per entry
	// via rl.DrawMesh with a per-entry scale/rotate/translate transform,
	// instead of rebuilding a triangle-fan circle approximation from
	// scratch every frame. The quad's own shape is a plain square --
	// set_circle_texture supplies a texture (e.g. a pre-rendered filled
	// circle) so it reads as a circle; without one it draws as a
	// flat-colored square. Never explicitly unloaded -- matches glox
	// exactly (no UnloadMesh/UnloadMaterial call exists for this anywhere
	// in glox either); process exit tears down the GL context regardless.
	circle_mesh:       rl.Mesh,
	circle_material:   rl.Material,
	circle_mesh_ready: bool,
}

make_batch_object :: proc(batch_type: Batch_Primitive) -> ^Batch_Object {
	o := new(Batch_Object)
	o.obj.type = .Batch
	o.batch_type = batch_type
	return o
}

batch_add :: proc(b: ^Batch_Object, pos, size: ^Vec3_Object, color: ^Vec4_Object) -> int {
	append(&b.entries, Batch_Entry{
		position = rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)},
		size     = rl.Vector3{f32(size.x), f32(size.y), f32(size.z)},
		color    = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.entries) - 1
}

batch_add_triangle3 :: proc(b: ^Batch_Object, p1, p2, p3: ^Vec3_Object, color: ^Vec4_Object) -> int {
	append(&b.triangles, Triangle_Batch_Entry{
		point1 = rl.Vector3{f32(p1.x), f32(p1.y), f32(p1.z)},
		point2 = rl.Vector3{f32(p2.x), f32(p2.y), f32(p2.z)},
		point3 = rl.Vector3{f32(p3.x), f32(p3.y), f32(p3.z)},
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.triangles) - 1
}

batch_add_circle3 :: proc(b: ^Batch_Object, center: ^Vec3_Object, radius: f64, axis: ^Vec3_Object, angle: f64, color: ^Vec4_Object) -> int {
	append(&b.circles, Circle_Batch_Entry{
		center = rl.Vector3{f32(center.x), f32(center.y), f32(center.z)},
		radius = f32(radius),
		axis   = rl.Vector3{f32(axis.x), f32(axis.y), f32(axis.z)},
		angle  = f32(angle),
		color  = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)},
	})
	return len(b.circles) - 1
}

batch_set_circle3_full :: proc(b: ^Batch_Object, index: int, x, y, z, radius: f64, color: ^Vec4_Object) -> bool {
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

batch_set_circle3_color :: proc(b: ^Batch_Object, index: int, color: ^Vec4_Object) -> bool {
	if index < 0 || index >= len(b.circles) {
		return false
	}
	b.circles[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

batch_set_position :: proc(b: ^Batch_Object, index: int, pos: ^Vec3_Object) -> bool {
	if index < 0 || index >= len(b.entries) {
		return false
	}
	b.entries[index].position = rl.Vector3{f32(pos.x), f32(pos.y), f32(pos.z)}
	return true
}

batch_set_color :: proc(b: ^Batch_Object, index: int, color: ^Vec4_Object) -> bool {
	if index < 0 || index >= len(b.entries) {
		return false
	}
	b.entries[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

batch_set_size :: proc(b: ^Batch_Object, index: int, size: ^Vec3_Object) -> bool {
	if index < 0 || index >= len(b.entries) {
		return false
	}
	b.entries[index].size = rl.Vector3{f32(size.x), f32(size.y), f32(size.z)}
	return true
}

batch_set_triangle3 :: proc(b: ^Batch_Object, index: int, p1, p2, p3: ^Vec3_Object) -> bool {
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

batch_set_triangle3_full :: proc(b: ^Batch_Object, index: int, x1, y1, z1, x2, y2, z2, x3, y3, z3: f64, color: ^Vec4_Object) -> bool {
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

batch_set_triangle3_color :: proc(b: ^Batch_Object, index: int, color: ^Vec4_Object) -> bool {
	if index < 0 || index >= len(b.triangles) {
		return false
	}
	b.triangles[index].color = rl.Color{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}
	return true
}

batch_get_position :: proc(b: ^Batch_Object, index: int) -> (rl.Vector3, bool) {
	if index < 0 || index >= len(b.entries) {
		return {}, false
	}
	return b.entries[index].position, true
}

batch_get_color :: proc(b: ^Batch_Object, index: int) -> (rl.Color, bool) {
	if index < 0 || index >= len(b.entries) {
		return {}, false
	}
	return b.entries[index].color, true
}

batch_get_size :: proc(b: ^Batch_Object, index: int) -> (rl.Vector3, bool) {
	if index < 0 || index >= len(b.entries) {
		return {}, false
	}
	return b.entries[index].size, true
}

batch_is_valid_index :: proc(b: ^Batch_Object, index: int) -> bool {
	return index >= 0 && index < len(b.entries)
}

batch_clear :: proc(b: ^Batch_Object) {
	clear(&b.entries)
	clear(&b.triangles)
	clear(&b.circles)
}

batch_reserve :: proc(b: ^Batch_Object, capacity: int) {
	if capacity > len(b.entries) {
		reserve(&b.entries, capacity)
	}
}

batch_count :: proc(b: ^Batch_Object) -> int {
	switch b.batch_type {
	case .Triangle3: return len(b.triangles)
	case .Circle3: return len(b.circles)
	case .Cube, .Sphere: return len(b.entries)
	}
	return len(b.entries)
}

batch_circle_quad :: proc(b: ^Batch_Object) -> (rl.Mesh, rl.Material) {
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

batch_set_circle_texture :: proc(b: ^Batch_Object, texture: rl.Texture2D) {
	_, material := batch_circle_quad(b)
	material.maps[rl.MaterialMapIndex.ALBEDO].texture = texture
}

@(private = "file")
batch_draw_circle3 :: proc(b: ^Batch_Object, entry: Circle_Batch_Entry) {
	mesh, material := batch_circle_quad(b)
	scale := rl.MatrixScale(entry.radius * 2, 1, entry.radius * 2)
	rotation := rl.MatrixRotate(entry.axis, entry.angle * math.RAD_PER_DEG)
	translation := rl.MatrixTranslate(entry.center.x, entry.center.y, entry.center.z)
	transform := scale * rotation * translation
	material.maps[rl.MaterialMapIndex.ALBEDO].color = entry.color
	rl.DrawMesh(mesh, material, transform)
}

// batch_draw renders every entry in the batch. The BATCH_CIRCLE3 branch
// flushes rlgl's own internal render batch before drawing (rl.DrawMesh,
// used here and by cube_rotated, does not flush it itself) and disables
// depth writes for the duration -- ported from glox's own Draw() exactly,
// including the doc comment explaining why: immediate-mode primitives
// drawn earlier in the frame (win.plane, win.cube, ...) only *queue*
// vertices into rlgl's batch, not send them to the GPU; without an
// explicit flush here, a translucent shadow quad can rasterize before,
// say, the floor it should sit on top of, and since alpha=0 still writes
// to the depth buffer, that gap becomes permanent once the floor's own
// already-queued draw later fails the depth test against it.
batch_draw :: proc(b: ^Batch_Object) {
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

// batch_draw_frustum_culled mirrors glox's own DrawWithDirectionalCulling:
// a simple, approximate view-cone test (not a real clip-space frustum),
// applied per entry before each draw call rather than a stricter culling
// scheme, matching glox's own implementation exactly rather than
// improving on it -- only BATCH_CUBE/BATCH_SPHERE support this (glox's
// own switch has no TRIANGLE3/CIRCLE3 case either, so those batch types
// silently draw nothing via this method -- ported as-is, not treated as
// a bug to fix, since it's real, existing behavior a script could depend
// on either way).
batch_draw_frustum_culled :: proc(b: ^Batch_Object, camera_pos, camera_forward: rl.Vector3, max_distance, fov_degrees: f32) {
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
