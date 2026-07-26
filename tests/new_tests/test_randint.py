import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["randint.lox", "randint_ns.lox"])
def test_randint_covers_all_chars(script):
    lines = run_lox(script)
    # Each char of "abcdefg" should appear (1000 random picks ensure coverage)
    for c in "abcdefg":
        assert c in lines
    assert lines[-2] == "done"
    assert lines[-1] == "nil"
