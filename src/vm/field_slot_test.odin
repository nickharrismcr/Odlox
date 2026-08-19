package vm

import "../core"
import "core:testing"

// End-to-end tests for compile-time-baked instance field slots
// (compiler/resolve.odin's discover_field_slots, core/chunk.odin's
// Get_Field_Slot/Set_Field_Slot doc comment) -- TODO.md's Phase 7 entry.
// Each test is run as its own process by bin/test_odin.sh (see TODO.md's
// Phase 0 entry / this repo's CLAUDE.md) -- these construct real VM
// instances the same way builtins_test.odin/vm_test.odin's own tests do.

@(private = "file")
run_field_slot_test :: proc(t: ^testing.T, source: string, var_name: string) -> core.Value {
	vm_instance := new_vm("test")
	status, _ := interpret(vm_instance, source)
	testing.expectf(t, status == .Ok, "expected %q to run without error, got %v: %s", source, status, vm_instance.error_msg)
	if status != .Ok {
		return core.NIL_VALUE
	}
	slot := core.env_slot_for_name(vm_instance.environment, var_name)
	testing.expectf(t, slot >= 0, "expected a global named %q", var_name)
	if slot < 0 || slot >= len(vm_instance.environment.globals) {
		return core.NIL_VALUE
	}
	return vm_instance.environment.globals[slot]
}

// test_field_slot_read_before_assignment_still_errors: within __init__
// itself, code preceding a field's own assignment line must still raise
// the same "Undefined property" error the map-based path always has --
// a naive zero-initialized slots array would instead silently return
// nil. See obj_instance.odin's make_instance_object (fills every slot
// with core.UNDEFINED_VALUE) and run.odin's Get_Field_Slot dispatch (the
// Undefined check).
@(test)
test_field_slot_read_before_assignment_still_errors :: proc(t: ^testing.T) {
	source := `
class Bad {
	__init__() {
		try {
			this.caught = "no"
			print this.never_set
			this.caught = "unreachable"
		} except RunTimeError as e {
			this.caught = "yes: " & e.msg
		}
	}
}
var b = Bad()
var result = b.caught
`
	v := run_field_slot_test(t, source, "result")
	testing.expectf(
		t,
		core.string_get(core.as_string(v)) == "yes: Undefined property 'never_set'.",
		"expected the read-before-assignment to raise the ordinary Undefined-property error, got %q",
		core.string_get(core.as_string(v)),
	)
}

// test_field_slot_external_access_works: a regression test for a real
// bug found while implementing this feature -- get_property/
// set_obj_field's Instance case originally checked only inst.fields,
// never inst.slots, which broke the most basic case of all: reading a
// slot-optimized field from outside the declaring class. Fixed via
// core.instance_get_field/instance_set_field (obj_instance.odin).
@(test)
test_field_slot_external_access_works :: proc(t: ^testing.T) {
	source := `
class Point {
	__init__(x) {
		this.x_val = x
	}
}
var p = Point(5)
var result = p.x_val
`
	v := run_field_slot_test(t, source, "result")
	testing.expect_value(t, core.as_int(v), 5)
}

// test_field_slot_external_write_then_fast_path_read: an external write
// to a slot-optimized field (core.instance_set_field's "not already in
// fields -> write to the slot" branch) must be visible to a later
// this-relative read through Get_Field_Slot's own fast path -- not just
// to another external/generic read.
@(test)
test_field_slot_external_write_then_fast_path_read :: proc(t: ^testing.T) {
	source := `
class Point {
	__init__(x) {
		this.x_val = x
	}
	get_x() {
		return this.x_val
	}
}
var p = Point(1)
p.x_val = 100
var result = p.get_x()
`
	v := run_field_slot_test(t, source, "result")
	testing.expect_value(t, core.as_int(v), 100)
}

