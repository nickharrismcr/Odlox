package core

import "core:bufio"
import "core:os"
import "core:strings"

// File_Object: wraps an open OS file handle plus (lazily-initialized)
// line-buffered reader state for readln.
File_Object :: struct {
	using obj:    Obj,
	handle:       ^os.File,
	closed:       bool,
	eof:          bool,
	reader:       bufio.Reader,
	reader_ready: bool, // reader is a value type; bufio.reader_init must run exactly once
}

make_file_object :: proc(handle: ^os.File) -> ^File_Object {
	o := new(File_Object)
	o.obj.type = .File
	o.handle = handle
	return o
}

// file_close is idempotent -- a script may already have closed the file
// itself before it becomes unreachable, at which point the garbage
// collector's sweep calls this again as teardown (see
// docs/ARCHITECTURE.md's GCFreer equivalent section).
file_close :: proc(f: ^File_Object) {
	if f.closed {
		return
	}
	if f.reader_ready {
		bufio.reader_destroy(&f.reader)
	}
	os.close(f.handle)
	f.closed = true
}

// file_read_line reads up to and including the next '\n' (stripped,
// along with any preceding '\r'). ok is false only once EOF has already
// been reached with nothing left to return -- a final line with no
// trailing newline still comes back as ok=true: a non-empty partial read
// on EOF is still a real line, and even a file whose last byte is the
// final '\n' (with nothing left after it) reports ok=false immediately
// rather than one extra successful read of an empty string. Only the
// *next* call after a real line reports EOF.
file_read_line :: proc(f: ^File_Object) -> (line: string, ok: bool) {
	if f.eof {
		return "", false
	}
	if !f.reader_ready {
		bufio.reader_init(&f.reader, os.to_reader(f.handle))
		f.reader_ready = true
	}
	raw, err := bufio.reader_read_string(&f.reader, '\n')
	if err != nil {
		f.eof = true
	}
	return strings.trim_right(raw, "\r\n"), true
}

// file_write writes s to f, first un-escaping a literal `\n` (the two
// characters backslash-n) into a real newline byte. This language's
// string literals have no real backslash-escape mechanism at all (see
// scanner.odin's scan_string, which only ever special-cases `$$` for
// interpolation), so `"hello\n"` in Lox source is literally the six
// characters h-e-l-l-o-backslash-n, not a newline. Writing text files
// with real newlines from Lox therefore depends on this one write-time
// unescape.
file_write :: proc(f: ^File_Object, s: string) {
	unescaped, was_allocation := strings.replace_all(s, `\n`, "\n")
	defer if was_allocation {
		delete(unescaped)
	}
	os.write_string(f.handle, unescaped)
}
