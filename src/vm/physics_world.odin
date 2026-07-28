package vm

import "../core"
import "core:math"

// physics_world: the real simulation logic for core.Physics_World_Object
// (struct defined there -- see its doc comment). Faithful port of
// glox's obj_builtin_physics_world.go/physics_world_methods.go,
// including its one known limitation: Physics_Material.friction is
// stored and combined but never actually applied in resolve()'s
// collision response. Not fixed here -- see core/obj_physics_world.odin's
// doc comment on Physics_Material.

// rotate_vec rotates v around axis (not required to be unit-length; a
// near-zero axis is treated as "no rotation") by angle_deg degrees,
// via Rodrigues' rotation formula.
@(private = "file")
rotate_vec :: proc(v, axis: core.P_Vec3, angle_deg: f64) -> core.P_Vec3 {
	length := math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
	if length < 1e-12 {
		return v
	}
	a := core.P_Vec3{axis.x / length, axis.y / length, axis.z / length}

	rad := angle_deg * math.PI / 180
	cos_a := math.cos(rad)
	sin_a := math.sin(rad)
	dot := v.x * a.x + v.y * a.y + v.z * a.z
	cross := core.P_Vec3{
		a.y * v.z - a.z * v.y,
		a.z * v.x - a.x * v.z,
		a.x * v.y - a.y * v.x,
	}
	return core.P_Vec3{
		v.x * cos_a + cross.x * sin_a + a.x * dot * (1 - cos_a),
		v.y * cos_a + cross.y * sin_a + a.y * dot * (1 - cos_a),
		v.z * cos_a + cross.z * sin_a + a.z * dot * (1 - cos_a),
	}
}

@(private = "file")
combine_materials :: proc(a, b: core.Physics_Material) -> (restitution: f64) {
	return math.sqrt(a.restitution * b.restitution)
}

physics_world_add_material :: proc(w: ^core.Physics_World_Object, restitution, friction, damping: f64) -> int {
	append(&w.materials, core.Physics_Material{restitution, friction, damping})
	return len(w.materials) - 1
}

// append_body is the common tail of add/add_static_box: push one entry
// onto every parallel SoA slice, keeping them in lockstep.
@(private = "file")
physics_world_append_body :: proc(w: ^core.Physics_World_Object, pos, vel: core.P_Vec3, shape: core.Shape, material_id: int, is_static: bool) -> int {
	append(&w.pos_x, pos.x)
	append(&w.pos_y, pos.y)
	append(&w.pos_z, pos.z)
	append(&w.vel_x, vel.x)
	append(&w.vel_y, vel.y)
	append(&w.vel_z, vel.z)
	append(&w.shapes, shape)
	append(&w.material_id, material_id)
	append(&w.active, true)
	append(&w.is_static, is_static)

	id := len(w.pos_x) - 1
	if is_static {
		append(&w.static_ids, id)
	}
	return id
}

physics_world_add :: proc(w: ^core.Physics_World_Object, pos, vel: core.P_Vec3, radius: f64, material_id: int) -> (id: int, err: string, ok: bool) {
	if material_id < 0 || material_id >= len(w.materials) {
		return 0, "invalid material id", false
	}
	shape := core.Shape{kind = .Sphere, extent = core.P_Vec3{radius, 0, 0}}
	return physics_world_append_body(w, pos, vel, shape, material_id, false), "", true
}

// add_static_box creates a fixed, optionally rotated box (ramps,
// shelves, platforms). Orientation is set once here and never updated
// -- no velocity argument, signalling fixed-ness without inspecting a
// flag.
physics_world_add_static_box :: proc(w: ^core.Physics_World_Object, pos, half_extents, axis: core.P_Vec3, angle: f64, material_id: int) -> (id: int, err: string, ok: bool) {
	if material_id < 0 || material_id >= len(w.materials) {
		return 0, "invalid material id", false
	}
	shape := core.Shape{kind = .Box, extent = half_extents, axis = axis, angle = angle}
	return physics_world_append_body(w, pos, core.P_Vec3{}, shape, material_id, true), "", true
}

Box_Transform :: struct {
	pos, half_extents, axis: core.P_Vec3,
	angle:                   f64,
}

