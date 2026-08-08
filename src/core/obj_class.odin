package core

// Class_Object. `methods`/`static_methods`/`statics` are keyed by the
// canonical `^String_Object` for the member's name (see obj_string.odin)
// -- a direct map lookup keyed by the interned pointer itself, with no
// separate name-id indirection.
//
// A Class_Object is an ordinary sweepable Obj with no side-registry
// keeping it artificially alive; only genuine reachability (a global
// slot, a closure's captured class reference, an instance's `.class`
// field, etc.) keeps it around -- see docs/ARCHITECTURE.md's Garbage
// collector section.
// field_slot_names/field_slot_index back the compile-time-baked
// field-slot fast path (see chunk.odin's Get_Field_Slot/Set_Field_Slot
// doc comment and obj_instance.odin's Instance_Object.slots).
// field_slot_names is a *borrowed* slice into the owning Chunk's own
// field_slot_tables entry -- never freed via this Class_Object, see
// gc.odin's free_object. field_slot_index (name -> index) exists only
// for instance_get_field's cold-path compatibility lookup; nothing on
// Get_Field_Slot/Set_Field_Slot's own hot path ever consults it.
Class_Object :: struct {
	using obj:        Obj,
	name:             ^String_Object,
	methods:          map[^String_Object]Value,
	static_methods:   map[^String_Object]Value,
	statics:          map[^String_Object]Value,
	super:            ^Class_Object,
	field_slot_names: []string,
	field_slot_index: map[^String_Object]int,
}

make_class_object :: proc(name: string) -> ^Class_Object {
	c := new(Class_Object)
	c.obj.type = .Class
	c.name = intern_string(name)
	return c
}

is_subclass_of :: proc(c, other: ^Class_Object) -> bool {
	for cur := c; cur != nil; cur = cur.super {
		if cur == other {
			return true
		}
	}
	return false
}
