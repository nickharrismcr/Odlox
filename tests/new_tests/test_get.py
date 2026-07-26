import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["get.lox", "get_ns.lox"])
def test_dict_get(script):
    lines = run_lox(script)
    assert lines[0] == "1"
    assert lines[1] == "not found"
    assert lines[-1] == "nil"
