package vm

import "../core"

// Mark-and-sweep collector -- design in docs/ARCHITECTURE.md's Garbage
// collector section. Marking/sweeping are incremental (GC_WORK_UNIT per
// maybe_collect_garbage call); only root scanning stays atomic.
// Function_Object/String_Object have no VM in scope at construction to
// register with, so they stay structurally permanent (still fully
// traced). write_barrier/write_barrier_value must run after any write
// the collector won't otherwise revisit this cycle.

INITIAL_GC_THRESHOLD :: 1 << 20 // 1 MiB, matches clox's starting nextGC
GC_HEAP_GROW_FACTOR :: 2

// GC_WORK_UNIT bounds how many gray-stack entries step_mark drains, or
// how many objects step_sweep walks, per maybe_collect_garbage call -- a
// fixed per-call budget. Not attempting a Go-style adaptive pacer in
// this pass; a fixed constant is the right first cut and can be tuned
// from real --trace-gc measurements afterward.
GC_WORK_UNIT :: 64

GC_Phase :: enum {
	Idle,
	Marking,
	Sweeping,
}

// gc_track registers obj as a newly-allocated collectible object on
// this VM's own intrusive list (mirroring clox's vm.objects). Does NOT
// check the allocation threshold itself -- see maybe_collect_garbage.
//
// "Allocate gray": whenever a cycle is active, a freshly tracked object
// is marked *and* queued for tracing (via mark_object), not just marked
// black outright. A brand-new object's own children are almost always
// already-marked-or-fresh values by construction (they came from the
// stack/globals/fields this same cycle already knows about, so tracing
// them again is a cheap no-op) -- but one real case needs it to be more
// than a no-op: module.odin's load_module splices a whole separate
// sub-VM's already-existing object subtree (arbitrary prior marked
// bits, from that sub-VM's own unrelated GC history) into this VM's
// object list via a single gc_track call on the Module_Object wrapping
// it. Marking that object black without queuing it would leave
// everything reachable only through it untraced for the rest of this
// cycle -- a use-after-free the moment sweep ran. Queuing it (what this
// proc does) instead lets the ordinary blacken_object(Module) pass
// discover and mark that whole subtree correctly, whenever it's
// eventually dequeued.
gc_track :: proc(vm: ^VM, obj: ^core.Obj) {
	obj.next = vm.objects
	vm.objects = obj
	vm.bytes_allocated += object_size(obj)
	if vm.gc_phase != .Idle {
		mark_object(vm, obj)
	}
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
			for sv in inst.slots {
				gc_adopt(vm, sv)
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

// maybe_collect_garbage advances the collector by one bounded step,
// starting a new cycle first if the allocation threshold has been
// crossed and none is already running. Called once per dispatch-loop
// iteration, *between* opcodes (see run.odin) -- deliberately never
// from inside a single opcode's own handler. Checking only at
// instruction boundaries means the value stack is *always* in a fully
// consistent, source-level-valid state -- exactly what root scanning is
// allowed to assume -- whenever a cycle can actually start. An opcode
// handler that pops several already-built values off the stack
// (transiently unreachable from anywhere) before combining them into a
// new object (e.g. Op_Create_List) never has a cycle start interleaved
// into that window, so no "pre-mark a just-linked object before
// anything else can reach it" trick is needed to protect it.
maybe_collect_garbage :: proc(vm: ^VM) {
	if vm.gc_phase == .Idle && vm.bytes_allocated > vm.next_gc {
		start_gc_cycle(vm)
	}
	#partial switch vm.gc_phase {
	case .Marking:
		step_mark(vm)
	case .Sweeping:
		step_sweep(vm)
	}
}

// start_gc_cycle begins a new cycle: fires .Gc_Start (still exactly
// once per cycle, so debug/trace.odin's Gc_Hook before/after byte
// accounting keeps working unmodified), scans roots -- atomically,
// unlike the marking/sweeping this hands off to; see this file's header
// comment for why that's safe -- then starts marking.
start_gc_cycle :: proc(vm: ^VM) {
	if vm.debug_hook != nil {
		vm.debug_hook(vm, .Gc_Start)
	}
	mark_roots(vm)
	vm.gc_phase = .Marking
}

// step_mark pops up to GC_WORK_UNIT entries off the gray stack, tracing
// each -- identical per-entry body to a non-incremental collector's
// full trace_references drain, just bounded. When the stack empties
// before the budget is spent, the whole reachable graph has been
// discovered: transition to sweeping.
step_mark :: proc(vm: ^VM) {
	for _ in 0 ..< GC_WORK_UNIT {
		if len(vm.gray_stack) == 0 {
			vm.gc_phase = .Sweeping
			vm.sweep_cursor = vm.objects
			vm.sweep_prev = nil
			return
		}
		n := len(vm.gray_stack) - 1
		obj := vm.gray_stack[n]
		resize(&vm.gray_stack, n)
		blacken_object(vm, obj)
	}
}

// step_sweep walks up to GC_WORK_UNIT objects from wherever the
// previous call left off (vm.sweep_cursor/vm.sweep_prev), freeing
// anything left unmarked and clearing the mark on survivors for next
// cycle -- identical per-object body to a non-incremental collector's
// full sweep. Anything requiring real external-resource teardown
// (currently just an open file) gets that call first (see
// docs/ARCHITECTURE.md's Object model section). When the cursor runs
// off the end of the list, the cycle is done: recompute next_gc
// (applying the 3b floor) and go Idle.
step_sweep :: proc(vm: ^VM) {
	for _ in 0 ..< GC_WORK_UNIT {
		obj := vm.sweep_cursor
		if obj == nil {
			vm.next_gc = max(vm.bytes_allocated * GC_HEAP_GROW_FACTOR, vm.gc_threshold_floor)
			vm.gc_phase = .Idle
			if vm.debug_hook != nil {
				vm.debug_hook(vm, .Gc_End)
			}
			return
		}
		next := obj.next
		if obj.marked {
			obj.marked = false
			vm.sweep_prev = obj
		} else {
			// object_size must be read before free_object runs -- several
			// cases (List/Dict/Instance/...) compute it from fields
			// (len(l.items), len(inst.fields), ...) that free_object's own
			// delete() calls invalidate.
			vm.bytes_allocated -= object_size(obj)
			free_object(obj)
			if vm.sweep_prev == nil {
				vm.objects = next
			} else {
				vm.sweep_prev.next = next
			}
		}
		vm.sweep_cursor = next
	}
}

// write_barrier/write_barrier_value are no-ops outside an active cycle.
// Call immediately after any write that installs obj/v into storage the
// collector won't automatically revisit for the rest of this cycle --
// see this file's header comment for the full site list.
//
// During Marking, this just enqueues obj like mark_object always does --
// a later step_mark call will trace it in due course. During Sweeping,
// no later step_mark call is coming (step_mark only ever runs during
// Marking), so deferring wouldn't work: obj's own not-yet-discovered
// children could be swept before anything traced them this cycle. Mark
// and fully trace eagerly instead, right here, rather than leaving
// anything on the gray stack for a phase that will never drain it.
// (Provably a no-op in practice for real bytecode: by the time Sweeping
// starts, everything the mutator can still reach is already marked, or
// freshly allocated -- see gc_track's "allocate gray" -- so obj should
// already be marked whenever write_barrier runs during Sweeping. Kept
// as a real, working path anyway rather than an assert, since that
// argument covers every mutation site audited for this plan, not a
// language-level guarantee.)
write_barrier :: proc(vm: ^VM, obj: ^core.Obj) {
	#partial switch vm.gc_phase {
	case .Marking:
		mark_object(vm, obj)
	case .Sweeping:
		if obj != nil && !obj.marked {
			mark_object(vm, obj)
			for len(vm.gray_stack) > 0 {
				n := len(vm.gray_stack) - 1
				o := vm.gray_stack[n]
				resize(&vm.gray_stack, n)
				blacken_object(vm, o)
			}
		}
	}
}

