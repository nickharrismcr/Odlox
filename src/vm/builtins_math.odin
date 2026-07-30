package vm

import "../core"
import "core:math"

// The low-level, underscore-prefixed native functions (`_sin`, `_cos`,
// ...) that the Lox-source `math` module wraps with int-to-float
// coercion and higher-level helpers (vector length, etc.) before
// exposing `sin`/`cos`/... to user code. These register as plain
// global names; `math.lox` is what makes `import math` work, and these
// functions are just the native floor it's built on.

@(private)
define_math_builtins :: proc(vm: ^VM) {
	define_builtin(vm, "", "_sin", sin_builtin)
	define_builtin(vm, "", "_cos", cos_builtin)
	define_builtin(vm, "", "_tan", tan_builtin)
	define_builtin(vm, "", "_sqrt", sqrt_builtin)
	define_builtin(vm, "", "_pow", pow_builtin)
	define_builtin(vm, "", "_atan2", atan2_builtin)
}

@(private = "file")
sin_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_float(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument to sin.")
		return core.NIL_VALUE
	}
	return core.make_float_value(math.sin(core.as_float(vm.stack[arg_stack_ptr])))
}

@(private = "file")
cos_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_float(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument to cos.")
		return core.NIL_VALUE
	}
	return core.make_float_value(math.cos(core.as_float(vm.stack[arg_stack_ptr])))
}

@(private = "file")
tan_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_float(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument to tan.")
		return core.NIL_VALUE
	}
	return core.make_float_value(math.tan(core.as_float(vm.stack[arg_stack_ptr])))
}

@(private = "file")
sqrt_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_float(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument to sqrt.")
		return core.NIL_VALUE
	}
	return core.make_float_value(math.sqrt(core.as_float(vm.stack[arg_stack_ptr])))
}

@(private = "file")
pow_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 2 || !core.is_float(vm.stack[arg_stack_ptr]) || !core.is_float(vm.stack[arg_stack_ptr + 1]) {
		runtime_error(vm, "Invalid argument to pow.")
		return core.NIL_VALUE
	}
	base := core.as_float(vm.stack[arg_stack_ptr])
	exp := core.as_float(vm.stack[arg_stack_ptr + 1])
	return core.make_float_value(math.pow(base, exp))
}

@(private = "file")
atan2_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 2 || !core.is_float(vm.stack[arg_stack_ptr]) || !core.is_float(vm.stack[arg_stack_ptr + 1]) {
		runtime_error(vm, "Invalid argument to atan2.")
		return core.NIL_VALUE
	}
	y := core.as_float(vm.stack[arg_stack_ptr])
	x := core.as_float(vm.stack[arg_stack_ptr + 1])
	return core.make_float_value(math.atan2(y, x))
}
