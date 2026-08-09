package vm

import "../core"

// foreach: a native-iterable fast path (list/string/range, converted
// to one of the three built-in iterator kinds in place, pulled with no
// Lox-level call overhead) plus the user-level protocol (a class
// instance defining __iter__/__next__), which needs a nested
// re-entrant call into run() to invoke those methods -- Run_Mode.Current_Function
// (see run.odin).

@(private = "file")
make_iterator :: proc(vm: ^VM, val: core.Value) -> (core.Value, bool) {
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
		case .Instance:
			return make_user_iterator(vm, val)
		}
	}
	return core.NIL_VALUE, false
}

// make_user_iterator implements the __iter__ half of the user-level
// protocol: val.__iter__() must return another instance that itself
// has a __next__ method -- checked here, once, rather than assumed and
// left to fail on every subsequent pull.
@(private = "file")
make_user_iterator :: proc(vm: ^VM, val: core.Value) -> (core.Value, bool) {
	inst := core.as_instance(val)
	method_val, ok := inst.class.methods[core.intern_string("__iter__")]
	if !ok {
		return core.NIL_VALUE, false
	}
	push(vm, val) // receiver for the 0-arg __iter__() call, mirrors Op_Invoke's own convention
	result, call_ok := call_closure_now(vm, method_val, 0)
	if !call_ok {
		return core.NIL_VALUE, false // vm.error_msg already set by the failed nested run
	}
	if result.type != .Obj || result.obj_type != .Instance {
		runtime_error(vm, "Foreach iterator must be an object with a __next__ method.")
		return core.NIL_VALUE, false
	}
	if _, has_next := core.as_instance(result).class.methods[core.intern_string("__next__")]; !has_next {
		runtime_error(vm, "Foreach iterator must have a __next__ method.")
		return core.NIL_VALUE, false
	}
	return result, true
}

// call_closure_now synchronously calls a Lox method (already resolved
// to a Closure_Object -- both __iter__ and __next__ always are, being
// entries out of Class.methods) with its receiver/args already pushed,
// via a nested run(vm, .Current_Function). Unlike run.odin's Op_Str
// (__str__ dispatch), which can just push a frame and let the *outer*
// dispatch loop carry on since its call is the very last thing that
// opcode does, iterator_next below needs the call's result back
// immediately, mid-opcode, to decide what happens next (nil means
// "iteration exhausted") -- exactly the case Run_Mode.Current_Function
// exists for. Deliberately calls the lower-level `call` (not the more
// general `call_value`), which would also have to handle Native/Class/
// Bound_Method receivers that a nested run() call isn't set up to
// follow correctly -- never a real possibility here since method_val
// only ever comes from Class.methods, but call() being Closure-only
// makes that guarantee explicit at the type level instead of implicit.
@(private = "file")
call_closure_now :: proc(vm: ^VM, method_val: core.Value, arg_count: int) -> (core.Value, bool) {
	if !call(vm, core.as_closure(method_val), arg_count) {
		return core.NIL_VALUE, false
	}
	status, result := run(vm, .Current_Function)
	return result, status == .Ok
}

@(private = "file")
iterator_next :: proc(vm: ^VM, it: core.Value) -> core.Value {
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
	case .Instance:
		inst := core.as_instance(it)
		method_val, ok := inst.class.methods[core.intern_string("__next__")]
		if !ok {
			runtime_error(vm, "Foreach iterator must have a __next__ method.")
			return core.NIL_VALUE
		}
		push(vm, it) // receiver for the 0-arg __next__() call
		result, call_ok := call_closure_now(vm, method_val, 0)
		if !call_ok {
			return core.NIL_VALUE // vm.error_msg already set by the failed nested run
		}
		return result
	}
	return core.NIL_VALUE
}

// do_foreach handles Op_Foreach: converts __iter's current value to an
// iterator (native or user-protocol) in place, pulls the first value.
// Returns the end_offset to jump by if the iterable was empty/exhausted
// immediately (0 means "don't jump" -- a real jump is never legitimately
// 0 bytes, since the loop body is never empty in valid compiled output).
do_foreach :: proc(vm: ^VM, slots: int, var_slot, iter_slot: u8, end_offset: int) -> int {
	raw := vm.stack[slots + int(iter_slot)]
	it, ok := make_iterator(vm, raw)
	if !ok {
		if vm.error_msg == "" {
			runtime_error(vm, "Value is not iterable.")
		}
		return end_offset // inert on error: vm.error_msg is already set, the
		// shared error-conversion tail (run.odin) raises the real
		// exception right after this opcode returns -- jumping past the
		// loop body here is just "don't execute it with garbage state",
		// not the actual error handling.
	}
	vm.stack[slots + int(iter_slot)] = it
	val := iterator_next(vm, it)
	if val.type == .Nil {
		return end_offset
	}
	vm.stack[slots + int(var_slot)] = val
	return 0
}

// do_next handles Op_Next: pulls the next value, storing it into
// var_slot and reporting whether to back-jump into the loop body again
// (true) or fall through to Op_End_Foreach (false, iteration exhausted
// -- or an error; see do_foreach's doc comment on why that's inert
// here rather than handled specially).
do_next :: proc(vm: ^VM, slots: int, var_slot, iter_slot: u8) -> bool {
	it := vm.stack[slots + int(iter_slot)]
	val := iterator_next(vm, it)
	if val.type == .Nil {
		return false
	}
	vm.stack[slots + int(var_slot)] = val
	return true
}
