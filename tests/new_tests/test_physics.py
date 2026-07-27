import pytest
from lox_helper import run_lox

EXPECTED = [
    "builtin",
    "0",
    "1",
    "vec3(1, -9, 0)",
    "( vec3(5, 5, 5) , vec3(1, 2, 3) , vec3(0, 1, 0) , 45 )",
    "2",
    "3",
    "vec3(1, 0, 0)",
    "true",
    "4",
    "3",
    "true",
    "caught: invalid material id",
    "caught: index out of range or inactive",
    "caught: body is not a box",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_physics_world_basic(force_compile):
    lines = run_lox("physics_world_basic.lox", force_compile=force_compile)
    assert lines == EXPECTED
