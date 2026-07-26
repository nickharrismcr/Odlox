import pytest
from lox_helper import run_lox

EXPECTED = [
    "bob",
    "30",
    "a",
    "b",
    "true",
    "nil",
    "3.14",
    "[1,2,3]",
    "3",
    '"quote\\"back\\\\slash\\nline\\ttab"',
    "true",
    "1",
    "true",
    "false",
    "nil",
    "-350",
    "42",
    "0",
    "{",
    '  "a": [',
    "    1,",
    "    {",
    '      "b": 2',
    "    }",
    "  ]",
    "}",
    "caught decode error",
    "caught encode error",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_json_basic(force_compile):
    lines = run_lox("json_basic.lox", force_compile=force_compile)
    assert lines == EXPECTED
