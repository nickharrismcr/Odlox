package vm

import "../core"
import "core:time"

// The sys.* module: args/clock/sleep/today/now built-ins.

@(private)
define_sys_builtins :: proc(vm: ^VM) {
	define_builtin(vm, "sys", "args", args_builtin)
	define_builtin(vm, "sys", "clock", clock_builtin)
	define_builtin(vm, "sys", "sleep", sleep_builtin)
	define_builtin(vm, "sys", "today", today_builtin)
	define_builtin(vm, "sys", "now", now_builtin)
}

@(private = "file")
args_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	items := make([dynamic]core.Value, len(vm.script_args))
	for a, i in vm.script_args {
		items[i] = core.make_string_value(a)
	}
	list := core.make_list_object(items)
	gc_track(vm, &list.obj)
	return core.make_object_value(&list.obj)
}

@(private = "file")
clock_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	elapsed := time.since(vm.start_time)
	return core.make_float_value(time.duration_seconds(elapsed))
}

@(private = "file")
sleep_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_number(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "sys.sleep argument must be a number")
		return core.NIL_VALUE
	}
	seconds := core.as_float(vm.stack[arg_stack_ptr])
	time.sleep(time.Duration(seconds * f64(time.Second)))
	return core.NIL_VALUE
}

@(private = "file")
today_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	buf: [time.MIN_YYYY_DATE_LEN]u8
	return core.make_string_value(time.to_string_yyyy_mm_dd(time.now(), buf[:]))
}

@(private = "file")
now_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	buf: [time.MIN_HMS_LEN]u8
	return core.make_string_value(time.to_string_hms(time.now(), buf[:]))
}
