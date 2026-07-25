package core

import "core:strings"

// Instance_Object.fields is keyed by canonical `^String_Object`, same
// reasoning as Class_Object's method maps -- see obj_string.odin's doc
// comment on why this is a plain, direct map key rather than glox's
// intern-to-an-int-first step.
Instance_Object :: struct {
	using obj: Obj,
	class:     ^Class_Object,
	fields:    map[^String_Object]Value,
}

make_instance_object :: proc(class: ^Class_Object) -> ^Instance_Object {
	o := new(Instance_Object)
	o.obj.type = .Instance
	o.class = class
	return o
}

instance_to_string :: proc(o: ^Instance_Object, allocator := context.allocator) -> string {
	return strings.concatenate({"<instance ", o.class.name.chars, ">"}, allocator)
}
