package core

import "core:bufio"
import "core:os"
import "core:strings"

// File_Object: wraps an open OS file handle plus (lazily-initialized)
// line-buffered reader state for readln. Phase 4 left this at just the
// handle/closed/eof fields with reads/writes deferred to Phase 6 --
// this is that step.
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
// collector's sweep (Phase 4) calls this again as teardown. Mirrors
// glox's GCFreer pattern (see docs/ARCHITECTURE.md), just as a plain
// proc dispatched from a `switch obj.type` in sweep rather than an
// interface method.
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
// along with any preceding '\r'), same trim glox's own ReadLine does.
// ok is false only once EOF has already been reached with nothing left
// to return -- a final line with no trailing newline still comes back
// as ok=true (matching glox: a non-empty partial read on EOF is still
// a real line, only the *next* call after that reports EOF).
//
// Real bug, found via except_native_raise.lox (which reads itself line
// by line until EOFError and asserts the exact resulting line count):
// glox's own ReadLine (obj_file.go) has the same "err != nil but len(line)
// > 0 still returns a real line" fallthrough this doc comment describes,
// but its *shape* means that fallthrough is also reached when err != nil
// AND len(line) == 0 -- i.e. a file whose last byte is the final '\n',
// with nothing left after it -- since Go's `if len(line) > 0 { return
// ... }` only returns *early* in that inner branch; every other path,
// including "err != nil, line empty", falls through to the same final
// `return MakeStringObjectValue(line, false)` and comes back as a
// *successful* read of an empty string. Only the *following* call (with
// f.Eof now true) reports real EOF. This port's version returned
// ok=false immediately in that exact case instead, one read short of
// glox's own behaviour for any file that ends with a trailing newline
// (the overwhelmingly common case) -- confirmed against glox's actual
// binary on this exact fixture (27 successful reads, not 26).
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
// characters backslash-n) into a real newline byte -- matching glox's
// own Write exactly. This looked like a compensating step for
// something glox-scanner-specific at first glance, but it isn't: this
// language's string literals (both glox's and this port's -- see
// scanner.odin's scan_string, which only ever special-cases `$$` for
// interpolation) have no real backslash-escape mechanism at all, so
// `"hello\n"` in Lox source is literally the six characters h-e-l-l-
// o-backslash-n, not a newline. Writing text files with real newlines
// from Lox therefore depends on this one write-time unescape; skipping
// it (an earlier version of this proc did, on the wrong assumption
// that the scanner already handled `\n`) breaks every multi-line file
// write silently -- caught by an os.write/os.readln smoke test
// round-trip, not by reasoning about the scanner in isolation.
file_write :: proc(f: ^File_Object, s: string) {
	unescaped, was_allocation := strings.replace_all(s, `\n`, "\n")
	defer if was_allocation {
		delete(unescaped)
	}
	os.write_string(f.handle, unescaped)
}
