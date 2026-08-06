package natives

import "../core"
import "../vm"
import "core:fmt"
import "core:math"
import "core:mem"

// physics: a hand-rolled 3D SoA sphere/box physics engine, no raylib
// dependency at all. Userdata_Object object kind (see
// core/obj_userdata.odin and this package's own README.md) -- struct,
// simulation logic (step, integrate, broad/narrow phase, resolve), and
// Lox-facing method dispatch all live together in this one file.
//
// One known limitation: Physics_Material.friction is stored and combined
// but never actually applied in resolve()'s collision response.

// P_Vec3 is purely an internal math type for the SoA simulation -- not
// exposed to Lox directly (positions/velocities/etc. cross the Lox
// boundary as core.Vec3 values, converted at the method-dispatch layer
// below). Named to avoid clashing with core.Vec3.
P_Vec3 :: struct {
	x, y, z: f64,
}

Shape_Kind :: enum u8 {
	Sphere,
	Box,
}

// Shape describes a body's collision volume. For .Sphere, only
// extent.x (radius) is meaningful. For .Box, extent holds half-extents
// per axis, and axis/angle orient it in world space (angle == 0 means
// axis-aligned). Box is only ever created by add_static_box -- there is
// no dynamic box constructor -- so every box in the simulation is
// static, and there is no box-box collision case anywhere (static-static
// pairs are skipped before a shape dispatch is even needed).
Shape :: struct {
	kind:   Shape_Kind,
	extent: P_Vec3,
	axis:   P_Vec3,
	angle:  f64, // degrees
}

// Physics_Material.friction is stored and combined the same way
// restitution is, but is never actually applied anywhere in resolve()'s
// collision response.
Physics_Material :: struct {
	restitution: f64,
	friction:    f64,
	damping:     f64,
}

Physics_Cell_Key :: struct {
	x, y, z: i32,
}

// Physics_Pair_Key is always constructed with a < b, so an unordered
// pair has exactly one key regardless of which body is passed first.
Physics_Pair_Key :: struct {
	a, b: int,
}

Collision_Pair :: struct {
	a, b:    int,
	normal:  P_Vec3,
	impulse: f64,
}

// Physics_World_Data: parallel (struct-of-arrays) body data, indexed by
// id == the index at insertion time. IDs are never reused (removal just
// tombstones active[id] = false).
Physics_World_Data :: struct {
	pos_x, pos_y, pos_z: [dynamic]f64,
	vel_x, vel_y, vel_z: [dynamic]f64,
	shapes:              [dynamic]Shape,
	material_id:         [dynamic]int,
	active:              [dynamic]bool,
	is_static:           [dynamic]bool,

	// static_ids caches the ids of static bodies as they're created, so
	// the dynamic-vs-static collision pass doesn't need to rescan
	// is_static every step. Static bodies bypass the grid entirely
	// rather than being inserted into it -- a single grid cell can't
	// represent a large platform's true extent, and multi-cell
	// insertion would cost proportional to a static body's size every
	// frame despite it never moving.
	static_ids: [dynamic]int,

	materials: [dynamic]Physics_Material,

	bounds_min, bounds_max: P_Vec3,
	gravity:                P_Vec3,
	cell_size:              f64,

	// grid buckets bodies by cell; used_cells lists the keys populated
	// during the last rebuild so the next call can clear just those
	// (re-slicing each bucket to length 0, keeping its backing array)
	// instead of deleting every map entry and reallocating fresh slices.
	grid:       map[Physics_Cell_Key][dynamic]int,
	used_cells: [dynamic]Physics_Cell_Key,

	collisions: [dynamic]Collision_Pair,

	// contact_sets is a ping-pong pair of persistent maps: each step(),
	// the buffer that was "prev" two frames ago becomes this frame's
	// "curr" (cleared in place, not reallocated). A collision is only
	// reported the frame a pair starts touching -- resting/still-
	// touching pairs are silent after that first frame.
	contact_sets: [2]map[Physics_Pair_Key]bool,
	contacts_cur: int,
}

@(private = "file")
physics_world_vtable := core.Userdata_Vtable {
	tag       = "PhysicsWorld",
	free      = physics_world_data_free,
	to_string = physics_world_to_string,
	size      = physics_world_data_size,
	invoke    = physics_world_invoke,
}

