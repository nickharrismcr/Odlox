import pytest
from lox_helper import run_lox

_MANDEL_CHARS = set(" .,-:;i+hHM$*#@")


@pytest.mark.parametrize("script", ["mandel.lox", "mandel_ns.lox"])
def test_mandel_line_count(script):
    lines = run_lox(script)
    # height=120 rows + nil
    assert len(lines) == 121
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["mandel.lox", "mandel_ns.lox"])
def test_mandel_valid_chars(script):
    lines = run_lox(script)
    for line in lines[:-1]:
        assert set(line) <= _MANDEL_CHARS, f"Unexpected chars in: {line!r}"


@pytest.mark.parametrize("script", ["mandel.lox", "mandel_ns.lox"])
def test_mandel_line_width(script):
    lines = run_lox(script)
    # width=180
    for line in lines[:-1]:
        assert len(line) == 180
