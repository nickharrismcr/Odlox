package core

import "core:fmt"

// The heap object model: a closed set of heap-object kinds represented
// as a common base struct (Obj) embedded via `using` in every concrete
// object type, plus an enum tag (Object_Type) and a type switch on the
// concrete pointer at each dispatch site. See docs/ARCHITECTURE.md's
// Object model section for the full reasoning.

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

	// Each iterator kind gets its own tag rather than sharing one, so the
	// tag alone is sufficient at every dispatch site (switch on .type,
	// then cast) with no secondary type switch needed.
	List_Iterator,
	Int_Iterator,
	String_Iterator,

	Float_Array,
	Float_Array_3D,

	// Userdata: pluggable native-extension objects -- every native kind
	// (Sound/Music/Process/Regex Pattern+Match/PhysicsWorld/Window/Image/
	// Texture/Render_Texture/Shader/Camera/Batch/Batch_Instanced) is one
	// of these now. See obj_userdata.odin's doc comment and
	// natives/README.md.
	Userdata,
}

// Obj is embedded (via `using`) at the head of every concrete object
// struct. `next` is the intrusive singly-linked list pointer the
// garbage collector (see the vm package) walks to sweep every live
// allocation -- zero/unused until a VM's registry exists to link an
// object into it.
//
// `marked`/`next` living directly on this plain pointer means a nil
// `^Class_Object` stored in an `Obj`-shaped slot is just a nil pointer,
// full stop -- there is no "non-nil box wrapping a nil pointer" state
// for the mark phase to trip over.
Obj :: struct {
	type:   Object_Type,
	marked: bool,
	next:   ^Obj,
}

// object_to_string dispatches to each concrete type's own text
// representation via a switch-and-cast on obj.type. Kinds with nothing
// more interesting to print than a fixed label are handled directly
// here; the ones whose text depends on their own fields (functions,
// instances, ...) delegate to a proc living alongside that type's
// definition.
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
	case .Float_Array:
		f := cast(^Float_Array_Object)obj
		return fmt.aprintf("<FloatArray %dx%d>", f.width, f.height, allocator = allocator)
	case .Float_Array_3D:
		f3 := cast(^Float_Array_3D_Object)obj
		return fmt.aprintf("<FloatArray3D %dx%dx%d>", f3.width, f3.height, f3.depth, allocator = allocator)
	case .Userdata:
		u := cast(^Userdata_Object)obj
		if u.vtable.to_string != nil {
			return u.vtable.to_string(u.data, allocator)
		}
		return fmt.aprintf("<%s>", u.vtable.tag, allocator = allocator)
	}
	return "<unknown>"
}
