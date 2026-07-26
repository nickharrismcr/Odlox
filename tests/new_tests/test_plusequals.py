from lox_helper import run_lox


def test_plusequals():
    lines = run_lox("plusequals.lox")
    assert lines[0] == "2"   # a=1, a+=1 → 2
    assert lines[1] == "3"   # b=2, b+=1 → 3
    assert lines[2] == "4"   # c=vec2(3,2), c.x+=1 → 4
    assert lines[3] == "3"   # d=12, *=2 → 24, /=3 → 8, %=5 → 3
    assert lines[4] == "60"  # e=20, *=3 → 60
    assert lines[5] == "15"  # e/=4 → 15
    assert lines[6] == "1"   # e%=7 → 1
    assert lines[7] == "12"  # f=vec2(3,2), f.x*=4 → 12
    assert lines[-1] == "nil"
