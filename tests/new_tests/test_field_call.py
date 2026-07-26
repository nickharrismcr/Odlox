import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["field_call.lox", "field_call_ns.lox"])
def test_field_call(script):
    lines = run_lox(script)
    assert lines[0] == "50"   # this.fn(x) — callable field invoked inside a method
    assert lines[1] == "40"   # r.fn(x)    — callable field invoked from outside
    assert lines[2] == "7"    # r.method() — ordinary method still dispatches
    assert lines[-1] == "nil"
