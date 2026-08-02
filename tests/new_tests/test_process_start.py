import pytest
from lox_helper import run_lox

# process.start()/.kill() -- a pipeless companion process, distinct from
# process.spawn()'s pickled-value pipe. Kept in its own file rather than
# folded into test_process.py, which is currently skipped whole-file for
# an unrelated process.wait_any() pipe-EOF race (see that file's header
# comment) that this code path doesn't share.
EXPECTED = [
    "worker ran",
    "nil",  # the worker's own script-result print (main.odin prints every
    # script's result value; a bare "print" statement's own script yields
    # nil) -- expected since process.start() inherits this process's
    # stdout, unlike process.spawn()'s pipe-redirected variant.
    "0",
    "caught send",
    "caught recv",
    "caught try_recv",
    "killed",
    "done",
    "nil",
]


@pytest.mark.parametrize("force_compile", [False, True])
def test_process_start_basic(force_compile):
    lines = run_lox("process_start_basic.lox", force_compile=force_compile)
    assert lines == EXPECTED
