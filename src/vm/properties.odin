package vm

import "../core"

// Property get/set across instance/class/module receivers, plus
// class-body opcodes (Class/Inherit/Method/Static_Method/Class_Var) and
// super dispatch. Vec2/3/4 get a swizzle fast path (`.x`/`.y`/`.z`/`.w`,
// plus `.r`/`.g`/`.b`/`.a` as color-channel aliases on Vec4) rather than
// going through the general Object property machinery, since a vector
// isn't an Obj-carrying Value kind the same way (see core/value.odin).

// get_property/set_property/bind_method/invoke/invoke_from_class all take
// name as an already-interned ^core.String_Object, not a plain string --
// call sites already have it interned off a bytecode constant, so passing
// the pointer avoids re-hashing on every access. get_property/invoke also
// take a monomorphic inline cache (nil for the colder do_get_super/
// do_super_invoke) so a same-class repeat hit skips the class.methods
// lookup too.
get_property :: proc(vm: ^VM, name: ^core.String_Object, cache: ^core.Property_Cache) -> bool {
	receiver := peek(vm, 0)

	#partial switch receiver.type {
	case .Vec2, .Vec3, .Vec4:
		return get_vec_swizzle(vm, receiver, core.string_get(name))
	case .Obj:
		#partial switch receiver.obj_type {
		case .Instance:
			inst := core.as_instance(receiver)
			// core.instance_get_field, not a raw inst.fields[name] read: it
			// must see a field regardless of whether the compiler put it in
			// inst.fields or inst.slots (discover_field_slots) -- this is
			// also the fallback path Get_Field_Slot's guard-miss reuses.
			if v, ok := core.instance_get_field(inst, name); ok {
				pop(vm)
				push(vm, v)
				return true
			}
			if cache.class == inst.class {
				return bind_method_cached(vm, cache.method)
			}
			return bind_method(vm, inst.class, name, cache)
		case .Class:
			class := core.as_class(receiver)
			for c := class; c != nil; c = c.super {
				if v, ok := c.statics[name]; ok {
					pop(vm)
					push(vm, v)
					return true
				}
			}
			runtime_error(vm, "Undefined static property '%s'.", core.string_get(name))
			return false
		case .Module:
			mod := core.as_module(receiver)
			if v, ok := core.env_get_var(mod.environment, name); ok {
				pop(vm)
				push(vm, v)
				return true
			}
			runtime_error(vm, "Undefined module property '%s'.", core.string_get(name))
			return false
		case .Userdata:
			// `win.KEY_*`/`win.BLEND_*`/`win.WRAP_*`/`win.BATCH_*` are
			// registered directly on the window object via its vtable's
			// get_property, not as module-level constants -- see
			// natives/gfx_window.odin's window_constant. nil for every
			// other Userdata kind (no bare-property reads defined).
			u := core.as_userdata(receiver)
			if u.vtable.get_property != nil {
				if v, ok := u.vtable.get_property(u.data, core.string_get(name)); ok {
					pop(vm)
					push(vm, v)
					return true
				}
			}
			runtime_error(vm, "Undefined property '%s'.", core.string_get(name))
			return false
		}
	}
	runtime_error(vm, "Only instances, classes, and modules have properties.")
	return false
}

@(private = "file")
get_vec_swizzle :: proc(vm: ^VM, v: core.Value, name: string) -> bool {
	field: f64
	ok := true
	#partial switch v.type {
	case .Vec2:
		vv := core.as_vec2(v)
		switch name {
		case "x":
			field = vv.x
		case "y":
			field = vv.y
		case:
			ok = false
		}
	case .Vec3:
		vv := core.as_vec3(v)
		switch name {
		case "x":
			field = vv.x
		case "y":
			field = vv.y
		case "z":
			field = vv.z
		case:
			ok = false
		}
	case .Vec4:
		vv := core.as_vec4(v)
		switch name {
		case "x", "r":
			field = vv.x
		case "y", "g":
			field = vv.y
		case "z", "b":
			field = vv.z
		case "w", "a":
			field = vv.w
		case:
			ok = false
		}
	}
	if !ok {
		runtime_error(vm, "Undefined vector field '%s'.", name)
		return false
	}
	pop(vm)
	push(vm, core.make_float_value(field))
	return true
}

