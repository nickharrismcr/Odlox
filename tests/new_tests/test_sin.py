import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["sin.lox", "sin_ns.lox"])
def test_sin_line_count(script):
    lines = run_lox(script)
    # i from 0.0 to 20.0 step 0.1 → 200 iterations + nil
    assert len(lines) == 201
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["sin.lox", "sin_ns.lox"])
def test_sin_lines_contain_star(script):
    lines = run_lox(script)
    for line in lines[:-1]:
        assert line.endswith("*"), f"Expected line ending with '*', got: {line!r}"
        assert set(line[:-1]) <= {" "}, f"Expected only spaces before '*'"


@pytest.mark.parametrize("script", ["sin.lox", "sin_ns.lox"])
def test_sin_first_line(script):
    lines = run_lox(script)
    # At i=0, sin(0)=0 → pd=0, position = p - pd = 50 spaces then *
    assert lines[0] == " " * 50 + "*"
