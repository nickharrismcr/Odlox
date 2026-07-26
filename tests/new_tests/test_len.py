import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["len.lox", "len_ns.lox"])
def test_len(script):
    lines = run_lox(script)
    assert len(lines) == 21
    for i, line in enumerate(lines[:-1]):
        expected_s = "A" * (i + 1)
        assert line == f"{expected_s} {i + 1}"
    assert lines[-1] == "nil"
