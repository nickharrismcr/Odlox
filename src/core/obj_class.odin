package core

// Class_Object. `methods`/`static_methods`/`statics` are keyed by the
// canonical `^String_Object` for the member's name -- a direct map lookup
// keyed by the interned pointer, with no separate name-id indirection. An
// ordinary sweepable Obj with no side-registry; only genuine reachability
// keeps it alive. field_slot_names/field_slot_index back the compile-time
// field-slot fast path; field_slot_names is a *borrowed* slice into the
// owning Chunk's field_slot_tables entry, never freed via this object.
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
