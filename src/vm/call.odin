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
// name is an already-interned ^core.String_Object throughout this file
// (see properties.odin's get_property doc comment for why) -- the
// String/List/Dict/Float_Array/Regex/Process builtin dispatch procs
// below still take a plain string, since they switch on the name's
// content rather than use it as a map key, so core.string_get(name) at
// each of those call sites is a cheap, non-hashing conversion, not a
// re-intern.
// cache is a monomorphic inline cache for the .Instance case -- see
// core/chunk.odin's Property_Cache doc comment. Always non-nil here
// (every Op_Invoke bytecode instruction gets a cache slot from the
// compiler, see expr.odin's dot); the .Class (static-method) branch
// deliberately passes nil to invoke_from_class rather than reusing this
// same cache, since a class value and an instance of that class hitting
// the same callsite would otherwise be indistinguishable by class
// pointer alone despite needing different method tables
// (static_methods vs. methods).
invoke :: proc(vm: ^VM, name: ^core.String_Object, arg_count: int, cache: ^core.Property_Cache) -> bool {
	receiver := peek(vm, arg_count)
	#partial switch receiver.type {
	case .Vec2, .Vec3, .Vec4:
		return invoke_vector_method(vm, receiver, core.string_get(name), arg_count)
	}
	if receiver.type != .Obj {
		runtime_error(vm, "Only objects have methods.")
		return false
	}
	#partial switch receiver.obj_type {
	case .Instance:
		inst := core.as_instance(receiver)
		if field_val, ok := inst.fields[name]; ok {
			vm.stack[vm.stack_top - arg_count - 1] = field_val
			return call_value(vm, field_val, arg_count)
		}
		if cache.class == inst.class {
			return call(vm, core.as_closure(cache.method), arg_count)
		}
		return invoke_from_class(vm, inst.class, name, arg_count, false, cache)
	case .Class:
		return invoke_from_class(vm, core.as_class(receiver), name, arg_count, true, nil)
	case .List:
		return invoke_builtin_list(vm, core.as_list(receiver), core.string_get(name), arg_count)
	case .Dict:
		return invoke_builtin_dict(vm, core.as_dict(receiver), core.string_get(name), arg_count)
	case .String:
		return invoke_builtin_string(vm, core.as_string(receiver), core.string_get(name), arg_count)
	case .Float_Array:
		return invoke_builtin_float_array(vm, core.as_float_array(receiver), core.string_get(name), arg_count)
	case .Regex_Pattern:
		return invoke_builtin_regex_pattern(vm, core.as_regex_pattern(receiver), core.string_get(name), arg_count)
	case .Regex_Match:
		return invoke_builtin_regex_match(vm, core.as_regex_match(receiver), core.string_get(name), arg_count)
	case .Process:
		return invoke_builtin_process(vm, core.as_process(receiver), core.string_get(name), arg_count)
	case .Physics_World:
		return invoke_builtin_physics_world(vm, core.as_physics_world(receiver), core.string_get(name), arg_count)
	case .Window:
		return invoke_builtin_window(vm, core.as_window(receiver), core.string_get(name), arg_count)
	case .Image:
		return invoke_builtin_image(vm, core.as_image(receiver), core.string_get(name), arg_count)
	case .Texture:
		return invoke_builtin_texture(vm, core.as_texture(receiver), core.string_get(name), arg_count)
	case .Render_Texture:
		return invoke_builtin_render_texture(vm, core.as_render_texture(receiver), core.string_get(name), arg_count)
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
		fn, found := core.env_get_var(mod.environment, name)
		if !found {
			runtime_error(vm, "Undefined module property '%s'.", core.string_get(name))
			return false
		}
		vm.stack[vm.stack_top - arg_count - 1] = fn
		return call_value(vm, fn, arg_count)
	}
	runtime_error(vm, "Undefined method '%s'.", core.string_get(name))
	return false
}

// invoke_vector_method mirrors glox's own VectorMethodCall (vm.go)
// exactly: the only method a vec2/3/4 supports at all is `.add(other)` --
// in-place addition with an argument of the *same* vec type, mutating
// the receiver and leaving it on the stack as its own return value
// (popping just the one argument, matching the receiver+args -> single-
// return-value convention every other Invoke path follows). Anything
// else -- wrong arg count, a mismatched vec type, or any other method
// name -- is "Invalid use of '.' operator", matching glox's own fallback
// error exactly. `.x`/`.y`/`.z`/`.w` (+ `.r`/`.g`/`.b`/`.a` on Vec4) are
// a separate, already-implemented Get/Set_Property fast path
// (properties.odin) -- not method calls, so not handled here.
@(private = "file")
invoke_vector_method :: proc(vm: ^VM, receiver: core.Value, name: string, arg_count: int) -> bool {
	if name == "add" && arg_count == 1 {
		other := peek(vm, 0)
		#partial switch receiver.type {
		case .Vec2:
			if other.type == .Vec2 {
				r, o := core.as_vec2(receiver), core.as_vec2(other)
				r.x += o.x
				r.y += o.y
				pop(vm)
				return true
			}
		case .Vec3:
			if other.type == .Vec3 {
				r, o := core.as_vec3(receiver), core.as_vec3(other)
				r.x += o.x
				r.y += o.y
				r.z += o.z
				pop(vm)
				return true
			}
		case .Vec4:
			if other.type == .Vec4 {
				r, o := core.as_vec4(receiver), core.as_vec4(other)
				r.x += o.x
				r.y += o.y
				r.z += o.z
				r.w += o.w
				pop(vm)
				return true
			}
		}
	}
	runtime_error(vm, "Invalid use of '.' operator")
	return false
}

