package core

import "core:strings"

// String_Object: the one Object kind that's always permanent (see the
// intern table below) and always accessed through a canonical pointer.
//
// glox interns strings to an integer id (`map[string]int`) and separately
// caches that id on every Value (`InternedId`) so hot-path equality can
// compare small ints instead of hashing. Interning here instead maps
// straight to the canonical `^String_Object` -- so a Value naming a
// string already just *is* a pointer to the one true object for that
// content, and there is no separate id to keep in sync (see value.odin's
// values_equal: two strings are equal iff `s1.chars == s2.chars`, and
// that's true iff they're the same object, because interning guarantees
// it). This also gives every other name-keyed map in the object model
// (Class.methods/statics, Instance.fields, Dict.items, Environment.vars)
// a natural key type: `^String_Object` directly, instead of glox's
// separate "intern to an int first" step.
String_Object :: struct {
	using obj: Obj,
	chars:     string, // canonical, owned, immutable bytes
}

@(private = "file")
intern_table: map[string]^String_Object

// intern_string returns the canonical String_Object for s, allocating
// and registering one on first sight. No lock: the VM is single-threaded
// (see docs/ARCHITECTURE.md's Scope section -- threads are out of scope
// entirely), unlike glox's Go intern table which needs a sync.RWMutex to
// support the thread module.
intern_string :: proc(s: string) -> ^String_Object {
	if existing, ok := intern_table[s]; ok {
		return existing
	}
	owned := strings.clone(s)
	obj := new(String_Object)
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
