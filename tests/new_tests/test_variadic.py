from lox_helper import run_lox


def test_variadic():
    lines = run_lox("variadic.lox")
    assert lines[0] == "0"                     # sum()
    assert lines[1] == "6"                     # sum(1, 2, 3)
    assert lines[2] == "5"                     # sum(5)
    assert lines[3] == "x/0"                   # lead("x")
    assert lines[4] == "x/2"                   # lead("x", 1, 2)
    assert lines[5] == "1,10,0"                # mix(1)          -> b default, empty rest
    assert lines[6] == "1,2,0"                 # mix(1, 2)       -> empty rest
    assert lines[7] == "1,2,2"                 # mix(1, 2, 3, 4) -> rest = [3, 4]
    assert lines[8] == '[ "b" , "c" , "z" ]'   # tags("a","b","c"), rest.append("z")
    assert lines[-1] == "nil"
