import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["catch_runtime.lox", "catch_runtime_ns.lox"])
def test_catch_runtime_error(script):
    lines = run_lox(script)
    assert lines[0] == "c"
    assert lines[1] == "b"
    assert lines[2] == "a"
    assert lines[3].startswith("Caught ")
    assert "argument" in lines[3].lower() or "0" in lines[3]
    assert lines[-1] == "nil"
