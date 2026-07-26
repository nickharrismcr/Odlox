import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["int_vs_float.lox", "int_vs_float_ns.lox"])
def test_int_vs_float(script):
    lines = run_lox(script)
    # test(1, 1.0): equal, not less, not greater
    assert lines[0] == "true"
    assert lines[1] == "false"
    assert lines[2] == "false"
    # test(1.0, 1): same
    assert lines[3] == "true"
    assert lines[4] == "false"
    assert lines[5] == "false"
    # test(2, 1.0): not equal, not less, greater
    assert lines[6] == "false"
    assert lines[7] == "false"
    assert lines[8] == "true"
    # test(1.0, 2): not equal, less, not greater
    assert lines[9] == "false"
    assert lines[10] == "true"
    assert lines[11] == "false"
    # string indexing
    assert lines[12] == "e"   # "test string"[1]
    assert lines[13] == "e"   # [int(1.0)]
    # print 1; print float(1); print 1.0
    assert lines[14] == "1"
    assert lines[15] == "1"
    assert lines[16] == "1"
    assert lines[-1] == "nil"
