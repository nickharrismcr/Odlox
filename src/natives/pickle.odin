package natives

import "../core"
import "../vm"

// pickle: plain-data serialisation. The actual encoder/decoder lives in
// core/pickle.odin -- see that file for the wire format and its own
// doc comment on why it lives in core rather than here. Class instances
// round-trip their field data only, never methods/code -- loads()
// resolves the class by name against the *calling frame's own* global
// scope (vm.resolve_class_by_name, exceptions.odin -- the same lookup
// an `except ClassName` clause uses), so an instance of a class that's
// only a global in some other module's own scope can't be
// reconstructed there.

@(private)
register_pickle :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "pickle")
	vm.define_builtin(v, "pickle", "dumps", pickle_dumps)
	vm.define_builtin(v, "pickle", "loads", pickle_loads)
}

@(private = "file")
pickle_dumps :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "Invalid argument count to dumps.")
		return core.NIL_VALUE
	}
	data, err, ok := core.pickle_encode(v.stack[arg_stack_ptr])
	if !ok {
		vm.runtime_error_named(v, "PickleError", "%s", err)
		return core.NIL_VALUE
	}
	defer delete(data)
	return core.make_string_value(string(data))
}

// pickle_resolve_class is core.Class_Resolver's own concrete
// implementation here -- a plain function (not a closure), taking the
// resolving VM as an opaque ctx pointer core itself can't name (core
// sits below vm in the package graph; same rawptr-boundary shape as
// core.Builtin_Fn).
@(private = "file")
pickle_resolve_class :: proc(name: string, ctx: rawptr) -> (^core.Class_Object, bool) {
	return vm.resolve_class_by_name(vm.native_vm(ctx), name)
}

@(private = "file")
pickle_loads :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "Invalid argument count to loads.")
		return core.NIL_VALUE
	}
	data_val := v.stack[arg_stack_ptr]
	if !core.is_string(data_val) {
		vm.runtime_error(v, "Invalid argument type to loads, expected string.")
		return core.NIL_VALUE
	}
	data := core.string_get(core.as_string(data_val))

	result, err, ok := core.pickle_decode(transmute([]u8)data, pickle_resolve_class, vm_ptr)
	if !ok {
		vm.runtime_error_named(v, "PickleError", "%s", err)
		return core.NIL_VALUE
	}
	vm.gc_adopt(v, result)
	return result
}
