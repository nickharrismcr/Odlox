from lox_helper import run_lox


def test_unpack():
    lines = run_lox("unpack.lox")
    assert lines[:6] == ["1", "2", "3", "4", "5", "6"]
    assert lines[-1] == "nil"
