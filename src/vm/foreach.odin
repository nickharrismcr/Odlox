package vm

import "../core"

// The native-iterable fast path for `foreach` (list/string): convert
// the iterable to one of the three built-in iterator kinds in place,
// then pull values from it with no Lox-level call overhead.
//
// KNOWN GAP vs. glox: this does not yet implement the *user-level*
// iterator protocol (a class instance defining `__iter__`/`__next__`),
// which needs a nested re-entrant call into run() to invoke those
// methods (glox's Run_Current_Function mode) -- deferred to keep this
// phase's scope tractable; foreach over a plain class instance will
// currently report "not iterable" rather than dispatching to
// `__iter__`. Revisit once the native path has real test coverage to
// build on.

@(private = "file")
make_native_iterator :: proc(vm: ^VM, val: core.Value) -> (core.Value, bool) {
	if val.type == .Obj {
		#partial switch val.obj_type {
		case .List:
			it := core.make_list_iterator_object(core.as_list(val))
			gc_track(vm, &it.obj)
			return core.make_object_value(&it.obj), true
		case .String:
			it := core.make_string_iterator_object(core.as_string(val))
			gc_track(vm, &it.obj)
			return core.make_object_value(&it.obj), true
		case .List_Iterator, .Int_Iterator, .String_Iterator:
			return val, true // already converted (Op_Next re-reading it)
		}
	}
	return core.NIL_VALUE, false
}

@(private = "file")
native_iterator_next :: proc(it: core.Value) -> core.Value {
	if it.type != .Obj {
		return core.NIL_VALUE
	}
	#partial switch it.obj_type {
	case .List_Iterator:
		return core.list_iterator_next(cast(^core.List_Iterator_Object)it.obj)
	case .Int_Iterator:
		return core.int_iterator_next(cast(^core.Int_Iterator_Object)it.obj)
	case .String_Iterator:
		return core.string_iterator_next(cast(^core.String_Iterator_Object)it.obj)
	}
	return core.NIL_VALUE
}

// do_foreach handles Op_Foreach: converts __iter's current value to a
// native iterator in place, pulls the first value. Returns the
// end_offset to jump by if the iterable was empty/exhausted immediately
// (0 means "don't jump" -- a real jump is never legitimately 0 bytes,
// since the loop body is never empty in valid compiled output).
do_foreach :: proc(vm: ^VM, slots: int, var_slot, iter_slot: u8, end_offset: int) -> int {
	raw := vm.stack[slots + int(iter_slot)]
	it, ok := make_native_iterator(vm, raw)
	if !ok {
		runtime_error(vm, "Value is not iterable.")
		return 0
	}
	vm.stack[slots + int(iter_slot)] = it
	val := native_iterator_next(it)
	if val.type == .Nil {
		return end_offset
	}
	vm.stack[slots + int(var_slot)] = val
	return 0
}

// do_next handles Op_Next: pulls the next value, storing it into
// var_slot and reporting whether to back-jump into the loop body again
// (true) or fall through to Op_End_Foreach (false, iteration exhausted).
do_next :: proc(vm: ^VM, slots: int, var_slot, iter_slot: u8) -> bool {
	it := vm.stack[slots + int(iter_slot)]
	val := native_iterator_next(it)
	if val.type == .Nil {
		return false
	}
	vm.stack[slots + int(var_slot)] = val
	return true
}
