import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["nested_func.lox", "nested_func_ns.lox"])
def test_nested_func(script):
    lines = run_lox(script)
    # test(1.0, 2.0): prints a+b=3, then innertest(1,2,i) = i*(1+2) = i*3 for i in 0..9
    assert lines[0] == "3"
    assert lines[1:11] == [str(i * 3) for i in range(10)]
    assert lines[-1] == "nil"
