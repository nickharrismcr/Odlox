package vm

import "../core"

// Mark-and-sweep collector -- design documented in
// docs/ARCHITECTURE.md's Garbage collector section. Two refinements
// beyond that document's blueprint, explained where they matter below:
//
//  1. No mid-opcode collection trigger, so no "pre-mark on link" trick
//     is needed at all -- see maybe_collect_garbage.
//  2. Of the four kinds ARCHITECTURE.md's "no permanent-object
//     exemption" simplification named (classes, modules, functions,
//     strings), only two -- Class_Object and Module_Object -- actually
//     get full sweep participation here. Function_Object and
//     String_Object are constructed by the *compiler*/`core.intern_string`
//     respectively, neither of which has a VM in scope to register them
//     with (core/compiler sit below vm in the package graph -- see
//     docs/ARCHITECTURE.md's package-layout section) -- so those two
//     remain structurally permanent. Still fully traced either way, so
//     nothing reachable only through a Function's constant pool or a
//     String's own bytes (impossible -- strings have no Object
//     children) goes missing.

INITIAL_GC_THRESHOLD :: 1 << 20 // 1 MiB, matches clox's starting nextGC
GC_HEAP_GROW_FACTOR :: 2

// gc_track registers obj as a newly-allocated collectible object on
// this VM's own intrusive list (mirroring clox's vm.objects). Does NOT
// check the allocation threshold itself -- see maybe_collect_garbage.
gc_track :: proc(vm: ^VM, obj: ^core.Obj) {
	obj.next = vm.objects
	vm.objects = obj
	vm.bytes_allocated += object_size(obj)
}

// alloc_vec2/3/4: the pool-aware allocators for vec2/3/4 (see
// docs/plans/pool-allocator.md) -- check this VM's own per-type free
// list first (objects parked there by sweep() instead of actually
// freed) before falling back to a fresh core.make_vec{2,3,4}_object.
// Either path ends with gc_track, exactly as a bare
// core.make_vec2_object(...) + gc_track call site would -- every
// vec2/3/4 constructor site (arithmetic, the vec2()/vec3()/vec4()
// builtins, native query methods) should go through these instead of
// calling core.make_vec{2,3,4}_object/_value directly, or it won't
// benefit from pooling.
alloc_vec2 :: proc(vm: ^VM, x, y: f64) -> ^core.Vec2_Object {
	if vm.vec2_free != nil {
		o := cast(^core.Vec2_Object)vm.vec2_free
		vm.vec2_free = vm.vec2_free.next
		o.marked = false
		o.x, o.y = x, y
		gc_track(vm, &o.obj)
		return o
	}
	o := core.make_vec2_object(x, y)
	gc_track(vm, &o.obj)
	return o
}

alloc_vec3 :: proc(vm: ^VM, x, y, z: f64) -> ^core.Vec3_Object {
	if vm.vec3_free != nil {
		o := cast(^core.Vec3_Object)vm.vec3_free
		vm.vec3_free = vm.vec3_free.next
		o.marked = false
		o.x, o.y, o.z = x, y, z
		gc_track(vm, &o.obj)
		return o
	}
	o := core.make_vec3_object(x, y, z)
	gc_track(vm, &o.obj)
	return o
}

alloc_vec4 :: proc(vm: ^VM, x, y, z, w: f64) -> ^core.Vec4_Object {
	if vm.vec4_free != nil {
		o := cast(^core.Vec4_Object)vm.vec4_free
		vm.vec4_free = vm.vec4_free.next
		o.marked = false
		o.x, o.y, o.z, o.w = x, y, z, w
		gc_track(vm, &o.obj)
		return o
	}
	o := core.make_vec4_object(x, y, z, w)
	gc_track(vm, &o.obj)
	return o
}

