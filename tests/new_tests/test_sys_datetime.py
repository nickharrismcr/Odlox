import re

import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("force_compile", [False, True])
def test_sys_today_and_now(force_compile):
    # sys.today()/sys.now() are real wall-clock date/time, so the exact
    # value isn't deterministic -- assert on shape instead of exact value.
    lines = run_lox("sys_datetime.lox", force_compile=force_compile)
    assert len(lines) == 4
    assert re.match(r"^\d{4}-\d{2}-\d{2}$", lines[0])
    assert re.match(r"^\d{2}:\d{2}:\d{2}$", lines[1])
    assert lines[2] == "done"
    assert lines[3] == "nil"
