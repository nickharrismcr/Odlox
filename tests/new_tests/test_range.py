import pytest
from lox_helper import run_lox

EXPECTED = [
    "10", "9", "8", "7", "6", "5", "4", "3", "2", "1",
    "10", "8", "6", "4", "2",
    "0", "1", "2", "3", "4",
    "0", "2", "4", "6", "8",
    "0",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_range_reverse(force_compile):
    lines = run_lox("range_reverse.lox", force_compile=force_compile)
    assert lines == EXPECTED
