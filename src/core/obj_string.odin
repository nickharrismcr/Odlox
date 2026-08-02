#+feature global-context
package core

import "core:mem"
import "core:strings"

// String_Object: at or under STRING_INTERN_MAX_LEN bytes, always permanent
// (see the intern table below) and always accessed through a canonical
// pointer -- collectible is false, and .chars is never freed. Interning
// maps a string's content straight to the canonical `^String_Object` -- so
// a Value naming a short string already just *is* a pointer to the one
// true object for that content, and there is no separate id to keep in
// sync (see value.odin's objects_equal doc comment). This also gives every
// name-keyed map in the object model (Class.methods/statics,
// Instance.fields, Dict.items, Environment.vars) a natural key type:
// `^String_Object` directly, with no separate intern-to-an-id step --
// those maps require the canonical pointer regardless of length, so any
// call site building a map key from a Value that might be long calls
// intern_string itself (see vm/collections.odin's dict_key doc comment).
//
// Over STRING_INTERN_MAX_LEN bytes, collectible is true instead: an
// ordinary GC'd object (own allocation, not deduplicated, not in
// intern_table), swept by vm/gc.odin like any other heap value once
// unreachable -- interning bulk/unbounded runtime data (a socket read, a
// file read) forever was a real memory leak; see
// docs/plans/string-interning-split.md for the full writeup, including
// the two map-key/identifier correctness follow-ons this required.
// Equality (`==`) needs no special case either way: Odin's native
// `string` `==` (see make_string_value's two branches) is a full content
// comparison, not a pointer compare.
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

// intern_allocator is captured once, at package init (before `odin test`'s
// runner exists and hands every test task its own short-lived, recycled
// scratch allocator) -- not left to the ambient context.allocator active
// on whichever call first grows intern_table. Interned strings are meant
// to outlive any single test task or VM run (see String_Object's own doc
// comment), so a later lookup must never dereference an entry whose
// backing memory was reclaimed when some earlier caller's allocator scope
// ended.
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
// under STRING_INTERN_MAX_LEN bytes -- unchanged behavior for every
// existing caller, since identifiers/literals/ordinary computed strings
// are almost always short. Over that length, it builds an ordinary
// collectible String_Object instead: not registered in intern_table, own
// clone of s so the caller's source buffer can be freed/reused
// immediately after this returns. Not yet gc_track'd -- this proc runs
// from core/compiler, below vm in the package graph, with no ^VM in
// scope (same reason intern_string never could either); a caller with a
// ^VM that wants a long result to actually be collected should call
// vm.make_tracked_string_value instead (vm/gc.odin) -- see that proc's
// own doc comment.
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

// make_interned_string_value always interns s (permanent, deduplicated,
// canonical pointer) regardless of length, bypassing STRING_INTERN_MAX_LEN
// entirely -- for compiler-emitted identifiers (property/method/super/
// class/module/global names, in compiler/expr.odin and compiler/stmt.odin)
// and anywhere else a string is used as a map key rather than as string
// data a script manipulates. Class.methods/statics, Instance.fields, and
// Dict.items (via vm/collections.odin's dict_key/vm/call.odin's dict
// get/remove) all require the canonical pointer no matter how long the
// name is -- a >40-byte property name compiled through plain
// make_string_value in two different chunks would silently get two
// different, non-interned objects instead of sharing one, breaking
// property/method dispatch for that name.
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
