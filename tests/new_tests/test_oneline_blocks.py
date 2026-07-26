from lox_helper import run_lox


# Expected output of oneline_blocks.lox, in order. The interpreter prints a
# trailing "nil" (the top-level script's nil return) as the final line, so the
# meaningful output is everything except the last line.
EXPECTED = [
    "if",       # if (true) { print "if" }
    "else",     # if (false) {...} else { print "else" }
    "nested",   # if (true) { if (true) { print "nested" } }
    "0", "1", "2",   # while (i < 3) { print i; i = i + 1 }
    "0", "1",        # for (var j = 0; j < 2; ...) { print j }
    "0", "1",        # foreach (k in range(2)) { print k }
    "42",       # func f() { return 42 } print f()
    "g-ok",     # func g() { return } g() ; print "g-ok"
    "bare",     # { print "bare" }
    "7",        # { const c = 7; print c }
    "before",   # if (true) { print "before" } print "after"
    "after",
]


def test_oneline_blocks():
    # Every block-bearing construct written on a single line must parse and run.
    # Run twice: forcing recompilation and from the cached .lxc, to cover both
    # the fresh-compile and cache-load paths.
    for force in (True, False):
        lines = run_lox("oneline_blocks.lox", force_compile=force)
        assert lines[-1] == "nil"            # top-level nil return
        assert lines[:-1] == EXPECTED


def test_oneline_missing_separator_still_errors():
    # The fix must NOT turn whitespace into a statement separator: two
    # statements on one line with no ';' / newline / '}' between them is still
    # a compile error, so `print 1 print 2` must not print 1 and 2.
    lines = run_lox("oneline_bad.lox")
    assert lines != ["1", "2"]
    assert any("Error" in ln for ln in lines)
    assert "1" not in lines and "2" not in lines
