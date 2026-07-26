import re

import pytest
from lox_helper import run_lox

TS = r"\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]"


@pytest.mark.parametrize("force_compile", [False, True])
def test_logging_default(force_compile):
    # Default Logger(): debug is suppressed (default level is INFO), the
    # other four levels appear, and an unrecognised level falls back to a
    # "LEVEL<n>" label rather than raising.
    lines = run_lox("logging_default.lox", force_compile=force_compile)
    assert len(lines) == 7
    assert re.match(TS + r" \[INFO\] root: hello$", lines[0])
    assert re.match(TS + r" \[WARN\] root: careful$", lines[1])
    assert re.match(TS + r" \[ERROR\] root: bad$", lines[2])
    assert re.match(TS + r" \[CRITICAL\] root: very bad$", lines[3])
    assert lines[4] == "LEVEL999"
    assert lines[5] == "done"
    assert lines[6] == "nil"


@pytest.mark.parametrize("force_compile", [False, True])
def test_logging_set_level(force_compile):
    # Constructing with level=WARN suppresses debug/info; set_level()/
    # get_level() work after construction too.
    lines = run_lox("logging_set_level.lox", force_compile=force_compile)
    assert len(lines) == 7
    assert re.match(TS + r" \[WARN\] w: careful$", lines[0])
    assert re.match(TS + r" \[ERROR\] w: bad$", lines[1])
    assert re.match(TS + r" \[CRITICAL\] w: very bad$", lines[2])
    assert lines[3] == "true"
    assert re.match(TS + r" \[CRITICAL\] w: still shown$", lines[4])
    assert lines[5] == "done"
    assert lines[6] == "nil"


@pytest.mark.parametrize("force_compile", [False, True])
def test_logging_custom_writer(force_compile):
    # A capturing writer receives the exact formatted line, and
    # Logger.DEBUG as the configured level lets every level through.
    lines = run_lox("logging_custom_writer.lox", force_compile=force_compile)
    assert lines == [
        "[DEBUG] t: d",
        "[INFO] t: i",
        "[WARN] t: w",
        "[ERROR] t: e",
        "[CRITICAL] t: c",
        "5",
        "done",
        "nil",
    ]


@pytest.mark.parametrize("force_compile", [False, True])
def test_logging_file_writer(force_compile):
    # logging.file_writer(file) writes through to a real file exactly like
    # the default writer prints -- debug is suppressed by the default
    # INFO level, and the file's content round-trips through os.read_all.
    lines = run_lox("logging_file_writer.lox", force_compile=force_compile)
    assert len(lines) == 5
    assert re.match(TS + r" \[INFO\] app: first$", lines[0])
    assert re.match(TS + r" \[INFO\] app: second$", lines[1])
    assert lines[2] == ""
    assert lines[3] == "done"
    assert lines[4] == "nil"
