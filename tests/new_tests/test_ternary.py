from lox_helper import run_lox


def test_ternary():
    lines = run_lox("ternary.lox")
    assert lines[0] == "item"    # n==1 ? "item" : "items"
    assert lines[1] == "items"   # n==2 ? "item" : "items"
    assert lines[2] == "6"       # (a>b ? a : b) + 1
    assert lines[3] == "2"       # true  ? 2 : true  ? 4 : 5  (right-assoc)
    assert lines[4] == "4"       # false ? 2 : true  ? 4 : 5
    assert lines[5] == "5"       # false ? 2 : false ? 4 : 5
    assert lines[6] == "42"      # true ? 42 : bang()
    assert lines[7] == "0"       # bang() not called
    assert lines[8] == "99"      # false ? bang() : 99
    assert lines[9] == "0"       # bang() still not called
    assert lines[-1] == "nil"