// get_box_transform is what Lox reads box orientation back from, so a
// rendered box always matches exactly what physics collided against.
physics_world_get_box_transform :: proc(w: ^core.Physics_World_Object, id: int) -> (bt: Box_Transform, err: string, ok: bool) {
	if id < 0 || id >= len(w.pos_x) || !w.active[id] {
		return {}, "index out of range or inactive", false
	}
	if w.shapes[id].kind != .Box {
		return {}, "body is not a box", false
	}
	s := w.shapes[id]
	return Box_Transform{
		pos = core.P_Vec3{w.pos_x[id], w.pos_y[id], w.pos_z[id]},
		half_extents = s.extent,
		axis = s.axis,
		angle = s.angle,
	}, "", true
}

physics_world_remove :: proc(w: ^core.Physics_World_Object, id: int) -> (err: string, ok: bool) {
	if id < 0 || id >= len(w.active) {
		return "index out of range", false
	}
	w.active[id] = false
	return "", true
}

physics_world_get_position :: proc(w: ^core.Physics_World_Object, id: int) -> (pos: core.P_Vec3, err: string, ok: bool) {
	if id < 0 || id >= len(w.pos_x) || !w.active[id] {
		return {}, "index out of range or inactive", false
	}
	return core.P_Vec3{w.pos_x[id], w.pos_y[id], w.pos_z[id]}, "", true
}

// add_impulse applies an instantaneous velocity change to a single
// body -- the low-level primitive Lox uses for explosion/force effects:
// the distance check, falloff curve, and "which bodies are affected"
// loop all stay in Lox, calling this once per affected body. No mass
// division -- matches the equal-mass assumption used in resolve().
physics_world_add_impulse :: proc(w: ^core.Physics_World_Object, id: int, impulse: core.P_Vec3) -> (err: string, ok: bool) {
	if id < 0 || id >= len(w.pos_x) || !w.active[id] {
		return "index out of range or inactive", false
	}
	w.vel_x[id] += impulse.x
	w.vel_y[id] += impulse.y
	w.vel_z[id] += impulse.z
	return "", true
}

// ---------------------------------------------------------------------
// Step: integration + broad phase + narrow phase

physics_world_step :: proc(w: ^core.Physics_World_Object, dt: f64) {
	physics_world_integrate(w, dt)
	physics_world_boundary_collisions(w)
	physics_world_rebuild_grid(w)

	clear(&w.collisions)

	// Swap ping-pong buffers: the map that was "prev" becomes this
	// frame's "curr", cleared in place instead of allocated fresh.
	w.contacts_cur = 1 - w.contacts_cur
	clear(&w.contact_sets[w.contacts_cur])

	physics_world_narrow_phase(w)
	physics_world_resolve_static_pairs(w)
}

@(private = "file")
physics_world_integrate :: proc(w: ^core.Physics_World_Object, dt: f64) {
	for i in 0 ..< len(w.pos_x) {
		if !w.active[i] || w.is_static[i] {
			continue // static bodies never move
		}
		mat := w.materials[w.material_id[i]]

		w.vel_x[i] += w.gravity.x * dt
		w.vel_y[i] += w.gravity.y * dt
		w.vel_z[i] += w.gravity.z * dt

		w.vel_x[i] *= mat.damping
		w.vel_y[i] *= mat.damping
		w.vel_z[i] *= mat.damping

		w.pos_x[i] += w.vel_x[i] * dt
		w.pos_y[i] += w.vel_y[i] * dt
		w.pos_z[i] += w.vel_z[i] * dt
	}
}

@(private = "file")
clamp_axis :: proc(pos, vel: ^f64, lo, hi, restitution: f64) {
	if pos^ < lo {
		pos^ = lo
		vel^ = -vel^ * restitution
	} else if pos^ > hi {
		pos^ = hi
		vel^ = -vel^ * restitution
	}
}

