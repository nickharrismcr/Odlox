from lox_helper import run_lox


def test_field_slot_basic():
    """Compile-time-baked instance field slots (compiler/resolve.odin's
    discover_field_slots, core/chunk.odin's Get_Field_Slot/Set_Field_Slot
    doc comment). Covers the basic fast path, external field access (a
    real bug found and fixed while building this feature), the
    read-before-assignment-inside-init edge case, a conditionally-
    assigned field's map fallback, inheritance (super.init(), a subclass
    with no init of its own, and the exact Toggle/NthToggle shape from
    benchmarks/lox/method_call.lox), a closure stored in a slot-optimized
    field called via this.field()/other.field(), and a custom exception
    class whose init sets msg/name at the top level."""
    lines = run_lox("field_slot_basic.lox")
    assert lines == [
        "7",  # p.sum(): 3 + 4
        "9",  # p.sum() after move(1, 1): 4 + 5
        "4",  # p.x_val (external read)
        "100",  # p.x_val after external write
        "105",  # p.sum() after the external write: 100 + 5
        "caught: Undefined property 'never_set'.",
        "99",  # b.never_set, assigned right after the caught read
        "yes",  # c1.maybe (flag=true)
        "caught: Undefined property 'maybe'.",  # c2.maybe (flag=false, never assigned)
        "Dog: Rex (Labrador)",
        "Rex",  # d.name (external read of an Animal-slotted, Dog-fallback field)
        "Labrador",  # d.breed
        "Tom says meow",  # cat.meow() -- Cat has no init of its own
        "Animal: Tom",  # cat.describe() -- inherited, unoverridden
        "true",  # nt.value() before any activate()
        "false",  # nt.value() after 3 activate() calls (wraps at countMax=3)
        "called!",  # h.run() -- this.cb() finds the closure via invoke's field-shadow check
        "called!",  # h.cb() -- same, external invoke
        "exception caught: custom failure",  # e.msg on a custom exception with slot-optimized fields
        "field_slot_basic complete",
        "nil",  # the script's own top-level expression result
    ]
