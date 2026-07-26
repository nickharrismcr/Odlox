import pytest
from lox_helper import run_lox

PROCESS_REUSE_EXPECTED = [
    "[ 4 , 9 , 16 ]",
    "[ 25 , 36 , 49 , 64 , 81 ]",
    "true",
    "caught closed pool",
    "done",
    "nil",
]

THREAD_REUSE_EXPECTED = [
    '[ ( 4 , 1 ) , ( 9 , 2 ) , ( 16 , 3 ) ]',
    '[ ( 25 , 4 ) , ( 36 , 5 ) ]',
    "caught closed pool",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_process_pool_reuse(force_compile):
    # A ProcessPool must be reusable across multiple map() calls without
    # respawning its workers (proven by matching pid()s before/after two
    # differently-sized map() calls), and map() on a closed pool must raise
    # PoolError rather than hang or crash.
    lines = run_lox("process_pool_reuse.lox", force_compile=force_compile)
    assert lines == PROCESS_REUSE_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_thread_pool_reuse(force_compile):
    # Same property as test_process_pool_reuse, but proven differently
    # since a thread has no OS pid: a task function capturing a mutable
    # counter upvalue must keep accumulating across two separate map()
    # calls (a fresh spawn would reset it to the closure's originally
    # captured value), proving the same underlying thread was reused, not
    # respawned. Uses 1 worker so dispatch is deterministic.
    lines = run_lox("thread_pool_reuse.lox", force_compile=force_compile)
    assert lines == THREAD_REUSE_EXPECTED
