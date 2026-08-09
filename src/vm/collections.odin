package vm

import "../core"
import "core:strings"

// Indexing, slicing, and collection-literal construction. Stack
// convention for slicing (see compiler/expr.odin's subscript): object,
// then start (Nil if open), then end (Nil if open, slices only).

// dict_key coerces any Value into the (already-interned) string a dict
// subscript should look it up by -- matches create_dict's own coercion
// (see that proc's doc comment), so `d[10]` and a literal `{10: ...}`
// agree on the same key. A Value that's already a string still goes
// through intern_string (a cheap no-op map lookup for the overwhelmingly
// common case where it's already the canonical pointer -- see
// obj_string.odin's STRING_INTERN_MAX_LEN and core/obj_dict.odin's doc
// comment on why every dict key must be canonical regardless of length);
// anything else goes through value_to_string once and interns the
// result, since there's no pre-existing interned pointer to reuse for a
// coerced key.
@(private = "file")
dict_key :: proc(v: core.Value) -> ^core.String_Object {
	if core.is_string(v) {
		return core.intern_string(core.string_get(core.as_string(v)))
	}
	s := core.value_to_string(v)
	defer delete(s)
	return core.intern_string(s)
}

// do_index handles Op_Index (`obj[idx]`). Checks the container's own
// type first -- Dict indexing takes any coercible key (see dict_key)
// and only List/String indexing requires idx to be an int.
do_index :: proc(vm: ^VM) -> bool {
	idx := pop(vm)
	obj := pop(vm)

	if obj.type == .Obj && obj.obj_type == .Dict {
		key := dict_key(idx)
		v, ok := core.dict_get(core.as_dict(obj), key)
		if !ok {
			runtime_error(vm, "Key '%s' not found.", core.string_get(key))
			return false
		}
		push(vm, v)
		return true
	}

	if !core.is_int(idx) {
		runtime_error(vm, "Index must be an integer.")
		return false
	}
	i := core.as_int(idx)

	if obj.type == .Obj && obj.obj_type == .List {
		v, ok := core.list_index(core.as_list(obj), i)
		if !ok {
			runtime_error(vm, "List index out of range.")
			return false
		}
		push(vm, v)
		return true
	}
	if core.is_string(obj) {
		s := core.string_get(core.as_string(obj))
		if i < 0 {
			i += len(s)
		}
		if i < 0 || i >= len(s) {
			runtime_error(vm, "String index out of range.")
			return false
		}
		push(vm, core.make_string_value(s[i:i + 1]))
		return true
	}
	runtime_error(vm, "Value is not indexable.")
	return false
}

// do_index_assign handles Op_Index_Assign (`obj[idx] = value`), with
// the same Dict-first type dispatch as do_index.
do_index_assign :: proc(vm: ^VM) -> bool {
	value := pop(vm)
	idx := pop(vm)
	obj := pop(vm)

	if obj.type == .Obj && obj.obj_type == .Dict {
		key := dict_key(idx)
		core.dict_set(core.as_dict(obj), key, value)
		push(vm, value)
		return true
	}

	if !core.is_int(idx) {
		runtime_error(vm, "Index must be an integer.")
		return false
	}
	if obj.type != .Obj || obj.obj_type != .List {
		runtime_error(vm, "Value does not support index assignment.")
		return false
	}
	l := core.as_list(obj)
	i := core.as_int(idx)
	if i < 0 {
		i += len(l.items)
	}
	if i < 0 || i >= len(l.items) {
		runtime_error(vm, "List index out of range.")
		return false
	}
	l.items[i] = value
	push(vm, value)
	return true
}

@(private = "file")
resolve_slice_bounds :: proc(start_v, end_v: core.Value, length: int) -> (start, end: int) {
	start = 0
	if start_v.type != .Nil {
		start = core.as_int(start_v)
	}
	end = length
	if end_v.type != .Nil {
		end = core.as_int(end_v)
	}
	if start < 0 {
		start += length
	}
	if end < 0 {
		end += length
	}
	if start < 0 {
		start = 0
	}
	if end > length {
		end = length
	}
	if start > end {
		start = end
	}
	return
}