@(private = "file")
physics_world_boundary_collisions :: proc(w: ^core.Physics_World_Object) {
	for i in 0 ..< len(w.pos_x) {
		if !w.active[i] || w.is_static[i] {
			continue // a fixed platform shouldn't bounce off the world bounds
		}
		mat := w.materials[w.material_id[i]]
		// Every dynamic body is a sphere -- Shape_Kind.Box is only ever
		// created by add_static_box, and statics are skipped above -- so
		// extent.x (radius) alone is the correct per-axis bound.
		r := w.shapes[i].extent.x

		clamp_axis(&w.pos_x[i], &w.vel_x[i], w.bounds_min.x + r, w.bounds_max.x - r, mat.restitution)
		clamp_axis(&w.pos_y[i], &w.vel_y[i], w.bounds_min.y + r, w.bounds_max.y - r, mat.restitution)
		clamp_axis(&w.pos_z[i], &w.vel_z[i], w.bounds_min.z + r, w.bounds_max.z - r, mat.restitution)
	}
}

@(private = "file")
physics_world_cell_of :: proc(w: ^core.Physics_World_Object, i: int) -> core.Physics_Cell_Key {
	return core.Physics_Cell_Key{
		x = i32(math.floor(w.pos_x[i] / w.cell_size)),
		y = i32(math.floor(w.pos_y[i] / w.cell_size)),
		z = i32(math.floor(w.pos_z[i] / w.cell_size)),
	}
}

@(private = "file")
physics_world_rebuild_grid :: proc(w: ^core.Physics_World_Object) {
	// Clear only the cells touched last frame, re-slicing each bucket to
	// length 0 so its backing array is kept (and reused below) instead
	// of deleting the map entry and forcing a fresh allocation on the
	// next insert.
	for k in w.used_cells {
		if bucket, ok := w.grid[k]; ok {
			clear(&bucket)
			w.grid[k] = bucket
		}
	}
	clear(&w.used_cells)

	for i in 0 ..< len(w.pos_x) {
		// Static bodies are never inserted -- see static_ids' doc comment.
		if !w.active[i] || w.is_static[i] {
			continue
		}
		k := physics_world_cell_of(w, i)
		bucket := w.grid[k]
		if len(bucket) == 0 {
			append(&w.used_cells, k)
		}
		append(&bucket, i)
		w.grid[k] = bucket
	}
}

// narrow_phase visits, for each dynamic body i, the 27 cells around i's
// own cell. Those 27 (dx,dy,dz) offsets are all distinct absolute cell
// coordinates, so a given neighbor cell is visited at most once per i --
// no pair can be found twice within one i's scan. Combined with the
// `j <= i` guard (which only ever looks for the higher-indexed half of
// a pair), every unordered dynamic-dynamic pair {a,b} is discovered
// exactly once overall, so no separate dedup set is needed here.
//
// Static bodies never appear here at all (as i or via the grid, which
// never contains them) -- they're handled entirely by
// resolve_static_pairs.
@(private = "file")
physics_world_narrow_phase :: proc(w: ^core.Physics_World_Object) {
	for i in 0 ..< len(w.pos_x) {
		if !w.active[i] || w.is_static[i] {
			continue
		}
		base := physics_world_cell_of(w, i)

		for dz: i32 = -1; dz <= 1; dz += 1 {
			for dy: i32 = -1; dy <= 1; dy += 1 {
				for dx: i32 = -1; dx <= 1; dx += 1 {
					k := core.Physics_Cell_Key{base.x + dx, base.y + dy, base.z + dz}
					// Read into a local before ranging over it -- ranging
					// directly over a map-index expression (`for j in
					// w.grid[k]`) segfaults when k is absent from the map
					// (confirmed as a real, reproducible Odin behavior via
					// an isolated standalone repro, not a bounds-check-
					// catchable bug in this code: crashes identically in
					// both -debug and -o:speed builds). Every other map
					// read in this file already goes through a local first
					// (see rebuild_grid) -- this was the one direct-index
					// exception.
					bucket := w.grid[k]
					for j in bucket {
						if j <= i || !w.active[j] {
							continue
						}
						physics_world_check_and_resolve(w, i, j, core.Physics_Pair_Key{i, j})
					}
				}
			}
		}
	}
}

