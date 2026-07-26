import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["except_native_raise.lox", "except_native_raise_ns.lox"])
def test_except_native_raise(script):
    lines = run_lox(script)
    # this is the assertion that fails before the fix: a native raise from
    # inside os.readln (called one frame down, in readOneLine) corrupted
    # `marker`, the last local declared immediately before the enclosing try.
    assert lines[0] == "sentinel"
    assert lines[1] == "list"
    assert lines[2] == "27"
    assert lines[3] == "import os;"
    assert lines[4] == "done"
    assert lines[-1] == "nil"