// invoke_from_class does the real class.methods[name] (or
// class.static_methods[name]) lookup and, on a hit, populates cache
// (skipped for is_static -- see invoke's doc comment on why static
// dispatch doesn't share a cache slot with instance dispatch) so the
// next call at this site with the same class skips straight past this
// lookup entirely.
invoke_from_class :: proc(vm: ^VM, class: ^core.Class_Object, name: ^core.String_Object, arg_count: int, is_static: bool, cache: ^core.Property_Cache) -> bool {
	method_val, ok := core.Value{}, false
	if is_static {
		method_val, ok = class.static_methods[name]
	} else {
		method_val, ok = class.methods[name]
	}
	if !ok {
		runtime_error(vm, "Undefined method '%s'.", core.string_get(name))
		return false
	}
	if cache != nil && !is_static {
		cache.class = class
		cache.method = method_val
	}
	return call(vm, core.as_closure(method_val), arg_count)
}

// bind_method implements property access to a method value (not a
// call): `instance.method` without `()` produces a Bound_Method_Object
// pairing the receiver with the unbound closure. cache is nil from
// do_get_super (no cache slot allocated for Get_Super sites); non-nil
// from get_property, which already checked cache.class == inst.class
// itself and calls bind_method_cached directly on a hit, so a genuine
// lookup here always means a miss worth (re)populating the cache for.
bind_method :: proc(vm: ^VM, class: ^core.Class_Object, name: ^core.String_Object, cache: ^core.Property_Cache) -> bool {
	method_val, ok := class.methods[name]
	if !ok {
		runtime_error(vm, "Undefined property '%s'.", core.string_get(name))
		return false
	}
	if cache != nil {
		cache.class = class
		cache.method = method_val
	}
	return bind_method_cached(vm, method_val)
}

// bind_method_cached builds the Bound_Method_Object for an
// already-resolved method value -- the shared tail of bind_method's
// genuine-lookup path and get_property's (properties.odin) cache-hit
// fast path, so package-visible rather than file-private.
bind_method_cached :: proc(vm: ^VM, method_val: core.Value) -> bool {
	bound := core.make_bound_method_object(peek(vm, 0), core.as_closure(method_val))
	gc_track(vm, &bound.obj)
	pop(vm) // the receiver
	push(vm, core.make_object_value(&bound.obj))
	return true
}

// collapse_call implements the calling convention every callee kind
// shares regardless of what it is: argCount args + 1 callee/receiver
// slot collapses down to exactly 1 result slot. Package-visible (not
// file-private) since regex.odin's Pattern/Match method dispatch uses
// it too, not just this file's own List/Dict/String/Float_Array ones.
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

// invoke_builtin_float_array ports glox's own farray_methods.go
// (RegisterAllFloatArrayMethods) exactly -- get/set/clear/width/height,
// same argument order -- except an out-of-range get/set is a proper Lox
// runtime error here (core.float_array_get/set's own ok bool) rather
// than glox's native Go panic (obj_builtin_farray.go's FloatArray.Get/Set).
@(private = "file")
invoke_builtin_float_array :: proc(vm: ^VM, f: ^core.Float_Array_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "width":
		if arg_count != 0 {
			runtime_error(vm, "width takes no arguments.")
			return false
		}
		result = core.make_int_value(f.width)
	case "height":
		if arg_count != 0 {
			runtime_error(vm, "height takes no arguments.")
			return false
		}
		result = core.make_int_value(f.height)
	case "get":
		if arg_count != 2 {
			runtime_error(vm, "get takes two arguments (x, y).")
			return false
		}
		x_val, y_val := peek(vm, 1), peek(vm, 0)
		if !core.is_int(x_val) || !core.is_int(y_val) {
			runtime_error(vm, "get arguments must be integers.")
			return false
		}
		v, ok := core.float_array_get(f, core.as_int(x_val), core.as_int(y_val))
		if !ok {
			runtime_error(vm, "Index out of bounds: (%d, %d) for array size %dx%d.", core.as_int(x_val), core.as_int(y_val), f.width, f.height)
			return false
		}
		result = core.make_float_value(v)
	case "set":
		if arg_count != 3 {
			runtime_error(vm, "set takes three arguments (x, y, value).")
			return false
		}
		x_val, y_val, val_val := peek(vm, 2), peek(vm, 1), peek(vm, 0)
		if !core.is_int(x_val) || !core.is_int(y_val) || !core.is_number(val_val) {
			runtime_error(vm, "set arguments must be (int, int, number).")
			return false
		}
		if !core.float_array_set(f, core.as_int(x_val), core.as_int(y_val), core.as_float(val_val)) {
			runtime_error(vm, "Index out of bounds: (%d, %d) for array size %dx%d.", core.as_int(x_val), core.as_int(y_val), f.width, f.height)
			return false
		}
		result = core.NIL_VALUE
	case "clear":
		if arg_count != 1 {
			runtime_error(vm, "clear takes one argument.")
			return false
		}
		val_val := peek(vm, 0)
		if !core.is_number(val_val) {
			runtime_error(vm, "clear argument must be a number.")
			return false
		}
		core.float_array_clear(f, core.as_float(val_val))
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined float_array method '%s'.", name)
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
		if v, ok := core.dict_get(d, core.as_string(key_val)); ok {
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
		v, _ := core.dict_remove(d, core.as_string(key_val))
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
