import pytest
from lox_helper import run_lox

EXPECTED = [
    "false",
    "true",
    "true",
    "false",
    "hello",
    "true",
    "world",
    "echo:hello",
    "",
    "caught connect error",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_socket_basic(force_compile):
    lines = run_lox("socket_basic.lox", force_compile=force_compile)
    assert lines == EXPECTED
