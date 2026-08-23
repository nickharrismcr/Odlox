from lox_helper import run_lox


def test_circular_import_fails_cleanly_instead_of_crashing():
    # Regression test: a genuine circular import (a imports b, b imports a)
    # used to recurse load_module -> compile_and_run_module -> do_import ->
    # load_module unboundedly (module_cache is only populated *after* a
    # module's load fully completes, so nothing detected the cycle) --
    # a native call-stack crash, not a diagnosed error. vm/module.odin's
    # modules_loading guard now catches it and reports a runtime error
    # instead. timeout=10 guards against a real regression back to the
    # infinite-recursion hang rather than letting the test itself hang.
    lines = run_lox("circular_import_a.lox", timeout=10)
    assert any("circular import" in line.lower() for line in lines), lines
    # Neither module's own top-level code ever finishes running.
    assert "a loaded" not in lines
    assert "b loaded" not in lines
