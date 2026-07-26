package vm

import "../core"

// Upvalue capture/closing -- standard clox design, unchanged by the
// port. capture_upvalue finds-or-creates the Upvalue_Object for a given
// stack slot, threading it into vm.open_upvalues (kept sorted
// descending by slot) so a later capture of the *same* slot from a
// sibling closure reuses the identical Upvalue_Object rather than
// creating a second one that would silently stop sharing mutations.

capture_upvalue :: proc(vm: ^VM, slot: int) -> ^core.Upvalue_Object {
	prev: ^core.Upvalue_Object
	uv := vm.open_upvalues
	for uv != nil && uv.slot > slot {
		prev = uv
		uv = uv.next_open
	}
	if uv != nil && uv.slot == slot {
		return uv
	}

	created := core.make_upvalue_object(&vm.stack[slot], slot)
	gc_track(vm, &created.obj)
	created.next_open = uv
	if prev == nil {
		vm.open_upvalues = created
	} else {
		prev.next_open = created
	}
	return created
}

// close_upvalues detaches every open upvalue at stack slot >= last,
// snapshotting the live value into the upvalue's own Closed field and
// repointing Location at it -- called on scope exit (Op_Close_Upvalue)
// and function return, closing everything at/above the exiting frame's
// base slot.
close_upvalues :: proc(vm: ^VM, last: int) {
	for vm.open_upvalues != nil && vm.open_upvalues.slot >= last {
		uv := vm.open_upvalues
		uv.closed = uv.location^
		uv.location = &uv.closed
		vm.open_upvalues = uv.next_open
	}
}