// resolve_static_pairs checks every active dynamic body against every
// static body directly, bypassing the grid entirely. Static body counts
// (walls, ramps, platforms) are expected to stay small, so this
// O(dynamic x static) pass is cheap and gives statics an exact
// membership test instead of an approximate, bounding-sphere-sized grid
// cell.
@(private = "file")
physics_world_resolve_static_pairs :: proc(w: ^core.Physics_World_Object) {
	for i in 0 ..< len(w.pos_x) {
		if !w.active[i] || w.is_static[i] {
			continue
		}
		for sid in w.static_ids {
			if !w.active[sid] {
				continue
			}
			a, b := i, sid
			if a > b {
				a, b = b, a
			}
			physics_world_check_and_resolve(w, a, b, core.Physics_Pair_Key{a, b})
		}
	}
}

@(private = "file")
physics_world_check_and_resolve :: proc(w: ^core.Physics_World_Object, i, j: int, pk: core.Physics_Pair_Key) {
	if w.is_static[i] && w.is_static[j] {
		return // two static bodies can't meaningfully collide
	}
	normal, overlap, ok := physics_world_collide(w, i, j)
	if !ok {
		return
	}
	physics_world_resolve(w, i, j, pk, normal, overlap)
}

// collide dispatches on the pair's shape kinds and returns the contact
// normal (pointing from i toward j) and penetration depth. ok is false
// if the pair isn't touching. There is no box-box case: Shape_Kind.Box
// is only ever created by add_static_box, and static-static pairs
// already return early in check_and_resolve, so the only shape
// combinations that ever reach here are sphere-sphere and sphere-box.
@(private = "file")
physics_world_collide :: proc(w: ^core.Physics_World_Object, i, j: int) -> (normal: core.P_Vec3, overlap: f64, ok: bool) {
	si, sj := w.shapes[i].kind, w.shapes[j].kind
	switch {
	case si == .Sphere && sj == .Sphere:
		return physics_world_collide_sphere_sphere(w, i, j)
	case si == .Sphere: // sj == .Box
		n, o, cok := physics_world_collide_sphere_box(w, i, j)
		if !cok {
			return {}, 0, false
		}
		return core.P_Vec3{-n.x, -n.y, -n.z}, o, true // box->sphere flipped to i->j
	case:
		// si == .Box, sj == .Sphere
		return physics_world_collide_sphere_box(w, j, i) // box(i)->sphere(j) is already i->j
	}
}

@(private = "file")
physics_world_collide_sphere_sphere :: proc(w: ^core.Physics_World_Object, i, j: int) -> (core.P_Vec3, f64, bool) {
	dx := w.pos_x[j] - w.pos_x[i]
	dy := w.pos_y[j] - w.pos_y[i]
	dz := w.pos_z[j] - w.pos_z[i]
	dist_sq := dx * dx + dy * dy + dz * dz
	min_dist := w.shapes[i].extent.x + w.shapes[j].extent.x

	if dist_sq >= min_dist * min_dist || dist_sq < 1e-12 {
		return {}, 0, false
	}

	dist := math.sqrt(dist_sq)
	return core.P_Vec3{dx / dist, dy / dist, dz / dist}, min_dist - dist, true
}

// collide_sphere_box tests a sphere against a (possibly rotated) box:
// the sphere's center is rotated into the box's local frame (inverse
// rotation), clamped to the box's half-extents to find the closest
// surface point, then rotated back to world space. angle == 0
// degenerates to the axis-aligned case with no extra cost. Returns the
// normal box-surface -> sphere-center.
@(private = "file")
physics_world_collide_sphere_box :: proc(w: ^core.Physics_World_Object, sphere_idx, box_idx: int) -> (core.P_Vec3, f64, bool) {
	box := w.shapes[box_idx]
	r := w.shapes[sphere_idx].extent.x

	local := core.P_Vec3{
		w.pos_x[sphere_idx] - w.pos_x[box_idx],
		w.pos_y[sphere_idx] - w.pos_y[box_idx],
		w.pos_z[sphere_idx] - w.pos_z[box_idx],
	}
	if box.angle != 0 {
		local = rotate_vec(local, box.axis, -box.angle)
	}

	clamped := core.P_Vec3{
		clamp(local.x, -box.extent.x, box.extent.x),
		clamp(local.y, -box.extent.y, box.extent.y),
		clamp(local.z, -box.extent.z, box.extent.z),
	}

	closest := clamped
	if box.angle != 0 {
		closest = rotate_vec(closest, box.axis, box.angle)
	}
	closest_world := core.P_Vec3{
		closest.x + w.pos_x[box_idx],
		closest.y + w.pos_y[box_idx],
		closest.z + w.pos_z[box_idx],
	}

	dx := w.pos_x[sphere_idx] - closest_world.x
	dy := w.pos_y[sphere_idx] - closest_world.y
	dz := w.pos_z[sphere_idx] - closest_world.z
	dist_sq := dx * dx + dy * dy + dz * dz

	if dist_sq >= r * r {
		return {}, 0, false
	}

	if dist_sq < 1e-12 {
		// Sphere center coincides with the closest surface point (deeply
		// embedded/tunneled). No well-defined nearest face without extra
		// work this doesn't need -- push out along the box's local +Y so
		// resolution still makes progress instead of dividing by ~0.
		return rotate_vec(core.P_Vec3{0, 1, 0}, box.axis, box.angle), r, true
	}

	dist := math.sqrt(dist_sq)
	return core.P_Vec3{dx / dist, dy / dist, dz / dist}, r - dist, true
}

