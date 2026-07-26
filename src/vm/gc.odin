package vm

import "../core"
import "core:os"
import "core:text/regex"

// Mark-and-sweep collector -- the design blueprint is
// docs/ARCHITECTURE.md's Garbage collector section, itself carried over
// from glox's own experimental Go collector (src/vm/gc.go there, whose
// doc comment says outright it exists to serve as this port's design
// blueprint). Two real refinements from that plan, discovered while
// actually wiring this up (both explained where they matter below):
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
//     remain structurally permanent, the same *outcome* glox's original
//     exemption had, just arrived at for a different reason (a real
//     constraint, not a deliberate choice) than glox's "small and
//     long-lived, not worth it" rationale. Still fully traced either
//     way, so nothing reachable only through a Function's constant pool
//     or a String's own bytes (impossible -- strings have no Object
//     children) goes missing.

INITIAL_GC_THRESHOLD :: 1 << 20 // 1 MiB, matches clox/glox's starting nextGC
GC_HEAP_GROW_FACTOR :: 2

// gc_track registers obj as a newly-allocated collectible object on
// this VM's own intrusive list (mirroring clox's vm.objects). Does NOT
// check the allocation threshold itself -- see maybe_collect_garbage.
gc_track :: proc(vm: ^VM, obj: ^core.Obj) {
	obj.next = vm.objects
	vm.objects = obj
	vm.bytes_allocated += object_size(obj)
}

// gc_adopt recursively gc_tracks every collectible object reachable from
// v -- used for a value tree built with no VM in scope to register
// objects with as they were allocated (core.pickle_decode, which can run
// from a background pipe-reader for the "process" module with no VM
// existing yet at all; see that proc's own doc comment). Strings are
// never tracked at all (structurally permanent -- see this file's header
// comment), so this only ever recurses into List/Dict/Instance/Vec2/3/4.
gc_adopt :: proc(vm: ^VM, v: core.Value) {
	#partial switch v.type {
	case .Vec2, .Vec3, .Vec4:
		gc_track(vm, v.obj)
	case .Obj:
		#partial switch v.obj_type {
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

// maybe_collect_garbage runs a full cycle if the allocation threshold
// has been crossed. Called once per dispatch-loop iteration, *between*
// opcodes (see run.odin) -- deliberately never from inside a single
// opcode's own handler. This is what removes the need for glox's
// "pre-mark a just-linked object so the very collection it triggered
// can't sweep it before anything else can reach it" trick: that trick
// exists in glox because a Go collection can, in principle, fire at any
// allocation, including ones in the middle of an opcode handler that's
// popped several already-built values off the stack (transiently
// unreachable from anywhere) before combining them into a new object
// (e.g. Op_Create_List). Checking only at instruction boundaries means
// the value stack is *always* in a fully consistent, source-level-valid
// state -- exactly what root scanning is allowed to assume -- whenever
// a collection can actually run.
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
	for _, m in vm.module_cache {
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
// check is sufficient here -- unlike glox's Go version, there is no
// typed-nil-interface gotcha to guard against (see
// docs/ARCHITECTURE.md's Object model section): `^core.Obj` is always
// either a real pointer or literally nil, never a non-nil box wrapping
// a nil concrete pointer.
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
	// String, Native, File, Int_Iterator, String_Iterator, Vec2/3/4: no
	// Object-typed children to trace.
	}
}

// sweep walks this VM's own registry, freeing anything left unmarked
// and clearing the mark on survivors for next cycle. Anything requiring
// real external-resource teardown (currently just an open file) gets
// that call first -- the switch-based equivalent of glox's GCFreer
// interface check (see docs/ARCHITECTURE.md's Object model section).
sweep :: proc(vm: ^VM) {
	prev: ^core.Obj
	obj := vm.objects
	for obj != nil {
		next := obj.next
		if obj.marked {
			obj.marked = false
			prev = obj
		} else {
			free_object(obj)
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
	case .Float_Array:
		f := cast(^core.Float_Array_Object)obj
		delete(f.data)
		free(f)
	case .Regex_Pattern:
		p := cast(^core.Regex_Pattern_Object)obj
		delete(p.group_names)
		regex.destroy_regex(p.regex)
		free(p)
	case .Regex_Match:
		m := cast(^core.Regex_Match_Object)obj
		delete(m.pos)
		delete(m.groups)
		free(m)
	case .Process:
		// Closes this end of both pipes -- the child process handle
		// itself (if any) is released by process_wait/process_kill
		// instead (Odin's own os.process_wait doc comment: "Use the
		// process_wait() procedure (optionally prefaced with a
		// process_kill()) to close and free the process handle"), which
		// a script calling .wait()/.kill() already does; a Process
		// object dropped without either leaves that OS-level handle
		// resource unreleased (the child process itself is unaffected
		// either way -- it runs and exits independently of whether its
		// parent-side handle was ever explicitly closed).
		p := cast(^core.Process_Object)obj
		os.close(p.read_file)
		os.close(p.write_file)
		free(p)
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
	case .Regex_Pattern:
		return size_of(core.Regex_Pattern_Object)
	case .Regex_Match:
		return size_of(core.Regex_Match_Object)
	case .Process:
		return size_of(core.Process_Object)
	case:
		return 32
	}
}
