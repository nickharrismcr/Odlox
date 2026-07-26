package core

import "core:os"

// Process_Object represents one end of a pipe-backed channel carrying
// length-prefixed pickled values (pickle_encode/pickle_decode, framed
// with a 4-byte little-endian length prefix -- see
// vm/process.odin's frame_write/frame_read). Doubles as both "the
// process I spawned" (child != nil, exposes wait/kill/pid) and "the
// channel back to whoever spawned me" (child == nil, constructed
// wrapping this process's own stdin/stdout) -- ported from glox's
// ProcessObject (src/builtin/obj_builtin_process.go), minus its
// background reader goroutine (this port has no general-purpose
// threading model exposed anywhere -- see docs/ARCHITECTURE.md's Scope
// section -- so recv/try_recv/wait_any read the pipe directly instead;
// see vm/process.odin for exactly how try_recv/wait_any poll for
// available data without a dedicated reader thread).
Process_Object :: struct {
	using obj:  Obj,
	read_file:  ^os.File,
	write_file: ^os.File,
	child:      Maybe(os.Process), // nil for the parent-channel variant
	done:       bool, // latched once a clean EOF has been observed on read_file
}

make_process_object :: proc(read_file, write_file: ^os.File, child: Maybe(os.Process)) -> ^Process_Object {
	o := new(Process_Object)
	o.obj.type = .Process
	o.read_file = read_file
	o.write_file = write_file
	o.child = child
	return o
}