// gc_adopt recursively gc_tracks every collectible object reachable from
// v -- used for a value tree built with no VM in scope to register
// objects with as they were allocated (core.pickle_decode, which can run
// from a background pipe-reader for the "process" module with no VM
// existing yet at all; see that proc's own doc comment). Most strings are
// never tracked at all (permanent/interned -- see obj_string.odin's
// STRING_INTERN_MAX_LEN), but a decoded string over that length is an
// ordinary collectible object like any other and needs the same
// gc_track call every other case here gets.
gc_adopt :: proc(vm: ^VM, v: core.Value) {
	#partial switch v.type {
	case .Vec2, .Vec3, .Vec4:
		gc_track(vm, v.obj)
	case .Obj:
		#partial switch v.obj_type {
		case .String:
			s := core.as_string(v)
			if s.collectible {
				gc_track(vm, &s.obj)
			}
		case .List:
			l := core.as_list(v)
			gc_track(vm, &l.obj)
			for item in l.items {
				gc_adopt(vm, item)
			}
		case .Dict:
			d := core.as_dict(v)
			gc_track(vm, &d.obj)
			for _, val in d.items {
				gc_adopt(vm, val)
			}
		case .Instance:
			inst := core.as_instance(v)
			gc_track(vm, &inst.obj)
			for _, val in inst.fields {
				gc_adopt(vm, val)
			}
		}
	}
}

// make_tracked_string_value is core.make_string_value plus gc_track when
// the result turned out collectible (over core.STRING_INTERN_MAX_LEN) --
// for vm/natives call sites that have a ^VM in scope and want a long
// result to actually be freed once unreachable, rather than just skip
// interning (core.make_string_value alone, called from anywhere without
// a ^VM, still returns a correct Value -- it just can't register it for
// collection itself).
make_tracked_string_value :: proc(vm: ^VM, s: string, immutable := false) -> core.Value {
	val := core.make_string_value(s, immutable)
	str_obj := core.as_string(val)
	if str_obj.collectible {
		gc_track(vm, &str_obj.obj)
	}
	return val
}

// maybe_collect_garbage runs a full cycle if the allocation threshold
// has been crossed. Called once per dispatch-loop iteration, *between*
// opcodes (see run.odin) -- deliberately never from inside a single
// opcode's own handler. Checking only at instruction boundaries means
// the value stack is *always* in a fully consistent, source-level-valid
// state -- exactly what root scanning is allowed to assume -- whenever
// a collection can actually run. An opcode handler that pops several
// already-built values off the stack (transiently unreachable from
// anywhere) before combining them into a new object (e.g.
// Op_Create_List) never has a collection interleaved into that window,
// so no "pre-mark a just-linked object before anything else can reach
// it" trick is needed to protect it.
maybe_collect_garbage :: proc(vm: ^VM) {
	if vm.bytes_allocated > vm.next_gc {
		collect_garbage(vm)
	}
}

collect_garbage :: proc(vm: ^VM) {
	mark_roots(vm)
	trace_references(vm)
	sweep(vm)
	vm.next_gc = vm.bytes_allocated * GC_HEAP_GROW_FACTOR
}

mark_roots :: proc(vm: ^VM) {
	for i in 0 ..< vm.stack_top {
		mark_value(vm, vm.stack[i])
	}
	for i in 0 ..< vm.frame_count {
		f := &vm.frames[i]
		if f.closure != nil {
			mark_object(vm, &f.closure.obj)
		}
	}
	for uv := vm.open_upvalues; uv != nil; uv = uv.next_open {
		mark_object(vm, &uv.obj)
	}
	mark_environment(vm, vm.environment)
	for _, v in vm.builtins {
		mark_value(vm, v)
	}
	for _, m in vm.builtin_modules {
		mark_object(vm, &m.obj)
	}
	// module_cache is process-wide (see module.odin), not per-VM -- every
	// VM's own mark phase walks the same shared cache, so a module stays
	// alive as long as *any* running VM might still call into it.
	for _, m in module_cache {
		mark_object(vm, &m.obj)
	}
}

mark_environment :: proc(vm: ^VM, env: ^core.Environment) {
	if env == nil {
		return
	}
	for v in env.globals {
		mark_value(vm, v)
	}
	for _, v in env.vars {
		mark_value(vm, v)
	}
}

