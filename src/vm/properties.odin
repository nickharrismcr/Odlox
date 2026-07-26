package vm

import "../core"

// Property get/set across instance/class/module receivers, plus
// class-body opcodes (Class/Inherit/Method/Static_Method/Class_Var) and
// super dispatch. Vec2/3/4 get a swizzle fast path (`.x`/`.y`/`.z`/`.w`,
// plus `.r`/`.g`/`.b`/`.a` as color-channel aliases on Vec4) rather than
// going through the general Object property machinery, since a vector
// isn't an Obj-carrying Value kind the same way (see core/value.odin).

get_property :: proc(vm: ^VM, name: string) -> bool {
	receiver := peek(vm, 0)

	#partial switch receiver.type {
	case .Vec2, .Vec3, .Vec4:
		return get_vec_swizzle(vm, receiver, name)
	case .Obj:
		#partial switch receiver.obj_type {
		case .Instance:
			inst := core.as_instance(receiver)
			if v, ok := inst.fields[core.intern_string(name)]; ok {
				pop(vm)
				push(vm, v)
				return true
			}
			return bind_method(vm, inst.class, name)
		case .Class:
			class := core.as_class(receiver)
			for c := class; c != nil; c = c.super {
				if v, ok := c.statics[core.intern_string(name)]; ok {
					pop(vm)
					push(vm, v)
					return true
				}
			}
			runtime_error(vm, "Undefined static property '%s'.", name)
			return false
		case .Module:
			mod := core.as_module(receiver)
			if v, ok := core.env_get_var(mod.environment, core.intern_string(name)); ok {
				pop(vm)
				push(vm, v)
				return true
			}
			runtime_error(vm, "Undefined module property '%s'.", name)
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

set_property :: proc(vm: ^VM, name: string) -> bool {
	receiver := peek(vm, 1)
	value := peek(vm, 0)

	if receiver.type == .Obj {
		#partial switch receiver.obj_type {
		case .Instance:
			core.as_instance(receiver).fields[core.intern_string(name)] = value
			pop(vm)
			pop(vm)
			push(vm, value)
			return true
		case .Class:
			core.as_class(receiver).statics[core.intern_string(name)] = value
			pop(vm)
			pop(vm)
			push(vm, value)
			return true
		case .Module:
			core.env_set_var(core.as_module(receiver).environment, core.intern_string(name), value)
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
// compiler/expr.odin's super_).
do_get_super :: proc(vm: ^VM, name: string) -> bool {
	super := core.as_class(pop(vm))
	return bind_method(vm, super, name)
}

// do_super_invoke: stack is [..., this_value, arg1, ..., argN,
// superclass_value]. Popping the superclass value leaves exactly
// [this_value, args...] -- the same shape invoke_from_class/call expect
// for any ordinary method call, so it can reuse that path directly.
do_super_invoke :: proc(vm: ^VM, name: string, arg_count: int) -> bool {
	super := core.as_class(pop(vm))
	return invoke_from_class(vm, super, name, arg_count, false)
}