write_barrier_value :: proc(vm: ^VM, v: core.Value) {
	#partial switch v.type {
	case .Obj:
		write_barrier(vm, v.obj)
	}
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
	case .Obj:
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
		if c.owner_class != nil {
			mark_object(vm, &c.owner_class.obj)
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
		for sv in inst.slots {
			mark_value(vm, sv)
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
	// String, Native, File, Int_Iterator, String_Iterator: no
	// Object-typed children to trace.
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
		delete(inst.slots)
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
	case .Float_Array_3D:
		f3 := cast(^core.Float_Array_3D_Object)obj
		delete(f3.data)
		free(f3)
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
// proportional to how much churn is actually happening. Package-private
// (not file-private): the vm-package test suite asserts List/Dict's
// backing-storage accounting directly.
@(private)
object_size :: proc(obj: ^core.Obj) -> int {
	#partial switch obj.type {
	case .Closure:
		return size_of(core.Closure_Object)
	case .Upvalue:
		return size_of(core.Upvalue_Object)
	case .Instance:
		// slots is eager allocation at construction (sized from the
		// class's field-slot table), unlike the lazily-grown fields map --
		// a real per-instance cost worth tracking accurately for the
		// heap-growth heuristic, same reasoning as Float_Array below.
		inst := cast(^core.Instance_Object)obj
		return size_of(core.Instance_Object) + len(inst.slots) * size_of(core.Value)
	case .List:
		// Backing storage, not just the header -- same reasoning as
		// Float_Array below (a large list badly under-reports its real
		// footprint otherwise).
		l := cast(^core.List_Object)obj
		return size_of(core.List_Object) + len(l.items) * size_of(core.Value)
	case .Dict:
		d := cast(^core.Dict_Object)obj
		return size_of(core.Dict_Object) + len(d.items) * (size_of(^core.String_Object) + size_of(core.Value))
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
	case .Float_Array_3D:
		// Same reasoning as Float_Array above -- dominated by the data
		// slice, not the struct header.
		f3 := cast(^core.Float_Array_3D_Object)obj
		return size_of(core.Float_Array_3D_Object) + len(f3.data) * size_of(f64)
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
