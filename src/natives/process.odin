package natives

import "../core"
import "../vm"
import "core:os"
import "core:strings"
import "core:sys/windows"
import "core:time"

// process: spawns other odlox processes and communicates with them over
// a pipe carrying pickled values. There is no general-purpose threading
// model exposed anywhere in this interpreter (see docs/ARCHITECTURE.md's
// Scope section -- threads are out of scope entirely), so recv/try_recv
// poll the pipe directly instead of blocking on a background reader
// (Windows' PeekNamedPipe, checked before an actual read), and wait_any
// round-robins try_recv across every still-live process with a short
// sleep between full rounds rather than blocking on a true multi-handle
// select. Observable behavior is what a true blocking wait would give
// (blocks until something is ready, returns nil once every process has
// finished, raises Process_Error on a genuine I/O problem) -- just with
// polling latency instead of an OS-level wait, and no background thread
// to manage.
//
// Userdata_Object object kind (see core/obj_userdata.odin and this
// package's own README.md) -- data, construction, method dispatch, and
// the pipe-framing/polling logic it all shares live together in this one
// file.

FRAME_LEN_SIZE :: 4

// Process_Data represents one end of a pipe-backed channel carrying
// length-prefixed pickled values (pickle_encode/pickle_decode, framed
// with a 4-byte little-endian length prefix -- see frame_write/frame_read
// below). Doubles as both "the process I spawned" (child != nil, exposes
// wait/kill/pid) and "the channel back to whoever spawned me" (child ==
// nil, constructed wrapping this process's own stdin/stdout).
Process_Data :: struct {
	read_file:  ^os.File,
	write_file: ^os.File,
	child:      Maybe(os.Process), // nil for the parent-channel variant
	done:       bool, // latched once a clean EOF has been observed on read_file
}

@(private = "file")
process_vtable := core.Userdata_Vtable {
	tag    = "process",
	free   = process_data_free,
	invoke = process_invoke,
}

@(private = "file")
process_data_free :: proc(data: rawptr) {
	p := cast(^Process_Data)data
	os.close(p.read_file)
	os.close(p.write_file)
	free(p)
}

// is_process_value: type-checks a Value against specifically this
// module's Userdata kind. obj_type alone can't distinguish "a Process"
// from "some other Userdata kind" the way it could when Process had its
// own Object_Type tag -- vtable pointer identity is the replacement (the
// same test luaL_checkudata does against a metatable in Lua), safe
// because process_vtable is one static instance shared by every Process
// this module constructs.
@(private = "file")
is_process_value :: proc(v: core.Value) -> bool {
	return v.type == .Obj && v.obj_type == .Userdata && core.as_userdata(v).vtable == &process_vtable
}

@(private = "file")
read_full :: proc(f: ^os.File, buf: []u8) -> bool {
	total := 0
	for total < len(buf) {
		n, err := os.read(f, buf[total:])
		if n == 0 && err == nil {
			return false // clean EOF
		}
		if err != nil {
			return false
		}
		total += n
	}
	return true
}

@(private = "file")
write_full :: proc(f: ^os.File, buf: []u8) -> bool {
	total := 0
	for total < len(buf) {
		n, err := os.write(f, buf[total:])
		if err != nil {
			return false
		}
		total += n
	}
	return true
}

// frame_write pickle-encodes v and writes it to f as a 4-byte little-
// endian length prefix followed by the encoded bytes, so multiple
// values can share one stream without running together.
@(private = "file")
frame_write :: proc(f: ^os.File, v: core.Value) -> (err: string, ok: bool) {
	data, eerr, eok := core.pickle_encode(v)
	if !eok {
		return eerr, false
	}
	defer delete(data)
	length_bytes := transmute([4]u8)u32(len(data))
	if !write_full(f, length_bytes[:]) {
		return "broken pipe", false
	}
	if !write_full(f, data) {
		return "broken pipe", false
	}
	return "", true
}

// frame_read reads one length-prefixed value written by frame_write.
// eof is true (with ok false) if the stream closed cleanly before any
// bytes of the next frame arrived -- callers use this to detect the
// peer closing its end of the pipe, distinct from a genuine I/O error.
@(private = "file")
frame_read :: proc(v: ^vm.VM, f: ^os.File) -> (result: core.Value, err: string, eof: bool, ok: bool) {
	length_bytes: [4]u8
	if !read_full(f, length_bytes[:]) {
		return core.NIL_VALUE, "", true, false
	}
	n := int(transmute(u32)length_bytes)
	data := make([]u8, n)
	defer delete(data)
	if !read_full(f, data) {
		return core.NIL_VALUE, "truncated message", false, false
	}
	result, err, ok = core.pickle_decode(data, pickle_resolve_class_for_process, v)
	if !ok {
		return core.NIL_VALUE, err, false, false
	}
	vm.gc_adopt(v, result)
	return result, "", false, true
}

