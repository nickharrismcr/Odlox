from lox_helper import run_lox


def test_pickle_field_slots():
    """Pickle round-trip for a slot-optimized class -- regression test
    for a real data-loss bug found while building compile-time-baked
    field slots (core/pickle.odin's pickle_encode_value originally only
    enumerated inst.fields, silently dropping fields living in
    inst.slots). Also exercises the decode-side fix: a decoded instance's
    slot-eligible fields are moved into inst.slots so a later mutation
    through the field-slot fast path stays consistent with external
    reads instead of leaving a stale copy in inst.fields."""
    lines = run_lox("pickle_field_slots.lox")
    assert lines == [
        "3",  # p2.x_val after round-trip (would be missing/wrong if the encode-side bug were present)
        "4",  # p2.y_val after round-trip
        "7",  # p2.sum() -- this-relative field-slot read of a decoded instance
        "104",  # p2.sum() after p2.x_val = 100 -- external write, then fast-path read
        "100",  # p2.x_val -- external read of the same mutation
        "pickle_field_slots complete",
        "nil",  # the script's own top-level expression result
    ]
