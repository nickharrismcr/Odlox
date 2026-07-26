from lox_helper import run_lox


def test_import_as():
    lines = run_lox("import_as.lox")
    assert lines[0] == "[ 5 , 4 , 3 , 2 , 1 ]"
    assert lines[-1] == "nil"