@(private = "file")
make_physics_world_data :: proc(min, max: P_Vec3, cell_size: f64, gravity: P_Vec3) -> ^Physics_World_Data {
	w := new(Physics_World_Data)
	w.bounds_min = min
	w.bounds_max = max
	w.cell_size = cell_size
	w.gravity = gravity
	w.grid = make(map[Physics_Cell_Key][dynamic]int)
	w.contact_sets[0] = make(map[Physics_Pair_Key]bool)
	w.contact_sets[1] = make(map[Physics_Pair_Key]bool)
	return w
}

// physics_world_count returns the number of currently-active bodies.
@(private = "file")
physics_world_count :: proc(w: ^Physics_World_Data) -> int {
	n := 0
	for a in w.active {
		if a {
			n += 1
		}
	}
	return n
}

// No external (GPU/OS) resource -- just every internal [dynamic]/map
// allocation, which free(w) alone wouldn't reach (each is its own
// separate backing allocation).
@(private = "file")
physics_world_data_free :: proc(data: rawptr) {
	w := cast(^Physics_World_Data)data
	delete(w.pos_x)
	delete(w.pos_y)
	delete(w.pos_z)
	delete(w.vel_x)
	delete(w.vel_y)
	delete(w.vel_z)
	delete(w.shapes)
	delete(w.material_id)
	delete(w.active)
	delete(w.is_static)
	delete(w.static_ids)
	delete(w.materials)
	for _, bucket in w.grid {
		delete(bucket)
	}
	delete(w.grid)
	delete(w.used_cells)
	delete(w.collisions)
	delete(w.contact_sets[0])
	delete(w.contact_sets[1])
	free(w)
}

@(private = "file")
physics_world_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	w := cast(^Physics_World_Data)data
	return fmt.aprintf("<PhysicsWorld [%d bodies]>", physics_world_count(w), allocator = allocator)
}

// Dominated by the SoA body slices -- a few thousand bodies is a real
// amount of memory the GC's heap-growth heuristic should actually see.
@(private = "file")
physics_world_data_size :: proc(data: rawptr) -> int {
	w := cast(^Physics_World_Data)data
	return size_of(Physics_World_Data) + len(w.pos_x) * (6 * size_of(f64) + size_of(Shape) + size_of(int) + 2 * size_of(bool))
}

@(private)
register_physics :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "physics")
	vm.define_builtin(v, "physics", "physics_world", physics_world_builtin)
}