// resolve applies positional correction and an impulse along normal
// (pointing i->j). When one side is static, all correction and impulse
// go to the dynamic side -- the correct limit of the general two-body
// formula as one mass -> infinity, not a bolt-on special case.
@(private = "file")
physics_world_resolve :: proc(w: ^core.Physics_World_Object, i, j: int, pk: core.Physics_Pair_Key, normal: core.P_Vec3, overlap: f64) {
	i_static, j_static := w.is_static[i], w.is_static[j]

	switch {
	case j_static:
		w.pos_x[i] -= normal.x * overlap
		w.pos_y[i] -= normal.y * overlap
		w.pos_z[i] -= normal.z * overlap
	case i_static:
		w.pos_x[j] += normal.x * overlap
		w.pos_y[j] += normal.y * overlap
		w.pos_z[j] += normal.z * overlap
	case:
		w.pos_x[i] -= normal.x * overlap * 0.5
		w.pos_y[i] -= normal.y * overlap * 0.5
		w.pos_z[i] -= normal.z * overlap * 0.5
		w.pos_x[j] += normal.x * overlap * 0.5
		w.pos_y[j] += normal.y * overlap * 0.5
		w.pos_z[j] += normal.z * overlap * 0.5
	}

	rvx := w.vel_x[j] - w.vel_x[i]
	rvy := w.vel_y[j] - w.vel_y[i]
	rvz := w.vel_z[j] - w.vel_z[i]
	vel_along_normal := rvx * normal.x + rvy * normal.y + rvz * normal.z

	restitution := combine_materials(w.materials[w.material_id[i]], w.materials[w.material_id[j]])

	curr := &w.contact_sets[w.contacts_cur]
	prev := &w.contact_sets[1 - w.contacts_cur]

	if vel_along_normal < 0 {
		switch {
		case j_static:
			impulse := -(1 + restitution) * vel_along_normal
			w.vel_x[i] -= impulse * normal.x
			w.vel_y[i] -= impulse * normal.y
			w.vel_z[i] -= impulse * normal.z
		case i_static:
			impulse := -(1 + restitution) * vel_along_normal
			w.vel_x[j] += impulse * normal.x
			w.vel_y[j] += impulse * normal.y
			w.vel_z[j] += impulse * normal.z
		case:
			impulse := -(1 + restitution) * vel_along_normal * 0.5
			w.vel_x[i] -= impulse * normal.x
			w.vel_y[i] -= impulse * normal.y
			w.vel_z[i] -= impulse * normal.z
			w.vel_x[j] += impulse * normal.x
			w.vel_y[j] += impulse * normal.y
			w.vel_z[j] += impulse * normal.z
		}

		curr[pk] = true
		if !prev[pk] {
			append(&w.collisions, core.Collision_Pair{
				a = i,
				b = j,
				normal = normal,
				impulse = abs(vel_along_normal),
			})
		}
	} else {
		curr[pk] = true
	}
}

// ---------------------------------------------------------------------
// Lox-facing method dispatch

