import pytest
from lox_helper import run_lox

EXPECTED = [
    "builtin",
    "2",
    "true",
    "true",
    "true",
    "true",
    "vec2",
    "float",
    "0",
    "vec2(0, -1)",
    "1",
    "caught: index out of range or inactive",
    "caught: add_circle() body_type must be 0 (static), 1 (kinematic), or 2 (dynamic).",
    "caught: index out of range or inactive",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_box2d_basic(force_compile):
    lines = run_lox("box2d_basic.lox", force_compile=force_compile)
    assert lines == EXPECTED
