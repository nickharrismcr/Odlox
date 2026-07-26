import pytest
from lox_helper import run_lox

# sync.Mutex is permanently out of scope for odlox, same as thread.* --
# see docs/ARCHITECTURE.md's Scope section and ROADMAP.md's header.
pytestmark = pytest.mark.skip(reason="sync.Mutex is permanently out of scope for odlox — see ARCHITECTURE.md's Scope section")

MUTEX_EXPECTED = [
    "20",
    "done",
    "nil",
]

MUTEX_FINALLY_EXPECTED = [
    "caught SyncError",
    "reacquired ok",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_sync_mutex(force_compile):
    # Globals are shared across threads, not isolated -- several threads
    # all incrementing the same global counter, serialised through one
    # Mutex, must add up exactly, every run.
    lines = run_lox("sync_mutex.lox", force_compile=force_compile)
    assert lines == MUTEX_EXPECTED


@pytest.mark.parametrize("force_compile", [False, True])
def test_sync_mutex_finally(force_compile):
    # A closure run via locked() that raises must still release the
    # mutex, proven by a second acquire()/release() succeeding promptly
    # afterward instead of hanging forever.
    lines = run_lox("sync_mutex_finally.lox", force_compile=force_compile)
    assert lines == MUTEX_FINALLY_EXPECTED
