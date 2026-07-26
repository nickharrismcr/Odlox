package core

import "core:fmt"
import "core:strings"

// string_depth/MAX_STRING_DEPTH guard List_Object/Dict_Object's own
// to_string against unbounded recursion when a container holds a
// reference to itself, directly or via another container (`l.append(l)`).
// Package-private (shared by obj_list.odin and obj_dict.odin, not
// exported) and a plain int rather than glox's `atomic.Int32` -- the VM
// is single-threaded (see docs/ARCHITECTURE.md's Scope section), so
// there's no concurrent String() call to guard against here.
@(private)
string_depth: int
@(private)
MAX_STRING_DEPTH :: 100

// List_Object backs both list (`[a, b]`) and tuple (`(a, b)`) literals --
// `is_tuple` is the only difference (tuples are immutable at the Value
// level; see the compiler/VM phases for where that's enforced).
List_Object :: struct {
	using obj: Obj,
	items:     [dynamic]Value,
	is_tuple:  bool,
}

make_list_object :: proc(items: [dynamic]Value, is_tuple := false) -> ^List_Object {
	o := new(List_Object)
	o.obj.type = .List
	o.items = items
	o.is_tuple = is_tuple
	return o
}

list_length :: proc(l: ^List_Object) -> int {
	return len(l.items)
}

list_append :: proc(l: ^List_Object, v: Value) {
	append(&l.items, v)
}

// list_join concatenates l's items (which must all be strings) with sep
// between them, mirroring glox's ListObject.Join -- the underlying
// logic for the `sep.join(list)` string method (vm/call.odin), named
// for the list here since the joining itself only touches list items.
list_join :: proc(l: ^List_Object, sep: string) -> (Value, bool) {
	if len(l.items) == 0 {
		return make_string_value(""), true
	}
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	for item, i in l.items {
		if !is_string(item) {
			return NIL_VALUE, false
		}
		if i > 0 {
			strings.write_string(&b, sep)
		}
		strings.write_string(&b, string_get(as_string(item)))
	}
	return make_string_value(strings.to_string(b)), true
}

list_remove :: proc(l: ^List_Object, ix: int) {
	if ix < 0 || ix >= len(l.items) {
		return
	}
	ordered_remove(&l.items, ix)
}

// list_index resolves ix Python-style (negative counts from the end)
// and returns an error if it's still out of range afterward.
list_index :: proc(l: ^List_Object, ix: int) -> (Value, bool) {
	i := ix
	if i < 0 {
		i += len(l.items)
	}
	if i < 0 || i >= len(l.items) {
		return NIL_VALUE, false
	}
	return l.items[i], true
}

list_contains :: proc(l: ^List_Object, v: Value) -> bool {
	for item in l.items {
		if values_equal(item, v, true) {
			return true
		}
	}
	return false
}

list_to_string :: proc(l: ^List_Object, allocator := context.allocator) -> string {
	string_depth += 1
	defer string_depth -= 1
	if string_depth > MAX_STRING_DEPTH {
		return "..."
	}

	parts := make([dynamic]string, 0, len(l.items), context.temp_allocator)
	for item in l.items {
		append(&parts, value_to_string(item, context.temp_allocator))
	}
	joined := strings.join(parts[:], " , ", context.temp_allocator)
	open, close := "[ ", " ]"
	if l.is_tuple {
		open, close = "( ", " )"
	}
	return strings.concatenate({open, joined, close}, allocator)
}
