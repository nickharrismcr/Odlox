import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("force_compile", [False, True])
def test_nested_try_same_frame_fallback(force_compile):
    # raiseException used to check only the innermost try's own except
    # clauses, then immediately unwind to the caller frame if none matched
    # -- skipping an enclosing try's matching handler in the same frame.
    lines = run_lox("nested_try_same_frame_fallback.lox", force_compile=force_compile)
    assert lines == ["outer caught: boom", "done", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_nested_try_fallback_with_finally(force_compile):
    # Same fallback, but the inner try also has a finally clause: its
    # cleanup must still run before escalating to the outer handler.
    lines = run_lox("nested_try_fallback_with_finally.lox", force_compile=force_compile)
    assert lines == ["inner finally", "outer caught: boom", "done", "nil"]


@pytest.mark.parametrize("force_compile", [False, True])
def test_except_class_inside_function(force_compile):
    # A try/except for a user-defined exception class used to fail to
    # resolve the class name whenever it lived inside any non-top-level
    # function, regardless of where the raise itself happened.
    lines = run_lox("except_class_inside_function.lox", force_compile=force_compile)
    assert lines == [
        "caught in g: from a nested call",
        "caught in h: same frame",
        "done",
        "nil",
    ]
