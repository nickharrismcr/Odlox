"""`const` on a local is a property of the binding, not of the value.

An earlier implementation marked the initialiser's constant-pool entry immutable
and let OP_SET_LOCAL check the value's Immut flag. That was wrong three ways,
each covered below.
"""
import pytest
from lox_helper import run_lox


def test_const_local_positive_cases():
    lines = run_lox("const_local.lox")
    assert lines[-1] == "nil"
    assert lines[:-1] == [
        "6",   # a const local must not poison a literal shared with a var local
        "6",   # a local seeded from an immutable value (const global) stays assignable
        "8",   # a const local is still readable
        "3",   # ordinary locals still support compound assignment
    ]


@pytest.mark.parametrize("script", [
    "const_local_assign.lox",    # const a = 5; a = 6
    "const_local_expr.lox",      # const a = 2 + 3; a = 99  (computed initialiser)
    "const_local_compound.lox",  # const a = 1; a += 2
])
def test_const_local_assignment_rejected(script):
    # Assignment to a const local is a compile-time error, whatever the initialiser
    # was and whichever assignment form is used.
    joined = "\n".join(run_lox(script))
    assert "Cannot assign to const 'a'." in joined, joined
