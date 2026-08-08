package core

import "core:strings"

// Instance_Object.fields is keyed by canonical `^String_Object`, same
// reasoning as Class_Object's method maps -- see obj_string.odin's doc
// comment on why this is a plain, direct map key with no separate
// name-id indirection.
//
// slots backs the compile-time-baked field-slot fast path (see
// chunk.odin's Get_Field_Slot/Set_Field_Slot doc comment): a fixed-size
// array, sized from class.field_slot_names at construction, for fields
// the compiler proved are always assigned unconditionally at the top
// level of the class's own init. Every entry starts as UNDEFINED_VALUE
// (not Value's plain zero value, which is a legitimate Nil) so a read
// before that field's assignment line still misses correctly, same as
// today's map-based behavior. fields and slots never hold the same name
// -- field-slot discovery is total and disjoint by construction (see
// resolve.odin's discover_field_slots) -- so nothing needs to check both
// for a single name except the compatibility helper, instance_get_field
// below, used only by cold/generic call sites that don't know at compile
// time whether a name is slotted.
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

// instance_get_field is the compatibility helper for call sites that
// don't know at compile time whether `name` is a slotted field on this
// instance's class -- checks fields first (the common case for a
// non-slot-optimized class, and always correct regardless), then falls
// back to class.field_slot_index/slots. Used by vm/call.odin's invoke
// (a field holding a callable shadows a same-named method) and
// vm/exceptions.odin (reading `msg` off a possibly slot-optimized
// exception instance) -- never by Get_Field_Slot/Set_Field_Slot's own
// hot path, which never needs a name lookup at all.
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

// instance_set_field is instance_get_field's write-side counterpart --
// used by vm/properties.odin's set_obj_field, the generic property-set
// path for `some_expr.name = value` where some_expr isn't provably
// `this` inside the declaring class (so it never compiles to
// Set_Field_Slot at all). Checks fields first, same as the read side and
// for the same reason: keeps every write targeting whichever storage
// already holds this name for this instance, rather than letting a
// generic write silently create a second, inconsistent copy of a name
// that's already a live field-slot for this class.
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
