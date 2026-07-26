package vm

import "../core"

// Function/method call mechanism. call_value is the general entry point
// (Op_Call: dispatches on whatever kind of callable is on the stack);
// invoke is Op_Invoke's fast path for `receiver.method(args)`, skipping
// the separate property-lookup step call_value alone would need.

call_value :: proc(vm: ^VM, callee: core.Value, arg_count: int) -> bool {
	if callee.type != .Obj {
		runtime_error(vm, "Can only call functions and classes.")
		return false
	}
	#partial switch callee.obj_type {
	case .Closure:
		return call(vm, core.as_closure(callee), arg_count)

	case .Native:
		native := core.as_native(callee)
		arg_stack_ptr := vm.stack_top - arg_count
		result := native.function(arg_count, arg_stack_ptr, rawptr(vm))
		collapse_call(vm, arg_count, result)
		return true

	case .Class:
		// A class value called like a function *is* the constructor
		// path -- there's no separate "construct" opcode.
		class := core.as_class(callee)
		inst := core.make_instance_object(class)
		gc_track(vm, &inst.obj)
		vm.stack[vm.stack_top - arg_count - 1] = core.make_object_value(&inst.obj)
		if init_val, ok := class.methods[core.intern_string("init")]; ok {
			return call(vm, core.as_closure(init_val), arg_count)
		}
		if arg_count != 0 {
			runtime_error(vm, "Expected 0 arguments but got %d.", arg_count)
			return false
		}
		return true

	case .Bound_Method:
		bm := core.as_bound_method(callee)
		vm.stack[vm.stack_top - arg_count - 1] = bm.receiver
		return call(vm, bm.method, arg_count)
	}
	runtime_error(vm, "Can only call functions and classes.")
	return false
}

// call is where arity/default/variadic argument shaping actually
// happens -- see docs/plans/default-variadic-params.md in the glox
// reference repo for the design this ports. Pads any omitted optional
// parameters with Value.Undefined (which the callee's own
// Op_Jump_If_Defined prologue, emitted by functions.odin, checks for)
// and collects surplus positional arguments into a fresh list for a
// trailing `*rest` parameter.
call :: proc(vm: ^VM, closure: ^core.Closure_Object, arg_count: int) -> bool {
	fn := closure.function
	fixed_count := fn.arity
	if fn.is_variadic {
		fixed_count -= 1
	}

	if fn.is_variadic {
		if arg_count < fn.min_arity {
			runtime_error(vm, "Expected at least %d arguments but got %d.", fn.min_arity, arg_count)
			return false
		}
	} else if arg_count < fn.min_arity || arg_count > fixed_count {
		if fn.min_arity == fixed_count {
			runtime_error(vm, "Expected %d arguments but got %d.", fixed_count, arg_count)
		} else {
			runtime_error(vm, "Expected between %d and %d arguments but got %d.", fn.min_arity, fixed_count, arg_count)
		}
		return false
	}

	if fn.is_variadic {
		if arg_count >= fixed_count {
			surplus := arg_count - fixed_count
			items := make([dynamic]core.Value, surplus)
			for i := surplus - 1; i >= 0; i -= 1 {
				items[i] = pop(vm)
			}
			rest := core.make_list_object(items)
			gc_track(vm, &rest.obj)
			push(vm, core.make_object_value(&rest.obj))
		} else {
			for _ in arg_count ..< fixed_count {
				push(vm, core.UNDEFINED_VALUE)
			}
			rest := core.make_list_object(make([dynamic]core.Value))
			gc_track(vm, &rest.obj)
			push(vm, core.make_object_value(&rest.obj))
		}
	} else {
		for _ in arg_count ..< fn.arity {
			push(vm, core.UNDEFINED_VALUE)
		}
	}

	if vm.frame_count == FRAMES_MAX {
		runtime_error(vm, "Stack overflow.")
		return false
	}

	vm.frames[vm.frame_count] = Call_Frame {
		closure = closure,
		ip      = 0,
		slots   = vm.stack_top - fn.arity - 1,
		depth   = vm.frame_count + 1,
	}
	vm.frame_count += 1
	if vm.debug_hook != nil {
		vm.debug_hook(vm, .Call)
	}
	return true
}

