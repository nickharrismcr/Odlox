package natives

import "../core"
import "../vm"
import "core:math"
import b2 "vendor:box2d"

// box2d: a thin wrapper around Odin's vendor:box2d bindings (Box2D v3.1.1,
// the ID-handle-based C API, not the older pointer-based v2 API). Exposes a
// convenient subset, not the full surface -- no joints, raycasting,
// debug-draw callback, or capsule/full-polygon/chain shapes. Complements,
// not replaces, the hand-rolled `physics` module (physics.odin) -- that one
// is untouched by this file.
//
// Bodies are plain int handles issued by the World object (mirrors
// physics.odin's own `add(...) -> id` / `get_position(id)` convention), not
// first-class Userdata_Objects -- consistent with the existing module, and
// sidesteps any GC-lifetime coupling with Box2D's own per-shape userData
// pointer (see box2d_world_add_circle/add_box's use of it below, which is
// purely an internal bookkeeping mechanism for collisions(), not something
// Lox ever sees directly).

Box2D_Body_Entry :: struct {
	body_id: b2.BodyId,
	active:  bool, // tombstoned on remove(), ids never reused -- same convention physics.odin's own `active` array uses
}

// Box2D_World_Data: one Box2D world plus the int-handle -> BodyId table
// Lox's `add_circle`/`add_box` hand out ids into.
Box2D_World_Data :: struct {
	world_id: b2.WorldId,
	bodies:   [dynamic]Box2D_Body_Entry, // index = the int handle Lox scripts hold
}

@(private = "file")
box2d_world_vtable := core.Userdata_Vtable {
	tag    = "Box2DWorld",
	free   = box2d_world_data_free,
	invoke = box2d_world_invoke,
}

// No external resource beyond the world itself -- destroying it cascades to
// every body/shape it owns, so there's no need to walk w.bodies here.
@(private = "file")
box2d_world_data_free :: proc(data: rawptr) {
	w := cast(^Box2D_World_Data)data
	b2.DestroyWorld(w.world_id)
	delete(w.bodies)
	free(w)
}

@(private)
register_box2d :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "box2d")
	vm.define_builtin(v, "box2d", "world", box2d_world_builtin)
}

