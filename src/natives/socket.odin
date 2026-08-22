package natives

import "../core"
import "../vm"
import "core:net"

// socket: raw TCP sockets for IPC with any process, as an alternative to
// process's pickled-value pipe. Deliberately low-level -- send/recv move
// raw bytes as Lox strings, no pickling. core:net has no Unix-domain-socket
// support, so "local IPC" here means TCP over loopback (127.0.0.1). There
// is no threading model in this VM, so accept()/recv() block the script by
// default and try_accept()/try_recv() are the non-blocking variants, built
// on core:net's Would_Block error rather than a manual poll.

Socket_Data :: struct {
	sock:      net.TCP_Socket,
	listening: bool,
	closed:    bool, // guards against a double net.close from an explicit .close() plus a GC sweep
}

@(private = "file")
socket_vtable := core.Userdata_Vtable {
	tag    = "socket",
	free   = socket_data_free,
	invoke = socket_invoke,
}

@(private = "file")
socket_data_free :: proc(data: rawptr) {
	s := cast(^Socket_Data)data
	if !s.closed {
		net.close(s.sock)
		s.closed = true
	}
	free(s)
}

@(private = "file")
make_socket_value :: proc(v: ^vm.VM, sock: net.TCP_Socket, listening: bool) -> core.Value {
	data := new(Socket_Data)
	data.sock = sock
	data.listening = listening
	o := core.make_userdata_object(&socket_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj)
}

@(private)
register_socket :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "socket")
	vm.define_builtin(v, "socket", "connect", socket_connect)
	vm.define_builtin(v, "socket", "listen", socket_listen)
}

// socket_connect: socket.connect(host, port) -> Socket. Blocking TCP
// dial; host is resolved (hostname or IP literal) the way core:net's own
// dial_tcp_from_hostname_with_port_override does.
@(private = "file")
socket_connect :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "connect() expects 2 arguments (host, port).")
		return core.NIL_VALUE
	}
	host_val := v.stack[arg_stack_ptr]
	port_val := v.stack[arg_stack_ptr + 1]
	if !core.is_string(host_val) {
		vm.runtime_error(v, "connect() first argument must be a string (host).")
		return core.NIL_VALUE
	}
	if !core.is_number(port_val) {
		vm.runtime_error(v, "connect() second argument must be a number (port).")
		return core.NIL_VALUE
	}
	host := core.string_get(core.as_string(host_val))
	port := core.as_int(port_val)

	sock, err := net.dial_tcp(host, port)
	if err != nil {
		vm.runtime_error_named(v, "SocketError", "connect() failed: %v", err)
		return core.NIL_VALUE
	}
	return make_socket_value(v, sock, false)
}

// socket_listen: socket.listen(host, port, backlog=1000) -> Socket. Binds
// and starts listening in one call, matching core:net's own listen_tcp.
// host must be an IP literal ("127.0.0.1", "0.0.0.0", ...) -- no DNS
// resolution, unlike connect().
@(private = "file")
socket_listen :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 && argc != 3 {
		vm.runtime_error(v, "listen() expects 2 or 3 arguments (host, port, backlog=1000).")
		return core.NIL_VALUE
	}
	host_val := v.stack[arg_stack_ptr]
	port_val := v.stack[arg_stack_ptr + 1]
	if !core.is_string(host_val) {
		vm.runtime_error(v, "listen() first argument must be a string (host).")
		return core.NIL_VALUE
	}
	if !core.is_number(port_val) {
		vm.runtime_error(v, "listen() second argument must be a number (port).")
		return core.NIL_VALUE
	}
	backlog := 1000
	if argc == 3 {
		backlog_val := v.stack[arg_stack_ptr + 2]
		if !core.is_number(backlog_val) {
			vm.runtime_error(v, "listen() third argument must be a number (backlog).")
			return core.NIL_VALUE
		}
		backlog = core.as_int(backlog_val)
	}
	host := core.string_get(core.as_string(host_val))
	port := core.as_int(port_val)

	addr := net.parse_address(host)
	if addr == nil {
		vm.runtime_error_named(v, "SocketError", "listen() invalid host address '%s'.", host)
		return core.NIL_VALUE
	}

	sock, err := net.listen_tcp(net.Endpoint{address = addr, port = port}, backlog)
	if err != nil {
		vm.runtime_error_named(v, "SocketError", "listen() failed: %v", err)
		return core.NIL_VALUE
	}
	return make_socket_value(v, sock, true)
}

// -----------------------------------------------------------------------
// Socket object methods

