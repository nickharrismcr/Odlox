from lox_helper import run_lox


def test_list_iter():
    lines = run_lox("list_iter.lox")
    assert lines[:-1] == ["1", "2", "3"]
    assert lines[-1] == "nil"
