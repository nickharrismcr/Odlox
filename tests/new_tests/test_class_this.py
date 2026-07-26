import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["class_this.lox", "class_this_ns.lox"])
def test_class_this(script):
    lines = run_lox(script)
    assert lines[0] == "111"
    assert lines[-1] == "nil"
