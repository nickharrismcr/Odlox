import pytest
from lox_helper import run_lox

EXPECTED = [
    "bob",
    "30",
    "a",
    "b",
    "true",
    "caught missing file error",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_json_load(force_compile):
    lines = run_lox("json_load.lox", force_compile=force_compile)
    assert lines == EXPECTED