// vec_with_field_set returns v (a Vec2/3/4 Value) with its swizzle
// component named `name` set to f, and whether `name` was valid for v's
// arity. Pure computation, no VM/stack involvement -- v is an inline
// value, so this can't mutate it in place; the caller (set_vec_swizzle or
// swizzle_assign below) is responsible for the returned whole value.
vec_with_field_set :: proc(v: core.Value, name: string, f: f64) -> (result: core.Value, ok: bool) {
	#partial switch v.type {
	case .Vec2:
		vv := core.as_vec2(v)
		switch name {
		case "x":
			vv.x = f
		case "y":
			vv.y = f
		case:
			return v, false
		}
		return core.make_vec2_value(vv.x, vv.y, v.immutable), true
	case .Vec3:
		vv := core.as_vec3(v)
		switch name {
		case "x":
			vv.x = f
		case "y":
			vv.y = f
		case "z":
			vv.z = f
		case:
			return v, false
		}
		return core.make_vec3_value(vv.x, vv.y, vv.z, v.immutable), true
	case .Vec4:
		vv := core.as_vec4(v)
		switch name {
		case "x", "r":
			vv.x = f
		case "y", "g":
			vv.y = f
		case "z", "b":
			vv.z = f
		case "w", "a":
			vv.w = f
		case:
			return v, false
		}
		return core.make_vec4_value(vv.x, vv.y, vv.z, vv.w, v.immutable), true
	}
	return v, false
}

// set_vec_swizzle mirrors get_vec_swizzle for assignment (`v.x = expr`)
// via the ordinary (non-write-back) Set_Property opcode -- reachable only
// if something outside compiled Lox code calls set_property directly with
// a vector receiver, since the compiler always routes a swizzle assignment
// through Set_*_Vec_Field instead. Kept as a defensive fallback: with no
// write-back destination here, the mutation isn't observable afterward.
set_vec_swizzle :: proc(vm: ^VM, v: core.Value, name: string, value: core.Value) -> bool {
	if !core.is_number(value) {
		runtime_error(vm, "Vector field '%s' must be assigned a number.", name)
		return false
	}
	_, ok := vec_with_field_set(v, name, core.as_float(value))
	if !ok {
		runtime_error(vm, "Undefined vector field '%s'.", name)
		return false
	}
	pop(vm)
	pop(vm)
	push(vm, value)
	return true
}

// set_obj_field mutates recv's `name` property in place -- the shared
// logic behind set_property's Instance/Class/Module cases, extracted so
// the swizzle-assignment write-back opcodes can reach it too, for when a
// swizzle-shaped target (`recv.x = ...`) turns out at runtime to hold
// something other than a vector (e.g. an Instance field named "x"). Takes
// recv/value as plain parameters rather than reading them off the VM
// stack, since callers besides Set_Property need this too.
set_obj_field :: proc(vm: ^VM, recv: core.Value, name: ^core.String_Object, value: core.Value) -> bool {
	if recv.type == .Obj {
		#partial switch recv.obj_type {
		case .Instance:
			// core.instance_set_field, not a raw inst.fields[name]=value
			// write: keeps a generic external `some_expr.name = value`
			// write targeting the same storage (slots or fields) that
			// core.instance_get_field/Get_Field_Slot's fallback would find
			// it in -- see that helper's own doc comment.
			core.instance_set_field(core.as_instance(recv), name, value)
			write_barrier_value(vm, value)
			return true
		case .Class:
			core.as_class(recv).statics[name] = value
			write_barrier_value(vm, value)
			return true
		case .Module:
			core.env_set_var(core.as_module(recv).environment, name, value)
			write_barrier_value(vm, value)
			return true
		}
	}
	runtime_error(vm, "Only instances, classes, and modules have settable properties.")
	return false
}

set_property :: proc(vm: ^VM, name: ^core.String_Object) -> bool {
	receiver := peek(vm, 1)
	value := peek(vm, 0)

	#partial switch receiver.type {
	case .Vec2, .Vec3, .Vec4:
		return set_vec_swizzle(vm, receiver, core.string_get(name), value)
	case .Obj:
		if !set_obj_field(vm, receiver, name, value) {
			return false
		}
		pop(vm)
		pop(vm)
		push(vm, value)
		return true
	}
	runtime_error(vm, "Only instances, classes, and modules have settable properties.")
	return false
}

