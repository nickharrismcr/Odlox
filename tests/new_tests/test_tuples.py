import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["tuples.lox", "tuples_ns.lox"])
def test_tuples(script):
    lines = run_lox(script)
    # append(2, a)'s first argument is a bare int, not a list -- append()'s
    # signature (compiler/typecheck_native.odin) diagnoses this at compile
    # time, printed before any program output.
    assert "argument 1" in lines[0].lower() and "list" in lines[0].lower()
    # lines[1]: the warning's own source-line echo (print_type_diagnostics).
    # foreach over (1,2,3,4,5,6)
    assert lines[2:8] == ["1", "2", "3", "4", "5", "6"]
    # tuple concatenation
    assert lines[8] == "[ 1 , 2 , 3 , 7 , 8 , 9 ]"
    # append(2, a) raises RuntimeError — tuples are immutable (append expects list as first arg).
    # lines[9], not lines[-1]: odlox now prints a call stack trace after the
    # error message (matching glox's own vm.PrintStackTrace, unconditional
    # on every uncaught runtime error), so the error message itself is no
    # longer necessarily the last line of output.
    assert "Uncaught exception" in lines[9]
    assert "append" in lines[9].lower() or "list" in lines[9].lower()