// invoke: Op_Invoke's fast path. A field holding a callable shadows a
// method of the same name (`this.fn(x)` calls the field value, not a
// method called `fn`) -- checked first for instances, matching glox.
invoke :: proc(vm: ^VM, name: string, arg_count: int) -> bool {
	receiver := peek(vm, arg_count)
	if receiver.type != .Obj {
		runtime_error(vm, "Only objects have methods.")
		return false
	}
	#partial switch receiver.obj_type {
	case .Instance:
		inst := core.as_instance(receiver)
		if field_val, ok := inst.fields[core.intern_string(name)]; ok {
			vm.stack[vm.stack_top - arg_count - 1] = field_val
			return call_value(vm, field_val, arg_count)
		}
		return invoke_from_class(vm, inst.class, name, arg_count, false)
	case .Class:
		return invoke_from_class(vm, core.as_class(receiver), name, arg_count, true)
	case .List:
		return invoke_builtin_list(vm, core.as_list(receiver), name, arg_count)
	case .Dict:
		return invoke_builtin_dict(vm, core.as_dict(receiver), name, arg_count)
	case .String:
		return invoke_builtin_string(vm, core.as_string(receiver), name, arg_count)
	case .Module:
		// `mod.fn(args)` -- a module has no "methods" of its own, just
		// name-keyed members (native functions, for a built-in module;
		// whatever the module's top-level code exported, for an
		// imported *.lox file). Found missing via the first real
		// smoke test of any built-in module function (`sys.clock()`):
		// `.name(args)` always compiles through Op_Invoke (see
		// expr.odin's dot), never a separate Get_Property+Call, so
		// without this case every built-in module call fell through
		// to "Undefined method" regardless of whether the member
		// existed.
		mod := core.as_module(receiver)
		fn, found := core.env_get_var(mod.environment, core.intern_string(name))
		if !found {
			runtime_error(vm, "Undefined module property '%s'.", name)
			return false
		}
		vm.stack[vm.stack_top - arg_count - 1] = fn
		return call_value(vm, fn, arg_count)
	}
	runtime_error(vm, "Undefined method '%s'.", name)
	return false
}

invoke_from_class :: proc(vm: ^VM, class: ^core.Class_Object, name: string, arg_count: int, is_static: bool) -> bool {
	key := core.intern_string(name)
	method_val, ok := core.Value{}, false
	if is_static {
		method_val, ok = class.static_methods[key]
	} else {
		method_val, ok = class.methods[key]
	}
	if !ok {
		runtime_error(vm, "Undefined method '%s'.", name)
		return false
	}
	return call(vm, core.as_closure(method_val), arg_count)
}

// bind_method implements property access to a method value (not a
// call): `instance.method` without `()` produces a Bound_Method_Object
// pairing the receiver with the unbound closure.
bind_method :: proc(vm: ^VM, class: ^core.Class_Object, name: string) -> bool {
	method_val, ok := class.methods[core.intern_string(name)]
	if !ok {
		runtime_error(vm, "Undefined property '%s'.", name)
		return false
	}
	bound := core.make_bound_method_object(peek(vm, 0), core.as_closure(method_val))
	gc_track(vm, &bound.obj)
	pop(vm) // the receiver
	push(vm, core.make_object_value(&bound.obj))
	return true
}

// collapse_call implements the calling convention every callee kind
// shares regardless of what it is: argCount args + 1 callee/receiver
// slot collapses down to exactly 1 result slot.
@(private = "file")
collapse_call :: proc(vm: ^VM, arg_count: int, result: core.Value) {
	vm.stack_top -= arg_count + 1
	push(vm, result)
}

// -----------------------------------------------------------------------
// Built-in list/dict/string methods -- the small, VM-primitive subset
// wired up now (Phase 4) using the pure-data procs Phase 2 already
// wrote (core.list_append etc.); the fuller method surface (raylib
// natives, sys/os/regexp/pickle modules) is Phase 6's job.

