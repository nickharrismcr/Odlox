import pytest
from lox_helper import run_lox

# Regression coverage for the length-based string interning split
# (core.STRING_INTERN_MAX_LEN): strings over 40 bytes are no longer
# forced through the permanent intern table (see docs/plans), so dict
# keys built from long strings must still resolve correctly by content.
EXPECTED = [
    "true",
    "42",
    "true",
    "42",
    "default",
    "42",
    "false",
    "literal-init value",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_dict_long_string_key(force_compile):
    lines = run_lox("dict_long_string_key.lox", force_compile=force_compile)
    assert lines == EXPECTED


LONG_IDENTIFIER_EXPECTED = [
    "42",
    "42",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_long_identifier_names(force_compile):
    lines = run_lox("long_identifier_names.lox", force_compile=force_compile)
    assert lines == LONG_IDENTIFIER_EXPECTED