// test_field_slot_inheritance_toggle_shape reproduces
// benchmarks/lox/method_call.lox's Toggle/NthToggle shape directly: a
// subclass whose own __init__ calls super.__init__(...) and then assigns its own
// additional fields. Exercises the owner_class guard (Closure_Object,
// vm/properties.odin's do_method) that makes each class's field-slot
// table safe to use independently of its superclass/subclasses -- see
// core/chunk.odin's Get_Field_Slot/Set_Field_Slot doc comment.
@(test)
test_field_slot_inheritance_toggle_shape :: proc(t: ^testing.T) {
	source := `
class Toggle {
	__init__(startState) {
		this.state = startState
	}
	value() {
		return this.state
	}
	activate() {
		this.state = !this.state
		return this
	}
}
class NthToggle < Toggle {
	__init__(startState, maxCounter) {
		super.__init__(startState)
		this.countMax = maxCounter
		this.count = 0
	}
	activate() {
		this.count = this.count + 1
		if (this.count >= this.countMax) {
			this.state = !this.state
			this.count = 0
		}
		return this
	}
}
var nt = NthToggle(true, 3)
nt.activate()
nt.activate()
nt.activate()
var result = nt.value()
`
	v := run_field_slot_test(t, source, "result")
	testing.expect_value(t, core.as_bool(v), false)
}

// test_field_slot_subclass_with_no_own_init: a subclass with no __init__ of
// its own at all reuses the superclass's compiled __init__ closure directly
// (do_inherit copies it into the subclass's own method table) -- its
// owner_class stays the superclass, so field-slot access inside it
// always takes the guard-miss fallback for a subclass instance, correct
// either way.
@(test)
test_field_slot_subclass_with_no_own_init :: proc(t: ^testing.T) {
	source := `
class Animal {
	__init__(name) {
		this.name = name
	}
	greet() {
		return "hi " & this.name
	}
}
class Cat < Animal {
}
var c = Cat("Tom")
var result = c.greet()
`
	v := run_field_slot_test(t, source, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "hi Tom")
}

// test_field_slot_callable_found_via_invoke is a regression test for
// vm/call.odin's invoke -- a callable stored in a slot-optimized field
// must still be found by the "a field holding a callable shadows a
// same-named method" check when called as this.field(...), even though
// that value lives in inst.slots, not inst.fields, for a normally-
// constructed instance. Fixed via core.instance_get_field.
@(test)
test_field_slot_callable_found_via_invoke :: proc(t: ^testing.T) {
	source := `
class Holder {
	__init__(fn) {
		this.cb = fn
	}
	run() {
		return this.cb()
	}
}
var h = Holder(func() { return "called" })
var result = h.run()
`
	v := run_field_slot_test(t, source, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "called")
}

// Regression test for exceptions.odin's format_uncaught_exception, which
// used to read inst.fields["msg"] directly -- a custom exception's
// __init__ (this.msg = m) is exactly the shape discover_field_slots
// slot-optimizes, so "msg" can live in inst.slots instead. Fixed via
// core.instance_get_field; checks the caught path (e.msg) as the
// reachable, testable half of the same lookup.
@(test)
test_field_slot_custom_exception_message_formats_correctly :: proc(t: ^testing.T) {
	source := `
class MyError < Exception {
	__init__(m) {
		this.msg = m
		this.name = "MyError"
	}
}
var result = "unset"
try {
	raise MyError("custom failure")
} except MyError as e {
	result = e.msg
}
`
	v := run_field_slot_test(t, source, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "custom failure")
}

// test_field_slot_conditional_field_falls_back_to_map: a field assigned
// only inside a conditional in __init__ never gets a slot at all (compiler/
// resolve.odin's discover_field_slots only looks at unconditional,
// top-level assignments) -- must still behave exactly like ordinary
// map-backed field access, including raising "Undefined property" when
// the condition never ran.
@(test)
test_field_slot_conditional_field_falls_back_to_map :: proc(t: ^testing.T) {
	source := `
class Cond {
	__init__(flag) {
		if (flag) {
			this.maybe = "yes"
		}
	}
}
var c1 = Cond(true)
var result1 = c1.maybe
var c2 = Cond(false)
var result2 = "not set"
try {
	print c2.maybe
	result2 = "no error!"
} except RunTimeError as e {
	result2 = "caught"
}
`
	v1 := run_field_slot_test(t, source, "result1")
	testing.expect_value(t, core.string_get(core.as_string(v1)), "yes")

	vm_instance := new_vm("test")
	status, _ := interpret(vm_instance, source)
	testing.expectf(t, status == .Ok, "expected the script to run without error, got %v: %s", status, vm_instance.error_msg)
	slot := core.env_slot_for_name(vm_instance.environment, "result2")
	testing.expect(t, slot >= 0)
	v2 := vm_instance.environment.globals[slot]
	testing.expect_value(t, core.string_get(core.as_string(v2)), "caught")
}
