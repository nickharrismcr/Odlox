import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["replace.lox", "replace_ns.lox"])
def test_replace(script):
    lines = run_lox(script)
    assert lines[0] == "ABCdefg"
    assert lines[-1] == "nil"