mark_value :: proc(vm: ^VM, v: core.Value) {
	#partial switch v.type {
	case .Obj, .Vec2, .Vec3, .Vec4:
		mark_object(vm, v.obj)
	}
}

// mark_object marks obj and, on its first visit this cycle, queues it
// for blacken_object to trace its children later. A plain `obj == nil`
// check is sufficient here: `^core.Obj` is always either a real pointer
// or literally nil, never a non-nil box wrapping a nil concrete pointer
// (see docs/ARCHITECTURE.md's Object model section).
mark_object :: proc(vm: ^VM, obj: ^core.Obj) {
	if obj == nil || obj.marked {
		return
	}
	obj.marked = true
	append(&vm.gray_stack, obj)
}

trace_references :: proc(vm: ^VM) {
	for len(vm.gray_stack) > 0 {
		n := len(vm.gray_stack) - 1
		obj := vm.gray_stack[n]
		resize(&vm.gray_stack, n)
		blacken_object(vm, obj)
	}
}

// blacken_object traces obj's own children, marking each in turn. Every
// concrete Object_Type gets a case: Function/String are traced through
// (their children matter for correctness) even though neither is ever
// itself linked into vm.objects and so can never actually be swept --
// see this file's header comment.
blacken_object :: proc(vm: ^VM, obj: ^core.Obj) {
	#partial switch obj.type {
	case .Closure:
		c := cast(^core.Closure_Object)obj
		mark_object(vm, &c.function.obj)
		for uv in c.upvalues {
			if uv != nil {
				mark_object(vm, &uv.obj)
			}
		}
	case .Upvalue:
		uv := cast(^core.Upvalue_Object)obj
		mark_value(vm, uv.closed)
		if uv.location != nil {
			mark_value(vm, uv.location^)
		}
	case .Instance:
		inst := cast(^core.Instance_Object)obj
		mark_object(vm, &inst.class.obj)
		for _, v in inst.fields {
			mark_value(vm, v)
		}
	case .List:
		l := cast(^core.List_Object)obj
		for v in l.items {
			mark_value(vm, v)
		}
	case .Dict:
		d := cast(^core.Dict_Object)obj
		for _, v in d.items {
			mark_value(vm, v)
		}
	case .Bound_Method:
		bm := cast(^core.Bound_Method_Object)obj
		mark_value(vm, bm.receiver)
		mark_object(vm, &bm.method.obj)
	case .Class:
		c := cast(^core.Class_Object)obj
		if c.super != nil {
			mark_object(vm, &c.super.obj)
		}
		for _, v in c.methods {
			mark_value(vm, v)
		}
		for _, v in c.static_methods {
			mark_value(vm, v)
		}
		for _, v in c.statics {
			mark_value(vm, v)
		}
	case .Module:
		m := cast(^core.Module_Object)obj
		if m.environment != nil {
			mark_environment(vm, m.environment)
		}
	case .Function:
		f := cast(^core.Function_Object)obj
		for v in f.chunk.constants {
			mark_value(vm, v)
		}
	case .List_Iterator:
		it := cast(^core.List_Iterator_Object)obj
		mark_object(vm, &it.data.obj)
	case .Userdata:
		u := cast(^core.Userdata_Object)obj
		if u.vtable.mark != nil {
			u.vtable.mark(rawptr(vm), u.data)
		}
	// String, Native, File, Int_Iterator, String_Iterator, Vec2/3/4: no
	// Object-typed children to trace.
	}
}

