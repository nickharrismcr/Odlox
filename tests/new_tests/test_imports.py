import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["imports.lox", "imports_ns.lox"])
def test_imports(script):
    lines = run_lox(script)
    assert lines[0] == "mf1 hello"
    assert lines[1] == "mf2 hello"
    assert lines[2] == "nil"       # internal_var (unset)
    assert lines[3] == "2mv2"      # internal_var2
    assert lines[4] == "mv1"       # internal_var after assignment
    assert lines[5] == "setclass"  # a.get()
    assert lines[6] == "b=2mv2"
    assert lines[-1] == "nil"
