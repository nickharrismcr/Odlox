package core

import "core:fmt"

// The heap object model. Go's version of this (glox's src/core/object.go)
// uses an interface (`Object`) implemented by every heap type, discriminated
// at hot-loop call sites by a cached tag byte to avoid a vtable call. Odin
// has no structural interfaces, so this doesn't port as "find the Odin
// equivalent of an interface" -- it ports as the pattern Odin actually has
// for a closed set of heap-object kinds: a common base struct embedded via
// `using`, plus an enum tag and a type switch on the concrete pointer. See
// docs/ARCHITECTURE.md's Object model section for the full reasoning,
// including the correctness bug (Go's typed-nil-interface gotcha) this
// approach can't even express, let alone need a workaround for.

Object_Type :: enum u8 {
	String,
	Function,
	Closure,
	Upvalue,
	Native,
	List,
	Dict,
	Class,
	Instance,
	Bound_Method,
	Module,
	File,

	// glox gives all three of these one shared Object_Type ("Iterator")
	// and distinguishes the concrete Go type with a type switch instead
	// of the tag, because Go's blackenObject dispatches on the concrete
	// type anyway. Odin's dispatch convention is "the tag alone is
	// sufficient" (switch on .type, then cast) -- so each iterator kind
	// gets its own tag here rather than reusing one, a small deliberate
	// deviation to fit that convention.
	List_Iterator,
	Int_Iterator,
	String_Iterator,

	Vec2,
	Vec3,
	Vec4,

	Float_Array,

	Regex_Pattern,
	Regex_Match,

	Process,

	Physics_World,
	Window,
}

// Obj is embedded (via `using`) at the head of every concrete object
// struct, exactly mirroring how glox's Go structs embed GCHeader. `next`
// is the intrusive singly-linked list pointer the garbage collector (see
// the vm package, Phase 4) walks to sweep every live allocation --
// unused, and simply zero, for anything constructed here in Phase 2
// before a VM's registry exists to link it into.
//
// `marked`/`next` living directly on this plain pointer, rather than
// behind an interface method, is what removes a real class of bug glox
// has to work around: a nil `^Class_Object` stored in an `Obj`-shaped
// slot is just a nil pointer, full stop -- there is no "non-nil box
// wrapping a nil pointer" state for Odin's mark phase to trip over the
// way Go's `reflect.ValueOf(obj).IsNil()` check exists specifically to
// catch.
Obj :: struct {
	type:   Object_Type,
	marked: bool,
	next:   ^Obj,
}

// object_to_string dispatches to each concrete type's own text
// representation -- the Odin equivalent of glox's `Object.String()`
// interface method, just a switch-and-cast instead of a virtual call.
// Kinds with nothing more interesting to print than a fixed label are
// handled directly here; the ones whose text depends on their own
// fields (functions, instances, ...) delegate to a proc living
// alongside that type's definition.
object_to_string :: proc(obj: ^Obj, allocator := context.allocator) -> string {
	switch obj.type {
	case .String:
		s := cast(^String_Object)obj
		return fmt.aprintf("\"%s\"", s.chars, allocator = allocator)
	case .Function:
		return function_to_string(cast(^Function_Object)obj, allocator)
	case .Closure:
		c := cast(^Closure_Object)obj
		return function_to_string(c.function, allocator)
	case .Upvalue:
		return "<upvalue>"
	case .Native:
		return "<built-in>"
	case .List:
		return list_to_string(cast(^List_Object)obj, allocator)
	case .Dict:
		return dict_to_string(cast(^Dict_Object)obj, allocator)
	case .Class:
		c := cast(^Class_Object)obj
		return fmt.aprintf("<class %s>", c.name.chars, allocator = allocator)
	case .Instance:
		return instance_to_string(cast(^Instance_Object)obj, allocator)
	case .Bound_Method:
		bm := cast(^Bound_Method_Object)obj
		return function_to_string(bm.method.function, allocator)
	case .Module:
		m := cast(^Module_Object)obj
		return fmt.aprintf("<module %s>", m.name, allocator = allocator)
	case .File:
		return "<file>"
	case .List_Iterator, .String_Iterator:
		return "<iterator>"
	case .Int_Iterator:
		return "<range iterator>"
	case .Vec2, .Vec3, .Vec4:
		// Reached only via a bare Value.Obj that happens to be a vector
		// (e.g. through a container); the normal path is
		// value_to_string's own Vec2/3/4 cases, which know the tag
		// without needing to re-derive it from the object.
		return value_to_string(make_object_value(obj), allocator)
	case .Float_Array:
		f := cast(^Float_Array_Object)obj
		return fmt.aprintf("<FloatArray %dx%d>", f.width, f.height, allocator = allocator)
	case .Regex_Pattern:
		p := cast(^Regex_Pattern_Object)obj
		return fmt.aprintf("<Pattern %q>", p.source, allocator = allocator)
	case .Regex_Match:
		m := cast(^Regex_Match_Object)obj
		return fmt.aprintf("<Match span=%v>", m.pos[0], allocator = allocator)
	case .Process:
		return "<process>"
	case .Physics_World:
		pw := cast(^Physics_World_Object)obj
		return fmt.aprintf("<PhysicsWorld [%d bodies]>", physics_world_count(pw), allocator = allocator)
	case .Window:
		return "<window>"
	}
	return "<unknown>"
}