@(private = "file")
pickle_resolve_class_for_process :: proc(name: string, ctx: rawptr) -> (^core.Class_Object, bool) {
	return vm.resolve_class_by_name(vm.native_vm(ctx), name)
}

// try_frame_read peeks a process's read end without blocking (Windows'
// PeekNamedPipe): returns has_data=false immediately if fewer than
// FRAME_LEN_SIZE bytes are currently buffered, rather than reading and
// possibly stalling on a message that hasn't fully arrived yet. Once the
// length prefix itself is available, the payload is assumed to follow
// shortly after (the writer already flushed it as one frame_write call)
// and is read with an ordinary, briefly-blocking frame_read -- a
// deliberate simplification over a byte-exact non-blocking read of the
// whole message; see this file's own header comment.
@(private = "file")
try_frame_read :: proc(v: ^vm.VM, f: ^os.File) -> (result: core.Value, err: string, eof: bool, has_data: bool, ok: bool) {
	handle := windows.HANDLE(os.fd(f))
	total_avail: u32
	peek_ok := windows.PeekNamedPipe(handle, nil, 0, nil, &total_avail, nil)
	if peek_ok && total_avail < FRAME_LEN_SIZE {
		return core.NIL_VALUE, "", false, false, false
	}
	// Either data is ready, or the peek itself failed. A failed peek is
	// NOT treated as an immediate EOF signal here: Windows' PeekNamedPipe
	// can report a broken pipe as soon as the writer closes its end, even
	// while buffered data the writer already sent is still sitting
	// unread in the pipe. Treating a failed peek as EOF would lose
	// whichever messages hadn't been drained yet, and misreport a message
	// that hadn't even finished being *read* as "truncated message"
	// instead. A real (blocking) read is the actual authority on EOF vs a
	// genuine message either way -- and since CreatePipe's anonymous pipes
	// are ordinary blocking pipes, a read attempted here either returns
	// already-buffered bytes immediately or discovers true EOF
	// immediately (the write end really is gone and the buffer really is
	// empty); it does not hang the round-robin poll this feeds into.
	result, err, eof, ok = frame_read(v, f)
	return result, err, eof, true, ok
}

@(private = "file")
process_send :: proc(v: ^vm.VM, p: ^Process_Data, val: core.Value) -> bool {
	err, ok := frame_write(p.write_file, val)
	if !ok {
		vm.runtime_error_named(v, "ProcessError", "%s", err)
		return false
	}
	return true
}

@(private = "file")
process_recv :: proc(v: ^vm.VM, p: ^Process_Data) -> (core.Value, bool) {
	result, err, eof, ok := frame_read(v, p.read_file)
	if !ok {
		if eof {
			vm.runtime_error_named(v, "ProcessError", "peer closed the connection")
		} else {
			vm.runtime_error_named(v, "ProcessError", "%s", err)
		}
		return core.NIL_VALUE, false
	}
	return result, true
}

// process_try_recv_impl returns (true, value, true) on a message, (true,
// nil, false) if nothing is ready yet, or (false, nil, false) plus a
// raised ProcessError on a genuine I/O problem (matching recv()'s own
// error behavior, just non-blocking when nothing is available yet).
@(private = "file")
process_try_recv_impl :: proc(v: ^vm.VM, p: ^Process_Data) -> (had_data: bool, result: core.Value, ok: bool) {
	res, err, eof, has_data, rok := try_frame_read(v, p.read_file)
	if !has_data {
		return false, core.NIL_VALUE, true
	}
	if !rok {
		if eof {
			p.done = true
			vm.runtime_error_named(v, "ProcessError", "peer closed the connection")
		} else {
			vm.runtime_error_named(v, "ProcessError", "%s", err)
		}
		return true, core.NIL_VALUE, false
	}
	return true, res, true
}

