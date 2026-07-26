import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["rgb_encode.lox", "rgb_encode_ns.lox"])
def test_rgb_encode_decode(script):
    lines = run_lox(script)
    assert lines[0] == "660510"
    assert lines[1] == "10"
    assert lines[2] == "20"
    assert lines[3] == "30"
    assert lines[-1] == "nil"
