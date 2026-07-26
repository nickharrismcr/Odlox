import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["str_interp.lox", "str_interp_ns.lox"])
def test_str_interp(script):
    lines = run_lox(script)
    assert lines[0] == "total: 3 (42.5%)"
    assert lines[1] == "cost: $3"           # $$ escapes to a literal $
    assert lines[2] == "b=true n=nil"        # bool / nil stringified
    assert lines[3] == "12"                  # adjacent interpolations
    assert lines[4] == "3"                   # leading interpolation
    assert lines[5] == "3-3"                 # single-quoted interpolation
    assert lines[6] == "nested y"            # nested string literal in expr
    assert lines[7] == "sum=7"               # embedded arithmetic (1 + 3*2)
    assert lines[8] == "point Pt(1,2)"       # class instance via toString