@(private = "file")
p_vec3_of :: proc(v: core.Value) -> core.P_Vec3 {
	vv := core.as_vec3(v)
	return core.P_Vec3{vv.x, vv.y, vv.z}
}

@(private = "file")
make_vec3_result :: proc(vm: ^VM, v: core.P_Vec3) -> core.Value {
	result := core.make_vec3_value(v.x, v.y, v.z)
	gc_track(vm, result.obj)
	return result
}

invoke_builtin_physics_world :: proc(vm: ^VM, w: ^core.Physics_World_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "add_material":
		if arg_count != 3 {
			runtime_error(vm, "add_material() expects 3 arguments (restitution, friction, damping).")
			return false
		}
		r_val, f_val, d_val := peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_number(r_val) || !core.is_number(f_val) || !core.is_number(d_val) {
			runtime_error(vm, "add_material() arguments must be numbers.")
			return false
		}
		id := physics_world_add_material(w, core.as_float(r_val), core.as_float(f_val), core.as_float(d_val))
		result = core.make_int_value(id, true)
	case "add":
		if arg_count != 4 {
			runtime_error(vm, "add() expects 4 arguments (position, velocity, radius, material_id).")
			return false
		}
		pos_val, vel_val, radius_val, mat_val := peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_vec3(pos_val) {
			runtime_error(vm, "add() first argument must be a vec3 (position).")
			return false
		}
		if !core.is_vec3(vel_val) {
			runtime_error(vm, "add() second argument must be a vec3 (velocity).")
			return false
		}
		if !core.is_number(radius_val) {
			runtime_error(vm, "add() third argument must be a number (radius).")
			return false
		}
		if !core.is_int(mat_val) {
			runtime_error(vm, "add() fourth argument must be an integer (material_id).")
			return false
		}
		id, err, ok := physics_world_add(w, p_vec3_of(pos_val), p_vec3_of(vel_val), core.as_float(radius_val), core.as_int(mat_val))
		if !ok {
			runtime_error(vm, "%s", err)
			return false
		}
		result = core.make_int_value(id, true)
	case "add_static_box":
		if arg_count != 5 {
			runtime_error(vm, "add_static_box() expects 5 arguments (position, half_extents, axis, angle, material_id).")
			return false
		}
		pos_val, extent_val, axis_val, angle_val, mat_val := peek(vm, 4), peek(vm, 3), peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_vec3(pos_val) {
			runtime_error(vm, "add_static_box() first argument must be a vec3 (position).")
			return false
		}
		if !core.is_vec3(extent_val) {
			runtime_error(vm, "add_static_box() second argument must be a vec3 (half_extents).")
			return false
		}
		if !core.is_vec3(axis_val) {
			runtime_error(vm, "add_static_box() third argument must be a vec3 (axis).")
			return false
		}
		if !core.is_number(angle_val) {
			runtime_error(vm, "add_static_box() fourth argument must be a number (angle in degrees).")
			return false
		}
		if !core.is_int(mat_val) {
			runtime_error(vm, "add_static_box() fifth argument must be an integer (material_id).")
			return false
		}
		id, err, ok := physics_world_add_static_box(w, p_vec3_of(pos_val), p_vec3_of(extent_val), p_vec3_of(axis_val), core.as_float(angle_val), core.as_int(mat_val))
		if !ok {
			runtime_error(vm, "%s", err)
			return false
		}
		result = core.make_int_value(id, true)
	case "get_box_transform":
		if arg_count != 1 {
			runtime_error(vm, "get_box_transform() expects 1 argument (id).")
			return false
		}
		id_val := peek(vm, 0)
		if !core.is_int(id_val) {
			runtime_error(vm, "get_box_transform() argument must be an integer (id).")
			return false
		}
		bt, err, ok := physics_world_get_box_transform(w, core.as_int(id_val))
		if !ok {
			runtime_error(vm, "%s", err)
			return false
		}
		items: [dynamic]core.Value
		append(&items, make_vec3_result(vm, bt.pos), make_vec3_result(vm, bt.half_extents), make_vec3_result(vm, bt.axis), core.make_float_value(bt.angle))
		list := core.make_list_object(items, true)
		gc_track(vm, &list.obj)
		result = core.make_object_value(&list.obj)
	case "remove":
		if arg_count != 1 {
			runtime_error(vm, "remove() expects 1 argument (id).")
			return false
		}
		id_val := peek(vm, 0)
		if !core.is_int(id_val) {
			runtime_error(vm, "remove() argument must be an integer (id).")
			return false
		}
		if err, ok := physics_world_remove(w, core.as_int(id_val)); !ok {
			runtime_error(vm, "%s", err)
			return false
		}
		result = core.NIL_VALUE
	case "get_position":
		if arg_count != 1 {
			runtime_error(vm, "get_position() expects 1 argument (id).")
			return false
		}
		id_val := peek(vm, 0)
		if !core.is_int(id_val) {
			runtime_error(vm, "get_position() argument must be an integer (id).")
			return false
		}
		pos, err, ok := physics_world_get_position(w, core.as_int(id_val))
		if !ok {
			runtime_error(vm, "%s", err)
			return false
		}
		result = make_vec3_result(vm, pos)
	case "get_position_into":
		// Writes into an existing vec3 in place instead of allocating a
		// fresh one every call -- for a script syncing hundreds of bodies'
		// positions every frame (e.g. lox_examples/3d_balls_physics_shaders.lox),
		// get_position() means one new Vec3_Object per body per frame that's
		// immediately discarded; this lets a script keep one persistent vec3
		// per body instead.
		if arg_count != 2 {
			runtime_error(vm, "get_position_into() expects 2 arguments (id, vec3).")
			return false
		}
		id_into_val, target_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(id_into_val) {
			runtime_error(vm, "get_position_into() first argument must be an integer (id).")
			return false
		}
		if !core.is_vec3(target_val) {
			runtime_error(vm, "get_position_into() second argument must be a vec3.")
			return false
		}
		pos_into, err_into, ok_into := physics_world_get_position(w, core.as_int(id_into_val))
		if !ok_into {
			runtime_error(vm, "%s", err_into)
			return false
		}
		target := core.as_vec3(target_val)
		target.x = pos_into.x
		target.y = pos_into.y
		target.z = pos_into.z
		result = core.NIL_VALUE
	case "add_impulse":
		if arg_count != 2 {
			runtime_error(vm, "add_impulse() expects 2 arguments (id, impulse).")
			return false
		}
		id_val, impulse_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(id_val) {
			runtime_error(vm, "add_impulse() first argument must be an integer (id).")
			return false
		}
		if !core.is_vec3(impulse_val) {
			runtime_error(vm, "add_impulse() second argument must be a vec3 (impulse).")
			return false
		}
		if err, ok := physics_world_add_impulse(w, core.as_int(id_val), p_vec3_of(impulse_val)); !ok {
			runtime_error(vm, "%s", err)
			return false
		}
		result = core.NIL_VALUE
	case "step":
		if arg_count != 1 {
			runtime_error(vm, "step() expects 1 argument (dt).")
			return false
		}
		dt_val := peek(vm, 0)
		if !core.is_number(dt_val) {
			runtime_error(vm, "step() argument must be a number (dt).")
			return false
		}
		physics_world_step(w, core.as_float(dt_val))
		result = core.NIL_VALUE
	case "collisions":
		if arg_count != 0 {
			runtime_error(vm, "collisions() expects no arguments.")
			return false
		}
		items: [dynamic]core.Value
		for p in w.collisions {
			tuple_items: [dynamic]core.Value
			append(&tuple_items, core.make_int_value(p.a, true), core.make_int_value(p.b, true), make_vec3_result(vm, p.normal), core.make_float_value(p.impulse, true))
			tuple := core.make_list_object(tuple_items, true)
			gc_track(vm, &tuple.obj)
			append(&items, core.make_object_value(&tuple.obj))
		}
		list := core.make_list_object(items, true)
		gc_track(vm, &list.obj)
		result = core.make_object_value(&list.obj)
	case "count":
		if arg_count != 0 {
			runtime_error(vm, "count() expects no arguments.")
			return false
		}
		result = core.make_int_value(core.physics_world_count(w), true)
	case:
		runtime_error(vm, "Undefined PhysicsWorld method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
