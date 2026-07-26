import pytest
from lox_helper import run_lox

# thread.*/sync.* are permanently out of scope for odlox (no cross-VM
# value copying, no mutex/atomic anywhere in this port -- see
# docs/ARCHITECTURE.md's Scope section and ROADMAP.md's header). This
# isn't a "not implemented yet" gap; it's never going to pass.
pytestmark = pytest.mark.skip(reason="thread.* is permanently out of scope for odlox — see ARCHITECTURE.md's Scope section")

BASIC_EXPECTED = [
    "42",
    "done",
    "nil",
]

ISOLATION_EXPECTED = [
    "110",
    '[ "a" , "b" , "z" ]',
    "11",
    '[ "a" , "b" , "c" ]',
    "nil",
]

PANIC_EXPECTED = [
    "caught ThreadError",
    "done",
    "nil",
]

CANCEL_EXPECTED = [
    "nil",
    "done",
    "nil",
]

POOL_100_EXPECTED = [
    "100",
    "0",
    "338350",
    "1",
    "10000",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_thread_basic(force_compile):
    lines = run_lox("thread_basic.lox", force_compile=force_compile)
    assert lines == BASIC_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_thread_isolation(force_compile):
    # A spawned closure's captured (upvalue) locals must be deep-copied,
    # not shared -- mutating the original after spawn must not leak into
    # the thread, and vice versa. Covers both a scalar and a captured list
    # (the ListObject clone path).
    lines = run_lox("thread_isolation.lox", force_compile=force_compile)
    assert lines == ISOLATION_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_thread_panic(force_compile):
    # An uncaught exception inside a spawned thread must surface as a
    # catchable ThreadError from wait(), not crash the process.
    lines = run_lox("thread_panic.lox", force_compile=force_compile)
    assert lines == PANIC_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_thread_cancel(force_compile):
    # cancel() must unblock a worker parked in channel().recv() promptly
    # (not hang). Mirrors process.kill() producing a clean EOF for
    # process.wait_any rather than a ProcessError: a cancelled thread's
    # wait() must return cleanly (nil), not raise, since cancellation is
    # an expected, self-inflicted shutdown, not a fault.
    lines = run_lox("thread_cancel.lox", force_compile=force_compile)
    assert lines == CANCEL_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_thread_pool_100(force_compile):
    # The thread-module analogue of test_process_pool_100: a fixed pool of
    # 4 in-memory worker closures draining a 100-task queue, dispatched
    # dynamically via thread.wait_any as each worker frees up. Every task
    # must be dispatched exactly once and every result slot filled,
    # regardless of scheduling order across the 4 threads.
    lines = run_lox("thread_pool_100.lox", force_compile=force_compile)
    assert lines == POOL_100_EXPECTED
