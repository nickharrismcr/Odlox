package core

import "core:strings"

// Instance_Object.fields is keyed by canonical `^String_Object`, same
// reasoning as Class_Object's method maps: a direct map key, no separate
// name-id indirection. slots backs the compile-time-baked field-slot fast
// path: a fixed-size array, sized from class.field_slot_names, for fields
// the compiler proved are always assigned unconditionally in the class's
// own init. Every entry starts as UNDEFINED_VALUE (not Nil) so a read
// before assignment still misses correctly. fields and slots never hold
// the same name, since field-slot discovery is total and disjoint.
Instance_Object :: struct {
	using obj: Obj,
	class:     ^Class_Object,
	fields:    map[^String_Object]Value,
	slots:     []Value,
}

make_instance_object :: proc(class: ^Class_Object) -> ^Instance_Object {
	o := new(Instance_Object)
	o.obj.type = .Instance
	o.class = class
	if n := len(class.field_slot_names); n > 0 {
		o.slots = make([]Value, n)
		for i in 0 ..< n {
			o.slots[i] = UNDEFINED_VALUE
		}
	}
	return o
}

// instance_get_field is the compatibility helper for call sites that don't
// know at compile time whether `name` is a slotted field -- checks fields
// first, then falls back to class.field_slot_index/slots. Never used by
// Get_Field_Slot/Set_Field_Slot's own hot path, which needs no name lookup.
instance_get_field :: proc(inst: ^Instance_Object, name: ^String_Object) -> (Value, bool) {
	if v, ok := inst.fields[name]; ok {
		return v, true
	}
	if idx, ok := inst.class.field_slot_index[name]; ok {
		v := inst.slots[idx]
		if v.type != .Undefined {
			return v, true
		}
	}
	return {}, false
}

// instance_set_field is instance_get_field's write-side counterpart, used
// by the generic property-set path for `some_expr.name = value` where
// some_expr isn't provably `this`. Checks fields first, same as the read
// side, so a write targets whichever storage already holds this name.
instance_set_field :: proc(inst: ^Instance_Object, name: ^String_Object, value: Value) {
	if _, ok := inst.fields[name]; ok {
		inst.fields[name] = value
		return
	}
	if idx, ok := inst.class.field_slot_index[name]; ok {
		inst.slots[idx] = value
		return
	}
	inst.fields[name] = value
}

instance_to_string :: proc(o: ^Instance_Object, allocator := context.allocator) -> string {
	return strings.concatenate({"<instance ", o.class.name.chars, ">"}, allocator)
}