// swizzle_assign implements the runtime half of `<target>.f = value` where
// f is a swizzle component name and `recv` is <target>'s current value. If
// recv is a vector, the mutated whole vector is returned for the caller to
// write back (write_back = true) -- recv itself, an inline Value copy, was
// never mutated. If recv is an Instance/Class/Module, it's mutated in
// place via set_obj_field and write_back is false. Either way the caller
// owns the stack; this proc doesn't touch it.
swizzle_assign :: proc(vm: ^VM, recv: core.Value, name: ^core.String_Object, value: core.Value) -> (mutated: core.Value, write_back: bool, ok: bool) {
	#partial switch recv.type {
	case .Vec2, .Vec3, .Vec4:
		name_str := core.string_get(name)
		if !core.is_number(value) {
			runtime_error(vm, "Vector field '%s' must be assigned a number.", name_str)
			return {}, false, false
		}
		m, field_ok := vec_with_field_set(recv, name_str, core.as_float(value))
		if !field_ok {
			runtime_error(vm, "Undefined vector field '%s'.", name_str)
			return {}, false, false
		}
		return m, true, true
	case .Obj:
		return {}, false, set_obj_field(vm, recv, name, value)
	}
	runtime_error(vm, "Only instances, classes, and modules have settable properties.")
	return {}, false, false
}

// -----------------------------------------------------------------------
// Classes

// field_names is the class's own compile-time-discovered field-slot
// table (compiler/resolve.odin's discover_field_slots, index -> name;
// possibly empty) -- a borrowed slice into the Chunk's own
// field_slot_tables entry, never freed via this Class_Object (see
// gc.odin's free_object). field_slot_index (name -> index) is built here
// once, for instance_get_field's cold-path compatibility lookup only --
// never consulted by Get_Field_Slot/Set_Field_Slot's own hot path.
do_class :: proc(vm: ^VM, name: string, field_names: []string) {
	class := core.make_class_object(name)
	class.field_slot_names = field_names
	for field_name, i in field_names {
		class.field_slot_index[core.intern_string(field_name)] = i
	}
	gc_track(vm, &class.obj)
	push(vm, core.make_object_value(&class.obj))
}

// do_inherit: stack is [..., superclass_value, class_value] (see
// compiler/stmt.odin's class_declaration) -- copies every inherited
// method into the subclass's own table (so method lookup never needs
// to walk the super chain at call time) and records `super` for
// is_subclass_of/Get_Super.
do_inherit :: proc(vm: ^VM) -> bool {
	class_val := peek(vm, 0)
	super_val := peek(vm, 1)
	if super_val.type != .Obj || super_val.obj_type != .Class {
		runtime_error(vm, "Superclass must be a class.")
		return false
	}
	super := core.as_class(super_val)
	class := core.as_class(class_val)
	for k, v in super.methods {
		class.methods[k] = v
		write_barrier_value(vm, v)
	}
	class.super = super
	write_barrier(vm, &super.obj)
	pop(vm) // class_val -- super_val stays, becoming the `super` local's slot
	return true
}

do_method :: proc(vm: ^VM, name: string, is_static: bool) {
	method_val := peek(vm, 0)
	class := core.as_class(peek(vm, 1))
	key := core.intern_string(name)
	write_barrier_value(vm, method_val)
	if is_static {
		class.static_methods[key] = method_val
	} else {
		// owner_class records which class this method was textually
		// declared in -- the guard Get_Field_Slot/Set_Field_Slot's VM
		// dispatch (run.odin) checks before trusting a baked-in field-slot
		// index, since do_inherit below copies this same closure verbatim
		// into any subclass's method table too. Irrelevant for statics
		// (`this` doesn't exist there), left nil.
		core.as_closure(method_val).owner_class = class
		class.methods[key] = method_val
	}
	pop(vm)
}

do_class_var :: proc(vm: ^VM, name: string) {
	val := peek(vm, 0)
	class := core.as_class(peek(vm, 1))
	class.statics[core.intern_string(name)] = val
	write_barrier_value(vm, val)
	pop(vm)
}

// do_get_super: stack is [..., this_value, superclass_value] (see
// compiler/expr.odin's super_). No inline cache -- super calls are
// comparatively cold, and unlike Get_Property/Invoke the compiler
// doesn't allocate a Property_Cache slot for Get_Super/Super_Invoke.
do_get_super :: proc(vm: ^VM, name: ^core.String_Object) -> bool {
	super := core.as_class(pop(vm))
	return bind_method(vm, super, name, nil)
}

// do_super_invoke: stack is [..., this_value, arg1, ..., argN,
// superclass_value]. Popping the superclass value leaves exactly
// [this_value, args...] -- the same shape invoke_from_class/call expect
// for any ordinary method call, so it can reuse that path directly.
do_super_invoke :: proc(vm: ^VM, name: ^core.String_Object, arg_count: int) -> bool {
	super := core.as_class(pop(vm))
	return invoke_from_class(vm, super, name, arg_count, false, nil)
}
