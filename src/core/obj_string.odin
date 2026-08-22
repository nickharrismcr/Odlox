#+feature global-context
package core

import "core:mem"
import "core:strings"

// String_Object: at or under STRING_INTERN_MAX_LEN bytes, always permanent
// and accessed through a canonical pointer (collectible is false, .chars
// never freed), so name-keyed maps can key directly on `^String_Object`
// with no separate intern-to-an-id step. Over that length, collectible is
// true: an ordinary GC'd object, not deduplicated, since interning
// unbounded runtime data (a socket/file read) forever leaked memory.
String_Object :: struct {
	using obj:   Obj,
	chars:       string, // canonical if !collectible, owned either way
	collectible: bool,   // false (the zero value) = permanent/interned, matching every pre-existing String_Object
}

// STRING_INTERN_MAX_LEN matches Lua's own short/long string split
// (LUAI_MAXSHORTLEN defaults to 40 bytes there too). See make_string_value.
STRING_INTERN_MAX_LEN :: 40

@(private = "file")
intern_table: map[string]^String_Object

// intern_allocator is captured once, at package init, not left to the
// ambient context.allocator active on whichever call first grows
// intern_table -- interned strings must outlive any single test task or
// VM run, so a later lookup must never dereference memory reclaimed when
// some earlier caller's allocator scope ended.
@(private = "file")
intern_allocator: mem.Allocator

@(init)
init_intern_table :: proc() {
	intern_allocator = context.allocator
	intern_table = make(map[string]^String_Object, allocator = intern_allocator)
}

// intern_string returns the canonical String_Object for s, allocating
// and registering one on first sight. No lock: the VM is single-threaded
// (see docs/ARCHITECTURE.md's Scope section -- threads are out of scope
// entirely).
intern_string :: proc(s: string) -> ^String_Object {
	if existing, ok := intern_table[s]; ok {
		return existing
	}
	owned := strings.clone(s, intern_allocator)
	obj := new(String_Object, intern_allocator)
	obj.obj.type = .String
	obj.chars = owned
	intern_table[owned] = obj
	return obj
}

// make_string_value interns s (permanent, deduplicated) when it's at or
// under STRING_INTERN_MAX_LEN bytes. Over that length, it builds an
// ordinary collectible String_Object instead, its own clone of s, not
// registered in intern_table. Not yet gc_track'd, since this proc runs
// below vm in the package graph with no ^VM in scope; a caller that wants
// a long result actually collected should call vm.make_tracked_string_value.
make_string_value :: proc(s: string, immutable := false) -> Value {
	if len(s) <= STRING_INTERN_MAX_LEN {
		return make_object_value(&intern_string(s).obj, immutable)
	}
	obj := new(String_Object)
	obj.obj.type = .String
	obj.chars = strings.clone(s)
	obj.collectible = true
	return make_object_value(&obj.obj, immutable)
}

// make_interned_string_value always interns s regardless of length,
// bypassing STRING_INTERN_MAX_LEN, for compiler-emitted identifiers and
// anywhere else a string is used as a map key rather than script data. A
// >40-byte property name compiled through plain make_string_value in two
// different chunks would otherwise get two non-interned objects instead
// of sharing one, breaking property/method dispatch for that name.
make_interned_string_value :: proc(s: string, immutable := false) -> Value {
	return make_object_value(&intern_string(s).obj, immutable)
}

string_get :: proc(s: ^String_Object) -> string {
	return s.chars
}

string_length :: proc(s: ^String_Object) -> int {
	return len(s.chars)
}

// string_replace replaces every occurrence of from with to in s.chars.
// from/to must both already be strings -- checked by the caller (see
// vm/call.odin's invoke_builtin_string).
string_replace :: proc(s: ^String_Object, from, to: ^String_Object) -> Value {
	result, was_allocation := strings.replace_all(s.chars, from.chars, to.chars)
	defer if was_allocation {
		delete(result)
	}
	return make_string_value(result)
}
