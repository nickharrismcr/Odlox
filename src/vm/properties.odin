package vm

import "../core"

// Property get/set across instance/class/module receivers, plus
// class-body opcodes (Class/Inherit/Method/Static_Method/Class_Var) and
// super dispatch. Vec2/3/4 get a swizzle fast path (`.x`/`.y`/`.z`/`.w`,
// plus `.r`/`.g`/`.b`/`.a` as color-channel aliases on Vec4) rather than
// going through the general Object property machinery, since a vector
// isn't an Obj-carrying Value kind the same way (see core/value.odin).

// get_property/set_property/bind_method/invoke/invoke_from_class all take
// name as an already-interned ^core.String_Object, not a plain string.
// Every call site (run.odin's Get_Property/Set_Property/Invoke/
// Super_Invoke/Get_Super cases) reads name straight off a bytecode
// constant that the compiler already interned when it emitted it
// (compiler/expr.odin's dot -> core.make_string_value); a plain-string
// signature here meant every single property/method access re-hashed
// that name's full content against the global intern table just to
// re-derive the exact pointer already sitting in the constant pool --
// real, measured cost, found via the Phase 7b benchmark baseline
// (trees/binary_trees, both property-access-heavy, were the only two
// benchmarks where odlox lost to glox; glox avoids this entirely by
// caching the interned id on the constant at compile time). Passing the
// pointer through turns every one of these into a single map lookup
// keyed by pointer identity, same as glox's int-keyed fast path.
//
// get_property/invoke additionally take a monomorphic inline cache
// (core.Property_Cache, one per callsite -- see core/chunk.odin's doc
// comment) so a same-class repeat hit skips the *second* map lookup too
// (class.methods[name], after an instance-fields-miss) -- nil for the
// callsites that don't get one (do_get_super/do_super_invoke, both
// comparatively cold). It can never replace the instance-fields lookup
// itself: Lox instances have no fixed shape, so a field masking a method
// on one instance says nothing about another instance of the same class.
get_property :: proc(vm: ^VM, name: ^core.String_Object, cache: ^core.Property_Cache) -> bool {
	receiver := peek(vm, 0)

	#partial switch receiver.type {
	case .Vec2, .Vec3, .Vec4:
		return get_vec_swizzle(vm, receiver, core.string_get(name))
	case .Obj:
		#partial switch receiver.obj_type {
		case .Instance:
			inst := core.as_instance(receiver)
			if v, ok := inst.fields[name]; ok {
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
		case .Window:
			// `win.KEY_*` -- glox registers these directly on the window
			// object (RegisterAllWindowConstants), not as module-level
			// constants; see gfx_window.odin's window_key_constant doc
			// comment for how this was found (porting lox_examples/defender).
			if v, ok := window_key_constant(core.string_get(name)); ok {
				pop(vm)
				push(vm, v)
				return true
			}
			runtime_error(vm, "Undefined window property '%s'.", core.string_get(name))
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

// set_vec_swizzle mirrors get_vec_swizzle for assignment (`v.x = expr`)
// -- glox's own OP_SET_PROPERTY has a real Vec2/Vec3/Vec4 case
// (`v.AsVec2().SetX(tmp.AsFloat())`, `vm.go`), which this port was
// missing entirely: set_property only ever checked `receiver.type ==
// .Obj`, so any vector's `.type` (`.Vec2`/`.Vec3`/`.Vec4`, never
// `.Obj` -- see value.odin) fell straight through to the generic
// "Only instances, classes, and modules have settable properties."
// error, rejecting vector field assignment outright. Found porting
// src/modules/particle_sys.lox, a real glox module that assigns
// `this.pos.x = ...` directly. Vec2/3/4 objects are mutable heap
// values (a Value just wraps a pointer to one -- see obj_vec.odin), so
// this mutates the field in place rather than replacing anything on
// the stack, same shape as Instance/Class/Module's map-entry updates.
set_vec_swizzle :: proc(vm: ^VM, v: core.Value, name: string, value: core.Value) -> bool {
	if !core.is_number(value) {
		runtime_error(vm, "Vector field '%s' must be assigned a number.", name)
		return false
	}
	f := core.as_float(value)
	ok := true
	#partial switch v.type {
	case .Vec2:
		vv := core.as_vec2(v)
		switch name {
		case "x":
			vv.x = f
		case "y":
			vv.y = f
		case:
			ok = false
		}
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
			ok = false
		}
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
			ok = false
		}
	}
	if !ok {
		runtime_error(vm, "Undefined vector field '%s'.", name)
		return false
	}
	pop(vm)
	pop(vm)
	push(vm, value)
	return true
}

set_property :: proc(vm: ^VM, name: ^core.String_Object) -> bool {
	receiver := peek(vm, 1)
	value := peek(vm, 0)

	#partial switch receiver.type {
	case .Vec2, .Vec3, .Vec4:
		return set_vec_swizzle(vm, receiver, core.string_get(name), value)
	case .Obj:
		#partial switch receiver.obj_type {
		case .Instance:
			core.as_instance(receiver).fields[name] = value
			pop(vm)
			pop(vm)
			push(vm, value)
			return true
		case .Class:
			core.as_class(receiver).statics[name] = value
			pop(vm)
			pop(vm)
			push(vm, value)
			return true
		case .Module:
			core.env_set_var(core.as_module(receiver).environment, name, value)
			pop(vm)
			pop(vm)
			push(vm, value)
			return true
		}
	}
	runtime_error(vm, "Only instances, classes, and modules have settable properties.")
	return false
}

// -----------------------------------------------------------------------
// Classes

do_class :: proc(vm: ^VM, name: string) {
	class := core.make_class_object(name)
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
	}
	class.super = super
	pop(vm) // class_val -- super_val stays, becoming the `super` local's slot
	return true
}

do_method :: proc(vm: ^VM, name: string, is_static: bool) {
	method_val := peek(vm, 0)
	class := core.as_class(peek(vm, 1))
	key := core.intern_string(name)
	if is_static {
		class.static_methods[key] = method_val
	} else {
		class.methods[key] = method_val
	}
	pop(vm)
}

do_class_var :: proc(vm: ^VM, name: string) {
	val := peek(vm, 0)
	class := core.as_class(peek(vm, 1))
	class.statics[core.intern_string(name)] = val
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
