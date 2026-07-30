package core

// Physics_World_Object: a hand-rolled 3D SoA sphere/box physics
// simulation -- no raylib dependency at all. Struct and pure data
// accessors live here; the real simulation logic (step, integrate,
// broad/narrow phase, resolve) lives in vm/physics_world.odin and
// mutates this struct's fields directly -- same split as
// Regex_Pattern_Object/Process_Object (struct in core, behavior in vm),
// since only vm/call.odin's invoke() can wire in a new Object_Type case.

// P_Vec3 is purely an internal math type for the SoA simulation -- not
// exposed to Lox directly (positions/velocities/etc. cross the Lox
// boundary as core.Vec3_Object, converted at vm/physics_world.odin's
// method-dispatch layer). Named to avoid clashing with Vec3_Object.
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

// Physics_World_Object: parallel (struct-of-arrays) body data, indexed
// by id == the index at insertion time. IDs are never reused (removal
// just tombstones active[id] = false).
Physics_World_Object :: struct {
	using obj: Obj,

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

make_physics_world_object :: proc(min, max: P_Vec3, cell_size: f64, gravity: P_Vec3) -> ^Physics_World_Object {
	o := new(Physics_World_Object)
	o.obj.type = .Physics_World
	o.bounds_min = min
	o.bounds_max = max
	o.cell_size = cell_size
	o.gravity = gravity
	o.grid = make(map[Physics_Cell_Key][dynamic]int)
	o.contact_sets[0] = make(map[Physics_Pair_Key]bool)
	o.contact_sets[1] = make(map[Physics_Pair_Key]bool)
	return o
}

// physics_world_count returns the number of currently-active bodies --
// pure data access, needed by object_to_string (core can't import vm)
// and reused by vm/physics_world.odin's count() method dispatch.
physics_world_count :: proc(w: ^Physics_World_Object) -> int {
	n := 0
	for a in w.active {
		if a {
			n += 1
		}
	}
	return n
}
