import pytest
from lox_helper import run_lox

BASIC_EXPECTED = [
    "false",
    "42",
    "0",
    "caught broken pipe",
    "done",
    "nil",
]

POOL_EXPECTED = [
    "4",
    "9",
    "25",
    "49",
    "121",
    "169",
    "289",
    "361",
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

WAIT_ANY_POOL_EXPECTED = [
    "Results for worker 1",
    "1 * 1 = 10.000000",
    "1 * 2 = 20.000000",
    "1 * 3 = 30.000000",
    "1 * 4 = 40.000000",
    "Results for worker 2",
    "2 * 1 = 20.000000",
    "2 * 2 = 40.000000",
    "2 * 3 = 60.000000",
    "2 * 4 = 80.000000",
    "Results for worker 3",
    "3 * 1 = 30.000000",
    "3 * 2 = 60.000000",
    "3 * 3 = 90.000000",
    "3 * 4 = 120.000000",
    "Results for worker 4",
    "4 * 1 = 40.000000",
    "4 * 2 = 80.000000",
    "4 * 3 = 120.000000",
    "4 * 4 = 160.000000",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_process_basic(force_compile):
    lines = run_lox("process_basic.lox", force_compile=force_compile)
    assert lines == BASIC_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_process_pool(force_compile):
    lines = run_lox("process_pool.lox", force_compile=force_compile)
    assert lines == POOL_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_process_pool_100(force_compile):
    # Same fixed-worker-pool/task-queue design as test_process_pool, scaled
    # to the numbers actually worth checking: a pool much smaller than the
    # queue (4 workers, 100 tasks), so most workers run several tasks each
    # and the pool stays saturated throughout. Every task must be dispatched
    # exactly once and every result slot filled, regardless of which worker
    # happens to finish first.
    lines = run_lox("process_pool_100.lox", force_compile=force_compile)
    assert lines == POOL_100_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_process_wait_any_pool(force_compile):
    # Regression test: workers fire-and-forget several messages each with no
    # request/response handshake, then exit. wait_any() must keep draining
    # whichever workers are still live instead of aborting the whole fan-in
    # the moment any one of them finishes, and must return nil (not deadlock
    # the process) once every worker is done.
    lines = run_lox("process_wait_any_pool.lox", force_compile=force_compile)
    assert lines == WAIT_ANY_POOL_EXPECTED
