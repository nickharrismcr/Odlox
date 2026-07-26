import pytest
from lox_helper import run_lox

EXPECTED = [
    "true",
    "true",
    "false",
    "42",
    "-123456789",
    "3.5",
    "hello world",
    '[ 1 , 2 , 3 , "four" ]',
    '( 1 , 2 , "three" )',
    "1",
    "[ 2 , 3 ]",
    "4",
    "1.5",
    "2.5",
    "1",
    "2",
    "3",
    "1",
    "2",
    "3",
    "4",
    "1",
    '( "a" , "b" )',
    "3",
    "3",
    "4",
    "7",
    "MyError",
    "boom",
    "boom",
    "caught cyclic instance",
    "caught unknown class",
    "caught unsupported",
    "caught cyclic",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_pickle_basic(force_compile):
    lines = run_lox("pickle_basic.lox", force_compile=force_compile)
    assert lines == EXPECTED