do_slice :: proc(vm: ^VM) -> bool {
	end_v := pop(vm)
	start_v := pop(vm)
	obj := pop(vm)

	if obj.type == .Obj && obj.obj_type == .List {
		l := core.as_list(obj)
		start, end := resolve_slice_bounds(start_v, end_v, len(l.items))
		items := make([dynamic]core.Value, end - start)
		copy(items[:], l.items[start:end])
		result := core.make_list_object(items)
		gc_track(vm, &result.obj)
		push(vm, core.make_object_value(&result.obj))
		return true
	}
	if core.is_string(obj) {
		s := core.string_get(core.as_string(obj))
		start, end := resolve_slice_bounds(start_v, end_v, len(s))
		push(vm, core.make_string_value(s[start:end]))
		return true
	}
	runtime_error(vm, "Value is not sliceable.")
	return false
}

do_slice_assign :: proc(vm: ^VM) -> bool {
	value := pop(vm)
	end_v := pop(vm)
	start_v := pop(vm)
	obj := pop(vm)

	if obj.type != .Obj || obj.obj_type != .List {
		runtime_error(vm, "Only lists support slice assignment.")
		return false
	}
	if value.type != .Obj || value.obj_type != .List {
		runtime_error(vm, "Can only assign a list to a list slice.")
		return false
	}
	l := core.as_list(obj)
	rhs := core.as_list(value)
	start, end := resolve_slice_bounds(start_v, end_v, len(l.items))

	tmp := make([dynamic]core.Value, 0, start + len(rhs.items) + (len(l.items) - end))
	append(&tmp, ..l.items[:start])
	append(&tmp, ..rhs.items[:])
	append(&tmp, ..l.items[end:])
	delete(l.items)
	l.items = tmp
	push(vm, value)
	return true
}

do_in :: proc(vm: ^VM) -> bool {
	container := pop(vm)
	item := pop(vm)
	if container.type == .Obj && container.obj_type == .List {
		push(vm, core.make_bool_value(core.list_contains(core.as_list(container), item)))
		return true
	}
	if container.type == .Obj && container.obj_type == .Dict {
		// Same key coercion as subscript (dict_key), not dict.get()'s
		// stricter string-only rule -- `10 in d` should agree with `d[10]`.
		key := dict_key(item)
		_, ok := core.dict_get(core.as_dict(container), key)
		push(vm, core.make_bool_value(ok))
		return true
	}
	if core.is_string(container) && core.is_string(item) {
		hay := core.string_get(core.as_string(container))
		needle := core.string_get(core.as_string(item))
		push(vm, core.make_bool_value(strings.contains(hay, needle)))
		return true
	}
	runtime_error(vm, "Right operand of 'in' must be a list, dict, or string.")
	return false
}

create_list :: proc(vm: ^VM, count: int, is_tuple: bool) {
	items := make([dynamic]core.Value, count)
	for i := count - 1; i >= 0; i -= 1 {
		items[i] = pop(vm)
	}
	l := core.make_list_object(items, is_tuple)
	gc_track(vm, &l.obj)
	push(vm, core.make_object_value(&l.obj, is_tuple)) // tuples are immutable Values
}

create_dict :: proc(vm: ^VM, pair_count: int) -> bool {
	items := make(map[^core.String_Object]core.Value, pair_count)
	// Pairs were pushed key0, value0, key1, value1, ... in source order;
	// pop them off in reverse (value_n, key_n, ..., value0, key0).
	for _ in 0 ..< pair_count {
		value := pop(vm)
		key := pop(vm)
		// A non-string key is coerced to its string representation, not
		// rejected -- an int-keyed dict literal like `{10: "DEBUG", 20:
		// "INFO", ...}` is valid, and looked up later via `str(level)`.
		// core.value_to_string is the same stringification Op_Str's own
		// generic (non-__str__) fallback uses, so a coerced key and its
		// later str() lookup always agree. dict_key shares this coercion
		// with do_index/do_index_assign.
		items[dict_key(key)] = value
	}
	d := core.make_dict_object(items)
	gc_track(vm, &d.obj)
	push(vm, core.make_object_value(&d.obj))
	return true
}

do_unpack :: proc(vm: ^VM, count: int) -> bool {
	val := pop(vm)
	if val.type != .Obj || val.obj_type != .List {
		runtime_error(vm, "Can only unpack a list or tuple.")
		return false
	}
	items := core.as_list(val).items
	if len(items) != count {
		runtime_error(vm, "Expected %d values to unpack but got %d.", count, len(items))
		return false
	}
	for item in items {
		push(vm, item)
	}
	return true
}
