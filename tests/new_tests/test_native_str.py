import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["native_str.lox", "native_str_ns.lox"])
def test_native_str(script):
    lines = run_lox(script)
    assert lines[0] == "true"
    assert lines[1] == "2"
    assert lines[2] == "2"
    assert lines[-1] == "nil"
