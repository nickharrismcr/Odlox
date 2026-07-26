from lox_helper import run_lox


def test_nested_for_continue():
    # Regression test for a compiler bug where `continue` inside a for-loop
    # nested 3+ levels deep would pop the loop's own control variable along
    # with body locals, corrupting the loop counter (crash or infinite hang)
    # once an intervening expression (e.g. a list index) reclaimed the freed
    # stack slot. See src/compiler/compile.go continueStatement().
    lines = run_lox("nested_for_continue.lox")
    assert lines[0] == "0"
    assert lines[-1] == "nil"
