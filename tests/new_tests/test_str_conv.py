import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["str_conv.lox", "str_conv_ns.lox"])
def test_str_conv(script):
    lines = run_lox(script)
    assert lines[0] == "123"
    assert lines[1] == "1234.25"
    assert "Uncaught exception" in lines[2]
    assert "int" in lines[2].lower()
