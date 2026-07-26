import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("force_compile", [False, True])
def test_multi_except_first_match(force_compile):
    # OP_TRY's operand used to be patched once per except clause instead of
    # once, so it always ended up pointing at the *last* clause -- an
    # exception matching an earlier, non-last clause went uncaught.
    lines = run_lox("multi_except_first_match.lox", force_compile=force_compile)
    assert lines == ["caught FooError", "caught BarError", "done", "nil"]


@pytest.mark.parametrize("script", ["except_fallthrough_no_raise.lox", "except_fallthrough_no_raise_ns.lox"])
def test_except_fallthrough_no_raise(script):
    # Falling through a try body without raising, when an except clause is
    # present, used to panic the VM outright (OP_END_TRY never consumed its
    # own jump offset).
    lines = run_lox(script)
    assert lines == ["before", "after", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_except_first_clause_completes(force_compile):
    # Once the "always points at the last clause" bug is fixed on its own,
    # a second bug was exposed: after a non-last clause matched and
    # completed, execution fell through into the next clause's own body.
    lines = run_lox("except_first_clause_completes.lox", force_compile=force_compile)
    assert lines == ["in foo handler", "done", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_except_break_stale_handler(force_compile):
    # break/continue never used to pop frame.Handlers, leaving a stale
    # handler that could incorrectly "catch" a later, unrelated exception.
    lines = run_lox("except_break_stale_handler.lox", force_compile=force_compile)
    assert lines[0] == "correctly caught: first"
    assert lines[1] == 'Uncaught exception: <class BoomError> : "second, should be uncaught" '
