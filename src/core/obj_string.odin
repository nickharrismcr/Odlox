#+feature global-context
package core

import "core:mem"
import "core:strings"

// String_Object: the one Object kind that's always permanent (see the
// intern table below) and always accessed through a canonical pointer.
//
// Interning maps a string's content straight to the canonical
// `^String_Object` -- so a Value naming a string already just *is* a
// pointer to the one true object for that content, and there is no
// separate id to keep in sync (see value.odin's values_equal: two
// strings are equal iff `s1.chars == s2.chars`, and that's true iff
// they're the same object, because interning guarantees it). This also
// gives every other name-keyed map in the object model
// (Class.methods/statics, Instance.fields, Dict.items, Environment.vars)
// a natural key type: `^String_Object` directly, with no separate
// intern-to-an-id step.
String_Object :: struct {
	using obj: Obj,
	chars:     string, // canonical, owned, immutable bytes
}

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

make_string_value :: proc(s: string, immutable := false) -> Value {
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
