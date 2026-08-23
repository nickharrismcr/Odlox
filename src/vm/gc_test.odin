package vm

import "../core"
import "core:testing"

// Tests for gc.odin's resumable GC_Phase state machine and write barrier
// (correct, resumable building blocks that maybe_collect_garbage now
// drains to completion in one call rather than spreading across many --
// see gc.odin's header comment) plus 3a's object_size accounting.
// vm_test.odin's end-to-end style (compile+run real source) doesn't give
// fine enough control over exactly when a cycle starts/how many bounded
// steps it takes, so these drive the gc.odin procs directly instead.

// -----------------------------------------------------------------------
// 3a: object_size backing-storage accounting

@(test)
test_object_size_counts_list_backing_storage :: proc(t: ^testing.T) {
	items := make([dynamic]core.Value, 10)
	l := core.make_list_object(items)
	defer free(l)
	defer delete(items)

	got := object_size(&l.obj)
	want := size_of(core.List_Object) + 10 * size_of(core.Value)
	testing.expect_value(t, got, want)
}

@(test)
test_object_size_counts_dict_backing_storage :: proc(t: ^testing.T) {
	items := make(map[^core.String_Object]core.Value, 4)
	items[core.intern_string("a")] = core.make_int_value(1)
	items[core.intern_string("b")] = core.make_int_value(2)
	d := core.make_dict_object(items)
	defer free(d)
	defer delete(items)

	got := object_size(&d.obj)
	want := size_of(core.Dict_Object) + len(items) * (size_of(^core.String_Object) + size_of(core.Value))
	testing.expect_value(t, got, want)
}

// -----------------------------------------------------------------------
// Resumable cycle: bounded per-call work, spans multiple calls

// test_marking_spans_multiple_step_mark_calls proves step_mark actually
// bounds its work. A root list holding more than GC_WORK_UNIT sub-list
// objects means blackening the root alone (one step_mark call's first
// dequeue) enqueues far more gray work than a single call's budget
// allows draining.
@(test)
test_marking_spans_multiple_step_mark_calls :: proc(t: ^testing.T) {
	vm := new_vm("test")

	child_count := GC_WORK_UNIT * 2
	items := make([dynamic]core.Value, child_count)
	for i in 0 ..< child_count {
		child := core.make_list_object(make([dynamic]core.Value))
		gc_track(vm, &child.obj)
		items[i] = core.make_object_value(&child.obj)
	}
	root := core.make_list_object(items)
	gc_track(vm, &root.obj)
	push(vm, core.make_object_value(&root.obj))

	start_gc_cycle(vm)
	testing.expect_value(t, vm.gc_phase, GC_Phase.Marking)

	step_mark(vm)
	testing.expectf(
		t, vm.gc_phase == .Marking,
		"expected marking to still be in progress after one bounded step_mark call with %d reachable objects (GC_WORK_UNIT=%d), got phase %v",
		child_count + 1, GC_WORK_UNIT, vm.gc_phase,
	)

	// Drain the rest -- bounded number of iterations so a real bug
	// (never terminating) fails the test instead of hanging it.
	calls := 0
	for vm.gc_phase == .Marking && calls < child_count {
		step_mark(vm)
		calls += 1
	}
	testing.expect_value(t, vm.gc_phase, GC_Phase.Sweeping)
}

// test_gc_cycle_reclaims_dead_and_keeps_live drives a whole cycle
// (start_gc_cycle, then step_mark/step_sweep repeatedly until Idle) and
// checks the end result: an object reachable only via the stack
// survives, one with no root at all gets swept.
@(test)
test_gc_cycle_reclaims_dead_and_keeps_live :: proc(t: ^testing.T) {
	vm := new_vm("test")

	dead := core.make_list_object(make([dynamic]core.Value))
	gc_track(vm, &dead.obj)

	live := core.make_list_object(make([dynamic]core.Value))
	gc_track(vm, &live.obj)
	push(vm, core.make_object_value(&live.obj))

	start_gc_cycle(vm)
	calls := 0
	for vm.gc_phase != .Idle && calls < 10_000 {
		#partial switch vm.gc_phase {
		case .Marking:
			step_mark(vm)
		case .Sweeping:
			step_sweep(vm)
		}
		calls += 1
	}
	testing.expect_value(t, vm.gc_phase, GC_Phase.Idle)

	found_live, found_dead := false, false
	for o := vm.objects; o != nil; o = o.next {
		if o == &live.obj {
			found_live = true
		}
		if o == &dead.obj {
			found_dead = true
		}
	}
	testing.expect(t, found_live, "object reachable from the stack should survive a gc cycle")
	testing.expect(t, !found_dead, "object with no root should be swept by a gc cycle")
}

// -----------------------------------------------------------------------
// Write barrier regression

// The core correctness case the write barrier exists for: mutating an
// already-blackened object's field to point at a still-white object must
// protect that referent for the rest of the current cycle. Mirrors
// call.odin's "append" method dispatch (list_append then
// write_barrier_value) rather than calling write_barrier directly.
@(test)
test_write_barrier_protects_object_installed_into_blackened_container :: proc(t: ^testing.T) {
	vm := new_vm("test")

	// orphan predates the cycle and starts genuinely unreachable from any
	// root -- exactly the shape of object a missed write barrier would
	// lose.
	orphan := core.make_list_object(make([dynamic]core.Value))
	gc_track(vm, &orphan.obj)
	testing.expect(t, !orphan.marked, "orphan should start unmarked")

	container := core.make_list_object(make([dynamic]core.Value))
	gc_track(vm, &container.obj)
	push(vm, core.make_object_value(&container.obj))

	start_gc_cycle(vm)
	for vm.gc_phase == .Marking {
		step_mark(vm)
	}
	testing.expect_value(t, vm.gc_phase, GC_Phase.Sweeping)
	testing.expect(t, container.marked, "container should already be blackened (dequeued) by now")
	testing.expect(t, !orphan.marked, "orphan should still be unmarked -- nothing reaches it yet")

	// Simulate `container.append(orphan)` running mid-cycle, after
	// container has already been fully traced.
	orphan_val := core.make_object_value(&orphan.obj)
	core.list_append(container, orphan_val)
	write_barrier_value(vm, orphan_val)
	testing.expect(t, orphan.marked, "write_barrier_value should have marked orphan immediately")

	calls := 0
	for vm.gc_phase != .Idle && calls < 10_000 {
		step_sweep(vm)
		calls += 1
	}
	testing.expect_value(t, vm.gc_phase, GC_Phase.Idle)

	found_orphan := false
	for o := vm.objects; o != nil; o = o.next {
		if o == &orphan.obj {
			found_orphan = true
		}
	}
	testing.expect(t, found_orphan, "orphan, installed into an already-blackened container mid-cycle, must survive sweep")
}