// sweep walks this VM's own registry, freeing anything left unmarked
// and clearing the mark on survivors for next cycle. Anything requiring
// real external-resource teardown (currently just an open file) gets
// that call first (see docs/ARCHITECTURE.md's Object model section).
sweep :: proc(vm: ^VM) {
	prev: ^core.Obj
	obj := vm.objects
	for obj != nil {
		next := obj.next
		if obj.marked {
			obj.marked = false
			prev = obj
		} else {
			// object_size must be read before free_object runs -- several
			// cases (List/Dict/Instance/...) compute it from fields
			// (len(l.items), len(inst.fields), ...) that free_object's own
			// delete() calls invalidate.
			vm.bytes_allocated -= object_size(obj)
			// vec2/3/4 are parked on a per-type free list (see
			// docs/plans/pool-allocator.md) instead of actually freed --
			// alloc_vec2/3/4 check these before calling new(). obj.next is
			// safe to repurpose as the free-list link here: `next` (the
			// sweep loop's own continuation pointer) was already captured
			// above, before this reassignment.
			#partial switch obj.type {
			case .Vec2:
				obj.next = vm.vec2_free
				vm.vec2_free = obj
			case .Vec3:
				obj.next = vm.vec3_free
				vm.vec3_free = obj
			case .Vec4:
				obj.next = vm.vec4_free
				vm.vec4_free = obj
			case:
				free_object(obj)
			}
			if prev == nil {
				vm.objects = next
			} else {
				prev.next = next
			}
		}
		obj = next
	}
}

@(private = "file")
free_object :: proc(obj: ^core.Obj) {
	#partial switch obj.type {
	case .File:
		f := cast(^core.File_Object)obj
		core.file_close(f)
		free(f)
	case .Closure:
		c := cast(^core.Closure_Object)obj
		delete(c.upvalues)
		free(c)
	case .List:
		l := cast(^core.List_Object)obj
		delete(l.items)
		free(l)
	case .Dict:
		d := cast(^core.Dict_Object)obj
		delete(d.items)
		free(d)
	case .Instance:
		inst := cast(^core.Instance_Object)obj
		delete(inst.fields)
		free(inst)
	case .String:
		// Only ever reached for a collectible (>STRING_INTERN_MAX_LEN)
		// string -- an interned one is never gc_track'd, so sweep()
		// never walks it in the first place (see this file's header
		// comment).
		s := cast(^core.String_Object)obj
		delete(s.chars)
		free(s)
	case .Float_Array:
		f := cast(^core.Float_Array_Object)obj
		delete(f.data)
		free(f)
	case .Userdata:
		u := cast(^core.Userdata_Object)obj
		u.vtable.free(u.data) // tears down + frees u.data itself
		free(u)
	case:
		free(obj)
	}
}

// object_size is a rough per-object size estimate for the heap-growth
// heuristic -- exactness doesn't matter, only that it's roughly
// proportional to how much churn is actually happening.
@(private = "file")
object_size :: proc(obj: ^core.Obj) -> int {
	#partial switch obj.type {
	case .Closure:
		return size_of(core.Closure_Object)
	case .Upvalue:
		return size_of(core.Upvalue_Object)
	case .Instance:
		return size_of(core.Instance_Object)
	case .List:
		return size_of(core.List_Object)
	case .Dict:
		return size_of(core.Dict_Object)
	case .String:
		// As with Float_Array below, the backing bytes (not the struct
		// header) dominate a long string's real footprint.
		s := cast(^core.String_Object)obj
		return size_of(core.String_Object) + len(s.chars)
	case .Bound_Method:
		return size_of(core.Bound_Method_Object)
	case .Class:
		return size_of(core.Class_Object)
	case .Module:
		return size_of(core.Module_Object)
	case .Float_Array:
		// Unlike List/Dict (whose own backing storage this same estimate
		// also ignores, accepted there as "rough is fine"), a Float_Array's
		// footprint is dominated by its data slice, not the struct header --
		// a 512x512 array is 2MB, not 32 bytes -- so this one specifically
		// includes it, or the GC-growth heuristic would badly under-count
		// exactly the allocation-heavy case this object exists for.
		f := cast(^core.Float_Array_Object)obj
		return size_of(core.Float_Array_Object) + len(f.data) * size_of(f64)
	case .Userdata:
		u := cast(^core.Userdata_Object)obj
		size := size_of(core.Userdata_Object)
		if u.vtable.size != nil {
			size += u.vtable.size(u.data)
		}
		return size
	case:
		return 32
	}
}
