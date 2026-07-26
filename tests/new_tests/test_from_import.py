from lox_helper import run_lox


def test_from_import_selective():
    lines = run_lox("from_import1.lox")
    assert lines[0] == "3"
    assert lines[1] == "5"
    assert lines[-1] == "nil"


def test_from_import_star():
    lines = run_lox("from_import2.lox")
    assert lines[0] == "3"
    assert lines[1] == "5"
    assert lines[-1] == "nil"
