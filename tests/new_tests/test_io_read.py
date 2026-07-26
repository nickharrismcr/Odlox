import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["io_read.lox", "io_read_ns.lox"])
def test_io_read(script):
    lines = run_lox(script)
    assert lines[0] == "reading"
    # numbered source lines (io_read.lox has 17 lines)
    assert lines[1].startswith("1 ")
    assert lines[1].endswith("import os")
    # EOFError is caught
    assert "in EOFError handler" in lines
    # file is closed
    assert "file closed" in lines
