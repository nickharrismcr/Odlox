package core

// The three built-in iterator kinds -- one Object_Type each. Each has
// its own `next` proc rather than a shared interface method; the vm
// package dispatches on `obj.type` at the two call sites that need "the
// next value" (native OP_FOREACH/OP_NEXT fast path for list/string, vs.
// the user-level `__iter__`/`__next__` protocol for class instances,
// which never touches these types at all).

List_Iterator_Object :: struct {
	using obj: Obj,
	data:      ^List_Object,
	index:     int,
}

make_list_iterator_object :: proc(data: ^List_Object) -> ^List_Iterator_Object {
	o := new(List_Iterator_Object)
	o.obj.type = .List_Iterator
	o.data = data
	return o
}

list_iterator_next :: proc(it: ^List_Iterator_Object) -> Value {
	if it.index >= len(it.data.items) {
		return NIL_VALUE
	}
	v := it.data.items[it.index]
	it.index += 1
	return v
}

Int_Iterator_Object :: struct {
	using obj:               Obj,
	start, end, step, index: int,
}

make_int_iterator_object :: proc(start, end, step: int) -> ^Int_Iterator_Object {
	o := new(Int_Iterator_Object)
	o.obj.type = .Int_Iterator
	o.start, o.end, o.step, o.index = start, end, step, start
	return o
}

int_iterator_next :: proc(it: ^Int_Iterator_Object) -> Value {
	// A positive step counts up toward end (exhausted once index reaches
	// or passes it); a negative step counts down toward end (exhausted
	// once index reaches or drops below it). Without this split, a
	// descending range like range(10, 0, -1) exhausts on the very first
	// check (index=10 >= end=0 is already true) and yields nothing.
	if it.step > 0 {
		if it.index >= it.end {
			return NIL_VALUE
		}
	} else {
		if it.index <= it.end {
			return NIL_VALUE
		}
	}
	v := make_int_value(it.index, true)
	it.index += it.step
	return v
}

String_Iterator_Object :: struct {
	using obj: Obj,
	data:      ^String_Object,
	index:     int, // byte offset
}

make_string_iterator_object :: proc(data: ^String_Object) -> ^String_Iterator_Object {
	o := new(String_Iterator_Object)
	o.obj.type = .String_Iterator
	o.data = data
	return o
}

string_iterator_next :: proc(it: ^String_Iterator_Object) -> Value {
	if it.index >= len(it.data.chars) {
		return NIL_VALUE
	}
	v := make_string_value(it.data.chars[it.index:it.index + 1])
	it.index += 1
	return v
}
