import pytest
from lox_helper import run_lox

EXPECTED = [
    "true",
    "bob@example.com",
    "bob",
    "example",
    "9",
    "24",
    "true",
    "true",
    "true",
    "true",
    "alice",
    "wonderland",
    "alice",
    "wonderland",
    '( "alice" , "wonderland" )',
    "a# b# c#",
    "a# b# c333",
    "2",
    '[ "a" , "b" , "c" , "d" ]',
    '[ "a" , "b,c,  d" ]',
    '[ "1" , "22" , "333" ]',
    '[ ( "a" , "1" ) , ( "b" , "22" ) ]',
    "42",
    "# # #",
    "true",
    "caught",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_regex_basic(force_compile):
    lines = run_lox("regex_basic.lox", force_compile=force_compile)
    assert lines == EXPECTED
