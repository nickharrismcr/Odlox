from lox_helper import run_lox


EXPECTED = [
    "5",          # add(2, 3)
    "30",         # scale(10), capturing `mul`
    "7",          # immediately-invoked lambda
    "11",         # ops[0](10)
    "20",         # ops[1](10)
    "81",         # dict-stored lambda d["sq"](9)
    "99",           # method returning a lambda that captures `this`
    "[ 1 , 4 , 9 ]",  # functools.map with a lambda
    "[ 2 , 4 ]",    # functools.filter with a lambda predicate
    "10",           # functools.reduce with a lambda
    "1",          # named declaration still works
]


def test_lambda():
    # Anonymous functions (block body) as expressions: assignment, closure
    # capture, IIFE, storage in list/dict, `this` capture in a method, and use
    # as higher-order-function arguments. Run both fresh-compile and cached.
    for force in (True, False):
        lines = run_lox("lambda.lox", force_compile=force)
        assert lines[-1] == "nil"      # top-level nil return
        assert lines[:-1] == EXPECTED