@(private = "file")
invoke_builtin_list :: proc(vm: ^VM, l: ^core.List_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "append":
		if arg_count != 1 {
			runtime_error(vm, "append takes one argument.")
			return false
		}
		core.list_append(l, peek(vm, 0))
		result = core.NIL_VALUE
	case "remove":
		if arg_count != 1 {
			runtime_error(vm, "remove takes one argument.")
			return false
		}
		core.list_remove(l, core.as_int(peek(vm, 0)))
		result = core.NIL_VALUE
	case "find":
		if arg_count != 1 {
			runtime_error(vm, "find takes one argument.")
			return false
		}
		target := peek(vm, 0)
		found := -1
		for item, i in l.items {
			if core.values_equal(item, target, true) {
				found = i
				break
			}
		}
		result = core.NIL_VALUE if found == -1 else core.make_int_value(found)
	case "length":
		if arg_count != 0 {
			runtime_error(vm, "length takes no arguments.")
			return false
		}
		result = core.make_int_value(core.list_length(l))
	case:
		runtime_error(vm, "Undefined list method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}

@(private = "file")
invoke_builtin_dict :: proc(vm: ^VM, d: ^core.Dict_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "get":
		if arg_count != 1 && arg_count != 2 {
			runtime_error(vm, "get takes one or two arguments.")
			return false
		}
		key_val := peek(vm, arg_count - 1)
		if !core.is_string(key_val) {
			runtime_error(vm, "Key argument to get must be a string.")
			return false
		}
		if v, ok := core.dict_get(d, core.string_get(core.as_string(key_val))); ok {
			result = v
		} else if arg_count == 2 {
			result = peek(vm, 0)
		} else {
			result = core.NIL_VALUE
		}
	case "keys":
		keys := core.dict_keys(d)
		gc_track(vm, &keys.obj)
		result = core.make_object_value(&keys.obj)
	case "remove":
		if arg_count != 1 {
			runtime_error(vm, "remove takes one argument.")
			return false
		}
		key_val := peek(vm, 0)
		if !core.is_string(key_val) {
			runtime_error(vm, "Argument to remove must be a string key.")
			return false
		}
		v, _ := core.dict_remove(d, core.string_get(core.as_string(key_val)))
		result = v
	case:
		runtime_error(vm, "Undefined dict method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}

@(private = "file")
invoke_builtin_string :: proc(vm: ^VM, s: ^core.String_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	// "length" isn't one of glox's real string methods (glox strings
	// only have replace/join -- string length goes through the free
	// `len(s)` function instead, see builtins.odin's len_builtin) --
	// kept anyway as a harmless, documented superset addition from
	// Phase 4 rather than removed as part of this phase's "match
	// glox's real method tables" pass, since nothing in the ported
	// test suite depends on its absence and it's a reasonable
	// convenience.
	case "length":
		if arg_count != 0 {
			runtime_error(vm, "length takes no arguments.")
			return false
		}
		result = core.make_int_value(core.string_length(s))
	case "replace":
		if arg_count != 2 {
			runtime_error(vm, "replace takes two arguments.")
			return false
		}
		from_val := peek(vm, 1)
		to_val := peek(vm, 0)
		if !core.is_string(from_val) || !core.is_string(to_val) {
			runtime_error(vm, "replace arguments must be strings.")
			return false
		}
		result = core.string_replace(s, core.as_string(from_val), core.as_string(to_val))
	case "join":
		if arg_count != 1 || !core.is_obj(peek(vm, 0)) || peek(vm, 0).obj_type != .List {
			runtime_error(vm, "join takes one list argument.")
			return false
		}
		joined, ok := core.list_join(core.as_list(peek(vm, 0)), core.string_get(s))
		if !ok {
			runtime_error(vm, "join: list contains a non-string item.")
			return false
		}
		result = joined
	case:
		runtime_error(vm, "Undefined string method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}