@(private = "file")
box2d_world_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "world() expects 1 argument (gravity).")
		return core.NIL_VALUE
	}
	gravity_val := v.stack[arg_stack_ptr]
	if !core.is_vec2(gravity_val) {
		vm.runtime_error(v, "world() argument must be a vec2 (gravity).")
		return core.NIL_VALUE
	}

	world_def := b2.DefaultWorldDef()
	world_def.gravity = box2d_vec2_of(gravity_val)

	data := new(Box2D_World_Data)
	data.world_id = b2.CreateWorld(world_def)
	o := core.make_userdata_object(&box2d_world_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

// ---------------------------------------------------------------------
// Marshaling helpers

@(private = "file")
box2d_vec2_of :: proc(v: core.Value) -> b2.Vec2 {
	vv := core.as_vec2(v)
	return b2.Vec2{f32(vv.x), f32(vv.y)}
}

@(private = "file")
box2d_vec2_result :: proc(v: ^vm.VM, vec: b2.Vec2) -> core.Value {
	return core.make_vec2_value(f64(vec.x), f64(vec.y))
}

@(private = "file")
box2d_body_type_of :: proc(n: int) -> (b2.BodyType, bool) {
	switch n {
	case 0:
		return .staticBody, true
	case 1:
		return .kinematicBody, true
	case 2:
		return .dynamicBody, true
	}
	return .staticBody, false
}

@(private = "file")
box2d_world_valid_id :: proc(w: ^Box2D_World_Data, id: int) -> bool {
	return id >= 0 && id < len(w.bodies) && w.bodies[id].active
}

// ---------------------------------------------------------------------
// Body/shape creation

@(private = "file")
box2d_world_add_circle :: proc(w: ^Box2D_World_Data, pos: b2.Vec2, radius: f32, body_type: b2.BodyType, density, friction, restitution: f32) -> int {
	body_def := b2.DefaultBodyDef()
	body_def.type = body_type
	body_def.position = pos
	body_id := b2.CreateBody(w.world_id, body_def)

	id := len(w.bodies)
	append(&w.bodies, Box2D_Body_Entry{body_id = body_id, active = true})

	shape_def := b2.DefaultShapeDef()
	shape_def.density = density
	shape_def.material.friction = friction
	shape_def.material.restitution = restitution
	shape_def.enableContactEvents = true
	// +1: id 0 must not collide with a null/unset userData read as 0 by
	// collisions() below.
	shape_def.userData = rawptr(uintptr(id + 1))
	circle := b2.Circle{center = {0, 0}, radius = radius}
	_ = b2.CreateCircleShape(body_id, shape_def, &circle)

	return id
}

@(private = "file")
box2d_world_add_box :: proc(w: ^Box2D_World_Data, pos: b2.Vec2, half_extents: b2.Vec2, angle: f32, body_type: b2.BodyType, density, friction, restitution: f32) -> int {
	body_def := b2.DefaultBodyDef()
	body_def.type = body_type
	body_def.position = pos
	body_def.rotation = b2.MakeRot(angle)
	body_id := b2.CreateBody(w.world_id, body_def)

	id := len(w.bodies)
	append(&w.bodies, Box2D_Body_Entry{body_id = body_id, active = true})

	shape_def := b2.DefaultShapeDef()
	shape_def.density = density
	shape_def.material.friction = friction
	shape_def.material.restitution = restitution
	shape_def.enableContactEvents = true
	shape_def.userData = rawptr(uintptr(id + 1))
	box := b2.MakeBox(half_extents.x, half_extents.y)
	_ = b2.CreatePolygonShape(body_id, shape_def, &box)

	return id
}

// ---------------------------------------------------------------------
// Lox-facing method dispatch

@(private = "file")
box2d_world_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	w := cast(^Box2D_World_Data)data
	result: core.Value
	switch name {
	case "add_circle":
		if arg_count != 6 {
			vm.runtime_error(v, "add_circle() expects 6 arguments (pos, radius, body_type, density, friction, restitution).")
			return false
		}
		pos_val, radius_val, type_val, density_val, friction_val, restitution_val :=
			vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec2(pos_val) {
			vm.runtime_error(v, "add_circle() first argument must be a vec2 (pos).")
			return false
		}
		if !core.is_number(radius_val) {
			vm.runtime_error(v, "add_circle() second argument must be a number (radius).")
			return false
		}
		if !core.is_int(type_val) {
			vm.runtime_error(v, "add_circle() third argument must be an integer (body_type: 0=static, 1=kinematic, 2=dynamic).")
			return false
		}
		if !core.is_number(density_val) || !core.is_number(friction_val) || !core.is_number(restitution_val) {
			vm.runtime_error(v, "add_circle() density/friction/restitution arguments must be numbers.")
			return false
		}
		body_type, type_ok := box2d_body_type_of(core.as_int(type_val))
		if !type_ok {
			vm.runtime_error(v, "add_circle() body_type must be 0 (static), 1 (kinematic), or 2 (dynamic).")
			return false
		}
		id := box2d_world_add_circle(
			w,
			box2d_vec2_of(pos_val),
			f32(core.as_float(radius_val)),
			body_type,
			f32(core.as_float(density_val)),
			f32(core.as_float(friction_val)),
			f32(core.as_float(restitution_val)),
		)
		result = core.make_int_value(id, true)
	case "add_box":
		if arg_count != 7 {
			vm.runtime_error(v, "add_box() expects 7 arguments (pos, half_extents, angle, body_type, density, friction, restitution).")
			return false
		}
		pos_val, extent_val, angle_val, type_val, density_val, friction_val, restitution_val :=
			vm.peek(v, 6), vm.peek(v, 5), vm.peek(v, 4), vm.peek(v, 3), vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec2(pos_val) {
			vm.runtime_error(v, "add_box() first argument must be a vec2 (pos).")
			return false
		}
		if !core.is_vec2(extent_val) {
			vm.runtime_error(v, "add_box() second argument must be a vec2 (half_extents).")
			return false
		}
		if !core.is_number(angle_val) {
			vm.runtime_error(v, "add_box() third argument must be a number (angle in radians).")
			return false
		}
		if !core.is_int(type_val) {
			vm.runtime_error(v, "add_box() fourth argument must be an integer (body_type: 0=static, 1=kinematic, 2=dynamic).")
			return false
		}
		if !core.is_number(density_val) || !core.is_number(friction_val) || !core.is_number(restitution_val) {
			vm.runtime_error(v, "add_box() density/friction/restitution arguments must be numbers.")
			return false
		}
		body_type, type_ok := box2d_body_type_of(core.as_int(type_val))
		if !type_ok {
			vm.runtime_error(v, "add_box() body_type must be 0 (static), 1 (kinematic), or 2 (dynamic).")
			return false
		}
		id := box2d_world_add_box(
			w,
			box2d_vec2_of(pos_val),
			box2d_vec2_of(extent_val),
			f32(core.as_float(angle_val)),
			body_type,
			f32(core.as_float(density_val)),
			f32(core.as_float(friction_val)),
			f32(core.as_float(restitution_val)),
		)
		result = core.make_int_value(id, true)
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
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		b2.DestroyBody(w.bodies[id].body_id)
		w.bodies[id].active = false
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
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		result = box2d_vec2_result(v, b2.Body_GetPosition(w.bodies[id].body_id))
	case "get_rotation":
		if arg_count != 1 {
			vm.runtime_error(v, "get_rotation() expects 1 argument (id).")
			return false
		}
		id_val := vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "get_rotation() argument must be an integer (id).")
			return false
		}
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		rot := b2.Body_GetRotation(w.bodies[id].body_id)
		result = core.make_float_value(math.atan2(f64(rot.s), f64(rot.c)), true)
	case "get_velocity":
		if arg_count != 1 {
			vm.runtime_error(v, "get_velocity() expects 1 argument (id).")
			return false
		}
		id_val := vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "get_velocity() argument must be an integer (id).")
			return false
		}
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		result = box2d_vec2_result(v, b2.Body_GetLinearVelocity(w.bodies[id].body_id))
	case "get_angular_velocity":
		if arg_count != 1 {
			vm.runtime_error(v, "get_angular_velocity() expects 1 argument (id).")
			return false
		}
		id_val := vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "get_angular_velocity() argument must be an integer (id).")
			return false
		}
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		result = core.make_float_value(f64(b2.Body_GetAngularVelocity(w.bodies[id].body_id)), true)
	case "set_velocity":
		if arg_count != 2 {
			vm.runtime_error(v, "set_velocity() expects 2 arguments (id, vel).")
			return false
		}
		id_val, vel_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "set_velocity() first argument must be an integer (id).")
			return false
		}
		if !core.is_vec2(vel_val) {
			vm.runtime_error(v, "set_velocity() second argument must be a vec2 (vel).")
			return false
		}
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		b2.Body_SetLinearVelocity(w.bodies[id].body_id, box2d_vec2_of(vel_val))
		result = core.NIL_VALUE
	case "apply_force":
		if arg_count != 2 {
			vm.runtime_error(v, "apply_force() expects 2 arguments (id, force).")
			return false
		}
		id_val, force_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "apply_force() first argument must be an integer (id).")
			return false
		}
		if !core.is_vec2(force_val) {
			vm.runtime_error(v, "apply_force() second argument must be a vec2 (force).")
			return false
		}
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		b2.Body_ApplyForceToCenter(w.bodies[id].body_id, box2d_vec2_of(force_val), true)
		result = core.NIL_VALUE
	case "apply_impulse":
		if arg_count != 2 {
			vm.runtime_error(v, "apply_impulse() expects 2 arguments (id, impulse).")
			return false
		}
		id_val, impulse_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "apply_impulse() first argument must be an integer (id).")
			return false
		}
		if !core.is_vec2(impulse_val) {
			vm.runtime_error(v, "apply_impulse() second argument must be a vec2 (impulse).")
			return false
		}
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		b2.Body_ApplyLinearImpulseToCenter(w.bodies[id].body_id, box2d_vec2_of(impulse_val), true)
		result = core.NIL_VALUE
	case "apply_torque":
		if arg_count != 2 {
			vm.runtime_error(v, "apply_torque() expects 2 arguments (id, torque).")
			return false
		}
		id_val, torque_val := vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_int(id_val) {
			vm.runtime_error(v, "apply_torque() first argument must be an integer (id).")
			return false
		}
		if !core.is_number(torque_val) {
			vm.runtime_error(v, "apply_torque() second argument must be a number (torque).")
			return false
		}
		id := core.as_int(id_val)
		if !box2d_world_valid_id(w, id) {
			vm.runtime_error(v, "index out of range or inactive")
			return false
		}
		b2.Body_ApplyTorque(w.bodies[id].body_id, f32(core.as_float(torque_val)), true)
		result = core.NIL_VALUE
	case "set_gravity":
		if arg_count != 1 {
			vm.runtime_error(v, "set_gravity() expects 1 argument (gravity).")
			return false
		}
		gravity_val := vm.peek(v, 0)
		if !core.is_vec2(gravity_val) {
			vm.runtime_error(v, "set_gravity() argument must be a vec2 (gravity).")
			return false
		}
		b2.World_SetGravity(w.world_id, box2d_vec2_of(gravity_val))
		result = core.NIL_VALUE
	case "get_gravity":
		if arg_count != 0 {
			vm.runtime_error(v, "get_gravity() expects no arguments.")
			return false
		}
		result = box2d_vec2_result(v, b2.World_GetGravity(w.world_id))
	case "step":
		if arg_count != 1 && arg_count != 2 {
			vm.runtime_error(v, "step() expects 1 or 2 arguments (dt, [substeps]).")
			return false
		}
		dt_val := vm.peek(v, arg_count - 1)
		if !core.is_number(dt_val) {
			vm.runtime_error(v, "step() dt argument must be a number.")
			return false
		}
		substeps := 4
		if arg_count == 2 {
			substeps_val := vm.peek(v, 0)
			if !core.is_int(substeps_val) {
				vm.runtime_error(v, "step() substeps argument must be an integer.")
				return false
			}
			substeps = core.as_int(substeps_val)
		}
		b2.World_Step(w.world_id, f32(core.as_float(dt_val)), i32(substeps))
		result = core.NIL_VALUE
	case "collisions":
		if arg_count != 0 {
			vm.runtime_error(v, "collisions() expects no arguments.")
			return false
		}
		events := b2.World_GetContactEvents(w.world_id)
		items: [dynamic]core.Value
		for i in 0 ..< int(events.beginCount) {
			e := events.beginEvents[i]
			a := int(uintptr(b2.Shape_GetUserData(e.shapeIdA)))
			b := int(uintptr(b2.Shape_GetUserData(e.shapeIdB)))
			if a == 0 || b == 0 {
				continue // every shape this module creates sets userData -- a 0 means a stale/foreign shape, skip it
			}
			tuple_items: [dynamic]core.Value
			append(&tuple_items, core.make_int_value(a - 1, true), core.make_int_value(b - 1, true))
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
		n := 0
		for e in w.bodies {
			if e.active {
				n += 1
			}
		}
		result = core.make_int_value(n, true)
	case:
		vm.runtime_error(v, "Undefined Box2DWorld method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