@(private = "file")
socket_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	s := cast(^Socket_Data)data
	result: core.Value
	switch name {
	case "accept":
		if arg_count != 0 {
			vm.runtime_error(v, "accept() takes no arguments.")
			return false
		}
		if !s.listening {
			vm.runtime_error(v, "accept() is only available on a listening socket.")
			return false
		}
		client, _, aerr := net.accept_tcp(s.sock)
		if aerr != nil {
			vm.runtime_error_named(v, "SocketError", "accept() failed: %v", aerr)
			return false
		}
		result = make_socket_value(v, client, false)
	case "try_accept":
		if arg_count != 0 {
			vm.runtime_error(v, "try_accept() takes no arguments.")
			return false
		}
		if !s.listening {
			vm.runtime_error(v, "try_accept() is only available on a listening socket.")
			return false
		}
		had_conn, conn_val, aok := socket_try_accept_impl(v, s)
		if !aok {
			return false
		}
		items: [dynamic]core.Value
		append(&items, core.make_bool_value(had_conn), conn_val)
		t := core.make_list_object(items, true)
		vm.gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "send":
		if arg_count != 1 {
			vm.runtime_error(v, "send() takes 1 argument.")
			return false
		}
		arg := vm.peek(v, 0)
		if !core.is_string(arg) {
			vm.runtime_error(v, "send() argument must be a string.")
			return false
		}
		buf := core.string_get(core.as_string(arg))
		n, serr := net.send_tcp(s.sock, transmute([]u8)buf)
		if serr != nil {
			vm.runtime_error_named(v, "SocketError", "send() failed: %v", serr)
			return false
		}
		result = core.make_int_value(n)
	case "recv":
		if arg_count != 1 {
			vm.runtime_error(v, "recv() takes 1 argument (max bytes).")
			return false
		}
		n_val := vm.peek(v, 0)
		if !core.is_number(n_val) {
			vm.runtime_error(v, "recv() argument must be a number.")
			return false
		}
		n := core.as_int(n_val)
		if n <= 0 {
			vm.runtime_error(v, "recv() argument must be a positive number.")
			return false
		}
		str_val, rok := socket_recv_impl(v, s, n)
		if !rok {
			return false
		}
		result = str_val
	case "try_recv":
		if arg_count != 1 {
			vm.runtime_error(v, "try_recv() takes 1 argument (max bytes).")
			return false
		}
		n_val := vm.peek(v, 0)
		if !core.is_number(n_val) {
			vm.runtime_error(v, "try_recv() argument must be a number.")
			return false
		}
		n := core.as_int(n_val)
		if n <= 0 {
			vm.runtime_error(v, "try_recv() argument must be a positive number.")
			return false
		}
		had_data, str_val, rok := socket_try_recv_impl(v, s, n)
		if !rok {
			return false
		}
		items: [dynamic]core.Value
		append(&items, core.make_bool_value(had_data), str_val)
		t := core.make_list_object(items, true)
		vm.gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "close":
		if arg_count != 0 {
			vm.runtime_error(v, "close() takes no arguments.")
			return false
		}
		if !s.closed {
			net.close(s.sock)
			s.closed = true
		}
		result = core.NIL_VALUE
	case "local_endpoint":
		if arg_count != 0 {
			vm.runtime_error(v, "local_endpoint() takes no arguments.")
			return false
		}
		ep, eerr := net.bound_endpoint(net.Any_Socket(s.sock))
		if eerr != nil {
			vm.runtime_error_named(v, "SocketError", "local_endpoint() failed: %v", eerr)
			return false
		}
		result = core.make_string_value(net.endpoint_to_string(ep))
	case "peer_endpoint":
		if arg_count != 0 {
			vm.runtime_error(v, "peer_endpoint() takes no arguments.")
			return false
		}
		ep, eerr := net.peer_endpoint(net.Any_Socket(s.sock))
		if eerr != nil {
			vm.runtime_error_named(v, "SocketError", "peer_endpoint() failed: %v", eerr)
			return false
		}
		result = core.make_string_value(net.endpoint_to_string(ep))
	case:
		vm.runtime_error(v, "Undefined Socket method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}

// socket_recv_impl returns an already-safe core.Value, not a raw Odin
// string: vm.make_tracked_string_value copies the bytes into their own
// allocation before buf is freed below -- string(buf[:nread]) is a
// zero-copy view into buf, and returning that view directly left the
// caller holding a dangling pointer once buf's memory was reused. The
// tracked (not plain core.make_string_value) path matters here since
// recv() is an unbounded-external-data source.
@(private = "file")
socket_recv_impl :: proc(v: ^vm.VM, s: ^Socket_Data, n: int) -> (result: core.Value, ok: bool) {
	buf := make([]u8, n)
	defer delete(buf)
	nread, rerr := net.recv_tcp(s.sock, buf)
	if rerr != nil {
		vm.runtime_error_named(v, "SocketError", "recv() failed: %v", rerr)
		return core.NIL_VALUE, false
	}
	return vm.make_tracked_string_value(v, string(buf[:nread])), true
}

// socket_try_recv_impl: non-blocking recv. Toggles the socket non-blocking
// for the duration of the call and back to blocking afterward, so a
// script may freely mix recv() and try_recv() on the same Socket. Returns
// an already-safe core.Value -- see socket_recv_impl's doc comment.
@(private = "file")
socket_try_recv_impl :: proc(v: ^vm.VM, s: ^Socket_Data, n: int) -> (had_data: bool, result: core.Value, ok: bool) {
	net.set_blocking(s.sock, false)
	defer net.set_blocking(s.sock, true)
	buf := make([]u8, n)
	defer delete(buf)
	nread, rerr := net.recv_tcp(s.sock, buf)
	if rerr == .Would_Block {
		return false, core.make_string_value(""), true
	}
	if rerr != nil {
		vm.runtime_error_named(v, "SocketError", "try_recv() failed: %v", rerr)
		return false, core.NIL_VALUE, false
	}
	return true, vm.make_tracked_string_value(v, string(buf[:nread])), true
}

@(private = "file")
socket_try_accept_impl :: proc(v: ^vm.VM, s: ^Socket_Data) -> (had_conn: bool, result: core.Value, ok: bool) {
	net.set_blocking(s.sock, false)
	defer net.set_blocking(s.sock, true)
	client, _, aerr := net.accept_tcp(s.sock)
	if aerr == .Would_Block {
		return false, core.NIL_VALUE, true
	}
	if aerr != nil {
		vm.runtime_error_named(v, "SocketError", "try_accept() failed: %v", aerr)
		return false, core.NIL_VALUE, false
	}
	return true, make_socket_value(v, client, false), true
}
