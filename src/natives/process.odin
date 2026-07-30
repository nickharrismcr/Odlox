package natives

import "../core"
import "../vm"
import "core:os"
import "core:strings"

// process: module-level entry points (spawn/parent/wait_any) -- see
// vm/process.odin for the actual object, its methods, and the pipe-
// framing/polling logic they share.

@(private)
register_process :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "process")
	vm.define_builtin(v, "process", "spawn", process_spawn)
	vm.define_builtin(v, "process", "parent", process_parent)
	vm.define_builtin(v, "process", "wait_any", process_wait_any_fn)
}

// process_spawn launches another odlox process running script_path,
// connected to the caller by a pipe on the child's stdin/stdout. Extra
// arguments become the child's own sys.args() -- passed straight
// through as additional command-line arguments, exactly like main.odin's
// own CLI parsing already treats everything after the script path.
@(private = "file")
process_spawn :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc < 1 {
		vm.runtime_error(v, "spawn() expects at least 1 argument (script path).")
		return core.NIL_VALUE
	}
	script_val := v.stack[arg_stack_ptr]
	if !core.is_string(script_val) {
		vm.runtime_error(v, "spawn() first argument must be a string (script path).")
		return core.NIL_VALUE
	}
	script_path := core.string_get(core.as_string(script_val))

	command: [dynamic]string
	append(&command, os.args[0], script_path)
	for i in 1 ..< argc {
		arg_val := v.stack[arg_stack_ptr + i]
		if !core.is_string(arg_val) {
			vm.runtime_error(v, "spawn() extra arguments must be strings.")
			return core.NIL_VALUE
		}
		s := core.string_get(core.as_string(arg_val))
		if strings.has_prefix(s, "-") {
			vm.runtime_error(v, "spawn() extra arguments must not start with '-'.")
			return core.NIL_VALUE
		}
		append(&command, s)
	}
	defer delete(command)

	child_stdin_read, parent_stdin_write, err1 := os.pipe()
	if err1 != nil {
		vm.runtime_error_named(v, "ProcessError", "failed to create stdin pipe: %v", err1)
		return core.NIL_VALUE
	}
	parent_stdout_read, child_stdout_write, err2 := os.pipe()
	if err2 != nil {
		os.close(child_stdin_read)
		os.close(parent_stdin_write)
		vm.runtime_error_named(v, "ProcessError", "failed to create stdout pipe: %v", err2)
		return core.NIL_VALUE
	}

	child, serr := os.process_start({
		command = command[:],
		stdin   = child_stdin_read,
		stdout  = child_stdout_write,
	})
	// The child's own ends were duplicated into the new process; this
	// side no longer needs them.
	os.close(child_stdin_read)
	os.close(child_stdout_write)
	if serr != nil {
		os.close(parent_stdin_write)
		os.close(parent_stdout_read)
		vm.runtime_error_named(v, "ProcessError", "failed to start process: %v", serr)
		return core.NIL_VALUE
	}

	proc_obj := core.make_process_object(parent_stdout_read, parent_stdin_write, child)
	vm.gc_track(v, &proc_obj.obj)
	return core.make_object_value(&proc_obj.obj)
}

// process_parent returns a Process wired to this process's own stdin/
// stdout -- the far end of the pipe whatever spawned this one is
// holding. Used inside a worker script to talk back to its parent; only
// exposes send/recv/try_recv (invoke_builtin_process's wait/kill/pid
// cases already require p.child to be present, which this variant never
// has).
@(private = "file")
process_parent :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 0 {
		vm.runtime_error(v, "parent() expects no arguments.")
		return core.NIL_VALUE
	}
	proc_obj := core.make_process_object(os.stdin, os.stdout, nil)
	vm.gc_track(v, &proc_obj.obj)
	return core.make_object_value(&proc_obj.obj)
}

@(private = "file")
process_wait_any_fn :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "wait_any() expects 1 argument (a list of processes).")
		return core.NIL_VALUE
	}
	list_val := v.stack[arg_stack_ptr]
	if !(list_val.type == .Obj && list_val.obj_type == .List) {
		vm.runtime_error(v, "wait_any() argument must be a list of processes.")
		return core.NIL_VALUE
	}
	list := core.as_list(list_val)
	if len(list.items) == 0 {
		vm.runtime_error(v, "wait_any() list must not be empty.")
		return core.NIL_VALUE
	}
	procs: [dynamic]^core.Process_Object
	defer delete(procs)
	for item in list.items {
		if !(item.type == .Obj && item.obj_type == .Process) {
			vm.runtime_error(v, "wait_any() list must contain only process objects.")
			return core.NIL_VALUE
		}
		append(&procs, core.as_process(item))
	}

	// Whether !ok means "every process finished" (nil, no error) or "a
	// genuine I/O problem" (an exception, raised from inside
	// process_wait_any via runtime_error_named) is resolved by the VM's
	// own shared error-conversion tail (run.odin, checked once per
	// instruction) reading vm.error_msg after this call returns -- either
	// way, returning nil here is correct: a live result is always the
	// (index, value) tuple built below, so nil alone is unambiguous.
	index, result, ok := vm.process_wait_any(v, procs[:])
	if !ok {
		return core.NIL_VALUE
	}
	items: [dynamic]core.Value
	append(&items, core.make_int_value(index), result)
	t := core.make_list_object(items, true)
	vm.gc_track(v, &t.obj)
	return core.make_object_value(&t.obj, true)
}
