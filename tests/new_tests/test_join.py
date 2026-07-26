import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["join.lox", "join_ns.lox"])
def test_join(script):
    lines = run_lox(script)
    assert len(lines) == 2
    joined = lines[0]
    parts = joined.split("||")
    assert parts == [str(i) for i in range(100)]
    assert lines[-1] == "nil"
