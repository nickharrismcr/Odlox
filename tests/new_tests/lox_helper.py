import subprocess, os

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ODLOX     = os.path.join(REPO_ROOT, "bin", "odlox.exe")
LOX_DIR   = os.path.join(REPO_ROOT, "tests", "new_tests", "lox")
TESTS_DIR = os.path.join(REPO_ROOT, "tests", "new_tests")


def run_lox(filename, force_compile=False, timeout=None):
    """Run a .lox script; return list of output lines (normalised).

    timeout is None (wait indefinitely) for every existing caller -- only
    a test with a real reason to bound the wait (e.g. guarding against a
    regressed infinite-recursion bug) should pass one.
    """
    path = os.path.join(LOX_DIR, filename)
    cmd  = [ODLOX] + (["--force-compile"] if force_compile else []) + [path]
    r    = subprocess.run(cmd, capture_output=True, cwd=TESTS_DIR, timeout=timeout)
    raw  = r.stdout.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return raw.decode("ascii").splitlines()
