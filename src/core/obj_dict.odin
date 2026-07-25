package core

import "core:fmt"
import "core:strings"

// Dict_Object keys are always `^String_Object` (canonical interned
// pointers), not arbitrary Values -- matching glox, where dict keys are
// always strings (re-interned to a name id on every get/set). Keying
// directly by the canonical pointer here means no separate intern-id
// concept is needed at all; see obj_string.odin's doc comment.
Dict_Object :: struct {
	using obj: Obj,
	items:     map[^String_Object]Value,
}

make_dict_object :: proc(items: map[^String_Object]Value = nil) -> ^Dict_Object {
	o := new(Dict_Object)
	o.obj.type = .Dict
	o.items = items
	return o
}

dict_set :: proc(d: ^Dict_Object, key: string, value: Value) {
	d.items[intern_string(key)] = value
}

dict_get :: proc(d: ^Dict_Object, key: string) -> (Value, bool) {
	return d.items[intern_string(key)]
}

dict_remove :: proc(d: ^Dict_Object, key: string) -> (Value, bool) {
	k := intern_string(key)
	v, ok := d.items[k]
	if ok {
		delete_key(&d.items, k)
	}
	return v, ok
}

// dict_keys returns a fresh List_Object of the dict's keys as string
// Values -- the caller is responsible for linking it into the VM's GC
// registry once one exists (Phase 4), same as glox's Keys().
dict_keys :: proc(d: ^Dict_Object) -> ^List_Object {
	keys := make([dynamic]Value, 0, len(d.items))
	for k in d.items {
		append(&keys, make_object_value(&k.obj))
	}
	return make_list_object(keys)
}

// dict_to_string shares list_to_string's recursion-depth guard (see
// obj_list.odin) -- a dict can hold itself (or a list holding it, etc.)
// just as easily as a list can.
dict_to_string :: proc(d: ^Dict_Object, allocator := context.allocator) -> string {
	string_depth += 1
	defer string_depth -= 1
	if string_depth > MAX_STRING_DEPTH {
		return "..."
	}

	parts := make([dynamic]string, 0, len(d.items), context.temp_allocator)
	for k, v in d.items {
		append(&parts, fmt.tprintf("\"%s\":%s", k.chars, value_to_string(v, context.temp_allocator)))
	}
	joined := strings.join(parts[:], ", ", context.temp_allocator)
	return strings.concatenate({"Dict({ ", joined, " })"}, allocator)
}
