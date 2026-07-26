from lox_helper import run_lox


def test_colour_utils():
    lines = run_lox("colour_utils.lox")
    assert lines[0] == "Testing colour_utils with RGB parameters - functions return vec4s:"
    assert "Faded red (255,0,0,0.5): vec4(127, 0, 0, 255)" in lines
    assert "Bright red (255,0,0,1.5): vec4(255, 0, 0, 255)" in lines
    assert "Dim red (255,0,0,0.5): vec4(127, 0, 0, 255)" in lines
    assert "Red to blue 50% (255,0,0 -> 0,0,255): vec4(127, 0, 127, 255)" in lines
    assert "HSV Red (0,1,1): vec4(255, 0, 0, 255)" in lines
    assert "HSV Green (120,1,1): vec4(0, 255, 0, 255)" in lines
    assert "HSV Blue (240,1,1): vec4(0, 0, 255, 255)" in lines
    assert lines[-1] == "nil"
