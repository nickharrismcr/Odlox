package vm

import "../core"
import "core:os"
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

FRAME_LEN_SIZE :: 4

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
frame_read :: proc(v: ^VM, f: ^os.File) -> (result: core.Value, err: string, eof: bool, ok: bool) {
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
	gc_adopt(v, result)
	return result, "", false, true
}

@(private = "file")
pickle_resolve_class_for_process :: proc(name: string, ctx: rawptr) -> (^core.Class_Object, bool) {
	return resolve_class_by_name(native_vm(ctx), name)
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
try_frame_read :: proc(v: ^VM, f: ^os.File) -> (result: core.Value, err: string, eof: bool, has_data: bool, ok: bool) {
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
	// genuine message -- and since CreatePipe's anonymous pipes are
	// ordinary blocking pipes, a read attempted here either returns
	// already-buffered bytes immediately or discovers true EOF
	// immediately (the write end really is gone and the buffer really is
	// empty); it does not hang the round-robin poll this feeds into.
	result, err, eof, ok = frame_read(v, f)
	return result, err, eof, true, ok
}

process_send :: proc(v: ^VM, p: ^core.Process_Object, val: core.Value) -> bool {
	err, ok := frame_write(p.write_file, val)
	if !ok {
		runtime_error_named(v, "ProcessError", "%s", err)
		return false
	}
	return true
}

process_recv :: proc(v: ^VM, p: ^core.Process_Object) -> (core.Value, bool) {
	result, err, eof, ok := frame_read(v, p.read_file)
	if !ok {
		if eof {
			runtime_error_named(v, "ProcessError", "peer closed the connection")
		} else {
			runtime_error_named(v, "ProcessError", "%s", err)
		}
		return core.NIL_VALUE, false
	}
	return result, true
}

// process_try_recv returns (true, value, true) on a message, (true,
// nil, false) if nothing is ready yet, or (false, nil, false) plus a
// raised ProcessError on a genuine I/O problem (matching recv()'s own
// error behavior, just non-blocking when nothing is available yet).
process_try_recv :: proc(v: ^VM, p: ^core.Process_Object) -> (had_data: bool, result: core.Value, ok: bool) {
	res, err, eof, has_data, rok := try_frame_read(v, p.read_file)
	if !has_data {
		return false, core.NIL_VALUE, true
	}
	if !rok {
		if eof {
			p.done = true
			runtime_error_named(v, "ProcessError", "peer closed the connection")
		} else {
			runtime_error_named(v, "ProcessError", "%s", err)
		}
		return true, core.NIL_VALUE, false
	}
	return true, res, true
}

// process_wait_any polls every not-yet-finished process in round robin
// (a short sleep between full rounds once none are ready) until one has
// a message, returning its index into processes plus the value. A
// process that reports a clean EOF is dropped from consideration (not
// an error for the wait as a whole) rather than ending the loop; once
// every process has finished, returns ok=false with no error raised --
// nil is the unambiguous "the whole pool is done" signal, distinct from
// a raised ProcessError on a genuine I/O problem.
process_wait_any :: proc(v: ^VM, processes: []^core.Process_Object) -> (index: int, result: core.Value, ok: bool) {
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
					runtime_error_named(v, "ProcessError", "%s", err)
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

// -----------------------------------------------------------------------
// Process object methods

invoke_builtin_process :: proc(v: ^VM, p: ^core.Process_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "send":
		if arg_count != 1 {
			runtime_error(v, "send() takes 1 argument.")
			return false
		}
		if !process_send(v, p, peek(v, 0)) {
			return false
		}
		result = core.NIL_VALUE
	case "recv":
		if arg_count != 0 {
			runtime_error(v, "recv() takes no arguments.")
			return false
		}
		val, rok := process_recv(v, p)
		if !rok {
			return false
		}
		result = val
	case "try_recv":
		if arg_count != 0 {
			runtime_error(v, "try_recv() takes no arguments.")
			return false
		}
		had_data, val, rok := process_try_recv(v, p)
		if !rok {
			return false
		}
		items: [dynamic]core.Value
		append(&items, core.make_bool_value(had_data), val)
		t := core.make_list_object(items, true)
		gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "wait":
		child, has_child := p.child.?
		if !has_child {
			runtime_error(v, "wait() is only available on a spawned process.")
			return false
		}
		state, werr := os.process_wait(child)
		if werr != nil {
			runtime_error(v, "process wait failed: %v", werr)
			return false
		}
		result = core.make_int_value(state.exit_code)
	case "kill":
		child, has_child := p.child.?
		if !has_child {
			runtime_error(v, "kill() is only available on a spawned process.")
			return false
		}
		if kerr := os.process_kill(child); kerr != nil {
			runtime_error(v, "process kill failed: %v", kerr)
			return false
		}
		result = core.NIL_VALUE
	case "pid":
		child, has_child := p.child.?
		if !has_child {
			runtime_error(v, "pid() is only available on a spawned process.")
			return false
		}
		result = core.make_int_value(child.pid)
	case:
		runtime_error(v, "Undefined Process method '%s'.", name)
		return false
	}
	collapse_call(v, arg_count, result)
	return true
}
