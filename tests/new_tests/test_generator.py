import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["generator.lox", "generator_ns.lox"])
def test_generator(script):
    lines = run_lox(script)
    assert lines[0] == "gen1 10"
    assert lines[1] == "gen2 3"
    assert lines[2] == "gen1 20"
    assert lines[3] == "gen2 6"
    assert lines[-2] == "gen2 30"
    assert lines[-1] == "nil"
    assert len(lines) == 21
