package core

import "core:os"

// File_Object: minimal shape for now -- just enough for the object model
// to be complete (Object_Type.File exists and needs a concrete struct).
// Buffered reads/writes and the actual `os.*` native functions that
// construct/use this are a Phase 6 concern; this deliberately stays
// this small until then.
File_Object :: struct {
	using obj: Obj,
	handle:    ^os.File,
	closed:    bool,
	eof:       bool,
}

make_file_object :: proc(handle: ^os.File) -> ^File_Object {
	o := new(File_Object)
	o.obj.type = .File
	o.handle = handle
	return o
}

// file_close is idempotent -- a script may already have closed the file
// itself before it becomes unreachable, at which point the garbage
// collector's sweep (Phase 4) calls this again as teardown. Mirrors
// glox's GCFreer pattern (see docs/ARCHITECTURE.md), just as a plain
// proc dispatched from a `switch obj.type` in sweep rather than an
// interface method.
file_close :: proc(f: ^File_Object) {
	if f.closed {
		return
	}
	os.close(f.handle)
	f.closed = true
}
