import pytest
from lox_helper import run_lox

_ALPHA = "abcdefghijkjmnopqrstuvwxyz"


@pytest.mark.parametrize("script", ["string_slice.lox", "string_slice_ns.lox"])
def test_string_slice(script):
    lines = run_lox(script)
    # a[:] → full string
    assert lines[0] == _ALPHA
    # individual chars
    assert lines[1:27] == list(_ALPHA)
    # prefix slices a[:i]
    for i in range(26):
        assert lines[27 + i] == _ALPHA[:i]
    # suffix slices a[i:]
    for i in range(26):
        assert lines[53 + i] == _ALPHA[i:]
    assert lines[-1] == "nil"
