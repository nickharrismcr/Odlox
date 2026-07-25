package core

// Class_Object. `methods`/`static_methods`/`statics` are keyed by the
// canonical `^String_Object` for the member's name (see obj_string.odin)
// -- a direct map lookup, same shape as glox's `map[int]Value` keyed by
// interned name id, just keyed by the pointer itself instead of a
// separate id.
//
// Unlike glox's experimental GC (which deliberately never sweeps classes
// -- see docs/ARCHITECTURE.md's Garbage collector section on why that
// exemption existed and why this port drops it), a Class_Object here is
// an ordinary sweepable Obj with no side-registry keeping it artificially
// alive; only genuine reachability (a global slot, a closure's captured
// class reference, an instance's `.class` field, etc.) keeps it around.
Class_Object :: struct {
	using obj:      Obj,
	name:           ^String_Object,
	methods:        map[^String_Object]Value,
	static_methods: map[^String_Object]Value,
	statics:        map[^String_Object]Value,
	super:          ^Class_Object,
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