// process_wait_any_impl polls every not-yet-finished process in round
// robin (a short sleep between full rounds once none are ready) until
// one has a message, returning its index into processes plus the value.
// A process that reports a clean EOF is dropped from consideration (not
// an error for the wait as a whole) rather than ending the loop; once
// every process has finished, returns ok=false with no error raised --
// nil is the unambiguous "the whole pool is done" signal, distinct from
// a raised ProcessError on a genuine I/O problem.
@(private = "file")
process_wait_any_impl :: proc(v: ^vm.VM, processes: []^Process_Data) -> (index: int, result: core.Value, ok: bool) {
	for {
		any_live := false
		for p, i in processes {
			if p.done {
				continue
			}
			any_live = true
			handle := windows.HANDLE(os.fd(p.read_file))
			total_avail: u32
			peek_ok := windows.PeekNamedPipe(handle, nil, 0, nil, &total_avail, nil)
			if peek_ok && total_avail < FRAME_LEN_SIZE {
				continue
			}
			// A failed peek is not treated as EOF outright -- see
			// try_frame_read's own doc comment for why (Windows can
			// report a broken pipe before buffered data the peer already
			// sent has actually been drained). A real read is the
			// authority on EOF vs a genuine message either way.
			res, err, eof, rok := frame_read(v, p.read_file)
			if !rok {
				p.done = true
				if !eof {
					vm.runtime_error_named(v, "ProcessError", "%s", err)
					return 0, core.NIL_VALUE, false
				}
				continue
			}
			return i, res, true
		}
		if !any_live {
			return 0, core.NIL_VALUE, false
		}
		time.sleep(time.Millisecond * 5)
	}
}

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

	data := new(Process_Data)
	data.read_file = parent_stdout_read
	data.write_file = parent_stdin_write
	data.child = child
	o := core.make_userdata_object(&process_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj)
}

// process_parent returns a Process wired to this process's own stdin/
// stdout -- the far end of the pipe whatever spawned this one is
// holding. Used inside a worker script to talk back to its parent; only
// exposes send/recv/try_recv (process_invoke's wait/kill/pid cases
// already require p.child to be present, which this variant never has).
@(private = "file")
process_parent :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 0 {
		vm.runtime_error(v, "parent() expects no arguments.")
		return core.NIL_VALUE
	}
	data := new(Process_Data)
	data.read_file = os.stdin
	data.write_file = os.stdout
	o := core.make_userdata_object(&process_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj)
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
	procs: [dynamic]^Process_Data
	defer delete(procs)
	for item in list.items {
		if !is_process_value(item) {
			vm.runtime_error(v, "wait_any() list must contain only process objects.")
			return core.NIL_VALUE
		}
		append(&procs, cast(^Process_Data)core.as_userdata(item).data)
	}

	// Whether !ok means "every process finished" (nil, no error) or "a
	// genuine I/O problem" (an exception, raised from inside
	// process_wait_any_impl via runtime_error_named) is resolved by the
	// VM's own shared error-conversion tail (run.odin, checked once per
	// instruction) reading vm.error_msg after this call returns -- either
	// way, returning nil here is correct: a live result is always the
	// (index, value) tuple built below, so nil alone is unambiguous.
	index, result, ok := process_wait_any_impl(v, procs[:])
	if !ok {
		return core.NIL_VALUE
	}
	items: [dynamic]core.Value
	append(&items, core.make_int_value(index), result)
	t := core.make_list_object(items, true)
	vm.gc_track(v, &t.obj)
	return core.make_object_value(&t.obj, true)
}

// -----------------------------------------------------------------------
// Process object methods

@(private = "file")
process_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	p := cast(^Process_Data)data
	result: core.Value
	switch name {
	case "send":
		if arg_count != 1 {
			vm.runtime_error(v, "send() takes 1 argument.")
			return false
		}
		if !process_send(v, p, vm.peek(v, 0)) {
			return false
		}
		result = core.NIL_VALUE
	case "recv":
		if arg_count != 0 {
			vm.runtime_error(v, "recv() takes no arguments.")
			return false
		}
		val, rok := process_recv(v, p)
		if !rok {
			return false
		}
		result = val
	case "try_recv":
		if arg_count != 0 {
			vm.runtime_error(v, "try_recv() takes no arguments.")
			return false
		}
		had_data, val, rok := process_try_recv_impl(v, p)
		if !rok {
			return false
		}
		items: [dynamic]core.Value
		append(&items, core.make_bool_value(had_data), val)
		t := core.make_list_object(items, true)
		vm.gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "wait":
		child, has_child := p.child.?
		if !has_child {
			vm.runtime_error(v, "wait() is only available on a spawned process.")
			return false
		}
		state, werr := os.process_wait(child)
		if werr != nil {
			vm.runtime_error(v, "process wait failed: %v", werr)
			return false
		}
		result = core.make_int_value(state.exit_code)
	case "kill":
		child, has_child := p.child.?
		if !has_child {
			vm.runtime_error(v, "kill() is only available on a spawned process.")
			return false
		}
		if kerr := os.process_kill(child); kerr != nil {
			vm.runtime_error(v, "process kill failed: %v", kerr)
			return false
		}
		result = core.NIL_VALUE
	case "pid":
		child, has_child := p.child.?
		if !has_child {
			vm.runtime_error(v, "pid() is only available on a spawned process.")
			return false
		}
		result = core.make_int_value(child.pid)
	case:
		vm.runtime_error(v, "Undefined Process method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
