import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["dict.lox", "dict_ns.lox"])
def test_dict(script):
    lines = run_lox(script)
    assert lines[0] == "1"
    assert lines[1] == "2"
    # 20 key-value pairs "0 : 0" .. "19 : 19"
    assert lines[2] == "0 : 0"
    assert lines[21] == "19 : 19"
    assert lines[22] == "20"   # len(c.keys())
    assert lines[23] == "1"   # len(e.keys())
    assert lines[24] == "2"   # len(e["a"].keys())
    assert lines[25] == "c"
    assert lines[26] == '[ 1 , 2 , 3 , Dict({ "e":"f" }) ]'
    assert lines[27] == "1"
    assert lines[28] == "f"
    assert lines[-1] == "nil"