@(private = "file")
physics_world_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 4 {
		vm.runtime_error(v, "physics_world() expects 4 arguments (min, max, cell_size, gravity).")
		return core.NIL_VALUE
	}
	min_val := v.stack[arg_stack_ptr]
	max_val := v.stack[arg_stack_ptr + 1]
	cell_size_val := v.stack[arg_stack_ptr + 2]
	gravity_val := v.stack[arg_stack_ptr + 3]

	if !core.is_vec3(min_val) {
		vm.runtime_error(v, "physics_world() first argument must be a vec3 (bounds min).")
		return core.NIL_VALUE
	}
	if !core.is_vec3(max_val) {
		vm.runtime_error(v, "physics_world() second argument must be a vec3 (bounds max).")
		return core.NIL_VALUE
	}
	if !core.is_number(cell_size_val) {
		vm.runtime_error(v, "physics_world() third argument must be a number (cell_size).")
		return core.NIL_VALUE
	}
	if !core.is_vec3(gravity_val) {
		vm.runtime_error(v, "physics_world() fourth argument must be a vec3 (gravity).")
		return core.NIL_VALUE
	}

	min_v := core.as_vec3(min_val)
	max_v := core.as_vec3(max_val)
	gravity_v := core.as_vec3(gravity_val)

	data := make_physics_world_data(
		P_Vec3{min_v.x, min_v.y, min_v.z},
		P_Vec3{max_v.x, max_v.y, max_v.z},
		core.as_float(cell_size_val),
		P_Vec3{gravity_v.x, gravity_v.y, gravity_v.z},
	)
	o := core.make_userdata_object(&physics_world_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

// ---------------------------------------------------------------------
// Simulation: integration + broad phase + narrow phase

// rotate_vec rotates v around axis (not required to be unit-length; a
// near-zero axis is treated as "no rotation") by angle_deg degrees,
// via Rodrigues' rotation formula.
@(private = "file")
rotate_vec :: proc(v, axis: P_Vec3, angle_deg: f64) -> P_Vec3 {
	length := math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
	if length < 1e-12 {
		return v
	}
	a := P_Vec3{axis.x / length, axis.y / length, axis.z / length}

	rad := angle_deg * math.PI / 180
	cos_a := math.cos(rad)
	sin_a := math.sin(rad)
	dot := v.x * a.x + v.y * a.y + v.z * a.z
	cross := P_Vec3{
		a.y * v.z - a.z * v.y,
		a.z * v.x - a.x * v.z,
		a.x * v.y - a.y * v.x,
	}
	return P_Vec3{
		v.x * cos_a + cross.x * sin_a + a.x * dot * (1 - cos_a),
		v.y * cos_a + cross.y * sin_a + a.y * dot * (1 - cos_a),
		v.z * cos_a + cross.z * sin_a + a.z * dot * (1 - cos_a),
	}
}

@(private = "file")
combine_materials :: proc(a, b: Physics_Material) -> (restitution: f64) {
	return math.sqrt(a.restitution * b.restitution)
}

@(private = "file")
physics_world_add_material :: proc(w: ^Physics_World_Data, restitution, friction, damping: f64) -> int {
	append(&w.materials, Physics_Material{restitution, friction, damping})
	return len(w.materials) - 1
}

// append_body is the common tail of add/add_static_box: push one entry
// onto every parallel SoA slice, keeping them in lockstep.
@(private = "file")
physics_world_append_body :: proc(w: ^Physics_World_Data, pos, vel: P_Vec3, shape: Shape, material_id: int, is_static: bool) -> int {
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

@(private = "file")
physics_world_add :: proc(w: ^Physics_World_Data, pos, vel: P_Vec3, radius: f64, material_id: int) -> (id: int, err: string, ok: bool) {
	if material_id < 0 || material_id >= len(w.materials) {
		return 0, "invalid material id", false
	}
	shape := Shape{kind = .Sphere, extent = P_Vec3{radius, 0, 0}}
	return physics_world_append_body(w, pos, vel, shape, material_id, false), "", true
}

// add_static_box creates a fixed, optionally rotated box (ramps,
// shelves, platforms). Orientation is set once here and never updated
// -- no velocity argument, signalling fixed-ness without inspecting a
// flag.
@(private = "file")
physics_world_add_static_box :: proc(w: ^Physics_World_Data, pos, half_extents, axis: P_Vec3, angle: f64, material_id: int) -> (id: int, err: string, ok: bool) {
	if material_id < 0 || material_id >= len(w.materials) {
		return 0, "invalid material id", false
	}
	shape := Shape{kind = .Box, extent = half_extents, axis = axis, angle = angle}
	return physics_world_append_body(w, pos, P_Vec3{}, shape, material_id, true), "", true
}

@(private = "file")
Box_Transform :: struct {
	pos, half_extents, axis: P_Vec3,
	angle:                   f64,
}

// get_box_transform is what Lox reads box orientation back from, so a
// rendered box always matches exactly what physics collided against.
@(private = "file")
physics_world_get_box_transform :: proc(w: ^Physics_World_Data, id: int) -> (bt: Box_Transform, err: string, ok: bool) {
	if id < 0 || id >= len(w.pos_x) || !w.active[id] {
		return {}, "index out of range or inactive", false
	}
	if w.shapes[id].kind != .Box {
		return {}, "body is not a box", false
	}
	s := w.shapes[id]
	return Box_Transform{
		pos = P_Vec3{w.pos_x[id], w.pos_y[id], w.pos_z[id]},
		half_extents = s.extent,
		axis = s.axis,
		angle = s.angle,
	}, "", true
}

@(private = "file")
physics_world_remove :: proc(w: ^Physics_World_Data, id: int) -> (err: string, ok: bool) {
	if id < 0 || id >= len(w.active) {
		return "index out of range", false
	}
	w.active[id] = false
	return "", true
}

@(private = "file")
physics_world_get_position :: proc(w: ^Physics_World_Data, id: int) -> (pos: P_Vec3, err: string, ok: bool) {
	if id < 0 || id >= len(w.pos_x) || !w.active[id] {
		return {}, "index out of range or inactive", false
	}
	return P_Vec3{w.pos_x[id], w.pos_y[id], w.pos_z[id]}, "", true
}

// add_impulse applies an instantaneous velocity change to a single
// body -- the low-level primitive Lox uses for explosion/force effects:
// the distance check, falloff curve, and "which bodies are affected"
// loop all stay in Lox, calling this once per affected body. No mass
// division -- matches the equal-mass assumption used in resolve().
@(private = "file")
physics_world_add_impulse :: proc(w: ^Physics_World_Data, id: int, impulse: P_Vec3) -> (err: string, ok: bool) {
	if id < 0 || id >= len(w.pos_x) || !w.active[id] {
		return "index out of range or inactive", false
	}
	w.vel_x[id] += impulse.x
	w.vel_y[id] += impulse.y
	w.vel_z[id] += impulse.z
	return "", true
}

@(private = "file")
physics_world_step :: proc(w: ^Physics_World_Data, dt: f64) {
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
physics_world_integrate :: proc(w: ^Physics_World_Data, dt: f64) {
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
physics_world_boundary_collisions :: proc(w: ^Physics_World_Data) {
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
physics_world_cell_of :: proc(w: ^Physics_World_Data, i: int) -> Physics_Cell_Key {
	return Physics_Cell_Key{
		x = i32(math.floor(w.pos_x[i] / w.cell_size)),
		y = i32(math.floor(w.pos_y[i] / w.cell_size)),
		z = i32(math.floor(w.pos_z[i] / w.cell_size)),
	}
}

@(private = "file")
physics_world_rebuild_grid :: proc(w: ^Physics_World_Data) {
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
physics_world_narrow_phase :: proc(w: ^Physics_World_Data) {
	for i in 0 ..< len(w.pos_x) {
		if !w.active[i] || w.is_static[i] {
			continue
		}
		base := physics_world_cell_of(w, i)

		for dz: i32 = -1; dz <= 1; dz += 1 {
			for dy: i32 = -1; dy <= 1; dy += 1 {
				for dx: i32 = -1; dx <= 1; dx += 1 {
					k := Physics_Cell_Key{base.x + dx, base.y + dy, base.z + dz}
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
						physics_world_check_and_resolve(w, i, j, Physics_Pair_Key{i, j})
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
physics_world_resolve_static_pairs :: proc(w: ^Physics_World_Data) {
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
			physics_world_check_and_resolve(w, a, b, Physics_Pair_Key{a, b})
		}
	}
}

@(private = "file")
physics_world_check_and_resolve :: proc(w: ^Physics_World_Data, i, j: int, pk: Physics_Pair_Key) {
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
physics_world_collide :: proc(w: ^Physics_World_Data, i, j: int) -> (normal: P_Vec3, overlap: f64, ok: bool) {
	si, sj := w.shapes[i].kind, w.shapes[j].kind
	switch {
	case si == .Sphere && sj == .Sphere:
		return physics_world_collide_sphere_sphere(w, i, j)
	case si == .Sphere: // sj == .Box
		n, o, cok := physics_world_collide_sphere_box(w, i, j)
		if !cok {
			return {}, 0, false
		}
		return P_Vec3{-n.x, -n.y, -n.z}, o, true // box->sphere flipped to i->j
	case:
		// si == .Box, sj == .Sphere
		return physics_world_collide_sphere_box(w, j, i) // box(i)->sphere(j) is already i->j
	}
}

@(private = "file")
physics_world_collide_sphere_sphere :: proc(w: ^Physics_World_Data, i, j: int) -> (P_Vec3, f64, bool) {
	dx := w.pos_x[j] - w.pos_x[i]
	dy := w.pos_y[j] - w.pos_y[i]
	dz := w.pos_z[j] - w.pos_z[i]
	dist_sq := dx * dx + dy * dy + dz * dz
	min_dist := w.shapes[i].extent.x + w.shapes[j].extent.x

	if dist_sq >= min_dist * min_dist || dist_sq < 1e-12 {
		return {}, 0, false
	}

	dist := math.sqrt(dist_sq)
	return P_Vec3{dx / dist, dy / dist, dz / dist}, min_dist - dist, true
}

// collide_sphere_box tests a sphere against a (possibly rotated) box:
// the sphere's center is rotated into the box's local frame (inverse
// rotation), clamped to the box's half-extents to find the closest
// surface point, then rotated back to world space. angle == 0
// degenerates to the axis-aligned case with no extra cost. Returns the
// normal box-surface -> sphere-center.
@(private = "file")
physics_world_collide_sphere_box :: proc(w: ^Physics_World_Data, sphere_idx, box_idx: int) -> (P_Vec3, f64, bool) {
	box := w.shapes[box_idx]
	r := w.shapes[sphere_idx].extent.x

	local := P_Vec3{
		w.pos_x[sphere_idx] - w.pos_x[box_idx],
		w.pos_y[sphere_idx] - w.pos_y[box_idx],
		w.pos_z[sphere_idx] - w.pos_z[box_idx],
	}
	if box.angle != 0 {
		local = rotate_vec(local, box.axis, -box.angle)
	}

	clamped := P_Vec3{
		clamp(local.x, -box.extent.x, box.extent.x),
		clamp(local.y, -box.extent.y, box.extent.y),
		clamp(local.z, -box.extent.z, box.extent.z),
	}

	closest := clamped
	if box.angle != 0 {
		closest = rotate_vec(closest, box.axis, box.angle)
	}
	closest_world := P_Vec3{
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
		return rotate_vec(P_Vec3{0, 1, 0}, box.axis, box.angle), r, true
	}

	dist := math.sqrt(dist_sq)
	return P_Vec3{dx / dist, dy / dist, dz / dist}, r - dist, true
}

// resolve applies positional correction and an impulse along normal
// (pointing i->j). When one side is static, all correction and impulse
// go to the dynamic side -- the correct limit of the general two-body
// formula as one mass -> infinity, not a bolt-on special case.
@(private = "file")
physics_world_resolve :: proc(w: ^Physics_World_Data, i, j: int, pk: Physics_Pair_Key, normal: P_Vec3, overlap: f64) {
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
			append(&w.collisions, Collision_Pair{
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
p_vec3_of :: proc(v: core.Value) -> P_Vec3 {
	vv := core.as_vec3(v)
	return P_Vec3{vv.x, vv.y, vv.z}
}

@(private = "file")
make_vec3_result :: proc(v: ^vm.VM, p: P_Vec3) -> core.Value {
	return core.make_vec3_value(p.x, p.y, p.z)
}

@(private = "file")
physics_world_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	w := cast(^Physics_World_Data)data
	result: core.Value
	switch name {
	case "add_material":
		if arg_count != 3 {
			vm.runtime_error(v, "add_material() expects 3 arguments (restitution, friction, damping).")
			return false
		}
		r_val, f_val, d_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_number(r_val) || !core.is_number(f_val) || !core.is_number(d_val) {
			vm.runtime_error(v, "add_material() arguments must be numbers.")
			return false
		}
		id := physics_world_add_material(w, core.as_float(r_val), core.as_float(f_val), core.as_float(d_val))
		result = core.make_int_value(id, true)
	case "add":
		if arg_count != 4 {
			vm.runtime_error(v, "add() expects 4 arguments (position, velocity, radius, material_id).")
			return false
		}
		pos_val, vel_val, radius_val, mat_val := vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) {
			vm.runtime_error(v, "add() first argument must be a vec3 (position).")
			return false
		}
		if !core.is_vec3(vel_val) {
			vm.runtime_error(v, "add() second argument must be a vec3 (velocity).")
			return false
		}
		if !core.is_number(radius_val) {
			vm.runtime_error(v, "add() third argument must be a number (radius).")
			return false
		}
		if !core.is_int(mat_val) {
			vm.runtime_error(v, "add() fourth argument must be an integer (material_id).")
			return false
		}
		id, err, ok := physics_world_add(w, p_vec3_of(pos_val), p_vec3_of(vel_val), core.as_float(radius_val), core.as_int(mat_val))
		if !ok {
			vm.runtime_error(v, "%s", err)
			return false
		}
		result = core.make_int_value(id, true)
	case "add_static_box":
		if arg_count != 5 {
			vm.runtime_error(v, "add_static_box() expects 5 arguments (position, half_extents, axis, angle, material_id).")
			return false
		}
		pos_val, extent_val, axis_val, angle_val, mat_val := vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) {
			vm.runtime_error(v, "add_static_box() first argument must be a vec3 (position).")
			return false
		}
		if !core.is_vec3(extent_val) {
			vm.runtime_error(v, "add_static_box() second argument must be a vec3 (half_extents).")
			return false
		}
		if !core.is_vec3(axis_val) {
			vm.runtime_error(v, "add_static_box() third argument must be a vec3 (axis).")
			return false
		}
		if !core.is_number(angle_val) {
			vm.runtime_error(v, "add_static_box() fourth argument must be a number (angle in degrees).")
			return false
		}
		if !core.is_int(mat_val) {
			vm.runtime_error(v, "add_static_box() fifth argument must be an integer (material_id).")
			return false
		}
		id, err, ok := physics_world_add_static_box(w, p_vec3_of(pos_val), p_vec3_of(extent_val), p_vec3_of(axis_val), core.as_float(angle_val), core.as_int(mat_val))
		if !ok {
			vm.runtime_error(v, "%s", err)
			return false
		}
		result = core.make_int_value(id, true)
	case "get_box_transform":
		if arg_count != 1 {
			vm.runtime_error(v, "get_box_transform() expects 1 argument (id).")
			return false
		}
		id_val := vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "get_box_transform() argument must be an integer (id).")
			return false
		}
		bt, err, ok := physics_world_get_box_transform(w, core.as_int(id_val))
		if !ok {
			vm.runtime_error(v, "%s", err)
			return false
		}
		items: [dynamic]core.Value
		append(&items, make_vec3_result(v, bt.pos), make_vec3_result(v, bt.half_extents), make_vec3_result(v, bt.axis), core.make_float_value(bt.angle))
		list := core.make_list_object(items, true)
		vm.gc_track(v, &list.obj)
		result = core.make_object_value(&list.obj)
	case "remove":
		if arg_count != 1 {
			vm.runtime_error(v, "remove() expects 1 argument (id).")
			return false
		}
		id_val := vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "remove() argument must be an integer (id).")
			return false
		}
		if err, ok := physics_world_remove(w, core.as_int(id_val)); !ok {
			vm.runtime_error(v, "%s", err)
			return false
		}
		result = core.NIL_VALUE
	case "get_position":
		if arg_count != 1 {
			vm.runtime_error(v, "get_position() expects 1 argument (id).")
			return false
		}
		id_val := vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "get_position() argument must be an integer (id).")
			return false
		}
		pos, err, ok := physics_world_get_position(w, core.as_int(id_val))
		if !ok {
			vm.runtime_error(v, "%s", err)
			return false
		}
		result = make_vec3_result(v, pos)
	case "add_impulse":
		if arg_count != 2 {
			vm.runtime_error(v, "add_impulse() expects 2 arguments (id, impulse).")
			return false
		}
		id_val, impulse_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "add_impulse() first argument must be an integer (id).")
			return false
		}
		if !core.is_vec3(impulse_val) {
			vm.runtime_error(v, "add_impulse() second argument must be a vec3 (impulse).")
			return false
		}
		if err, ok := physics_world_add_impulse(w, core.as_int(id_val), p_vec3_of(impulse_val)); !ok {
			vm.runtime_error(v, "%s", err)
			return false
		}
		result = core.NIL_VALUE
	case "step":
		if arg_count != 1 {
			vm.runtime_error(v, "step() expects 1 argument (dt).")
			return false
		}
		dt_val := vm.peek(v, 0)
		if !core.is_number(dt_val) {
			vm.runtime_error(v, "step() argument must be a number (dt).")
			return false
		}
		physics_world_step(w, core.as_float(dt_val))
		result = core.NIL_VALUE
	case "collisions":
		if arg_count != 0 {
			vm.runtime_error(v, "collisions() expects no arguments.")
			return false
		}
		items: [dynamic]core.Value
		for p in w.collisions {
			tuple_items: [dynamic]core.Value
			append(&tuple_items, core.make_int_value(p.a, true), core.make_int_value(p.b, true), make_vec3_result(v, p.normal), core.make_float_value(p.impulse, true))
			tuple := core.make_list_object(tuple_items, true)
			vm.gc_track(v, &tuple.obj)
			append(&items, core.make_object_value(&tuple.obj))
		}
		list := core.make_list_object(items, true)
		vm.gc_track(v, &list.obj)
		result = core.make_object_value(&list.obj)
	case "count":
		if arg_count != 0 {
			vm.runtime_error(v, "count() expects no arguments.")
			return false
		}
		result = core.make_int_value(physics_world_count(w), true)
	case:
		vm.runtime_error(v, "Undefined PhysicsWorld method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
