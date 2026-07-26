import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["wordcount.lox", "wordcount_ns.lox"])
def test_wordcount(script):
    lines = run_lox(script)
    assert lines[0] == "292"   # unique words in Lorem Ipsum passage
    assert lines[1] == "23"    # count of "the"
    assert lines[-1] == "nil"
