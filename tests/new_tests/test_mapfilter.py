import pytest
from lox_helper import run_lox


def _parse_list(line):
    """Parse a Lox list like '[ 0 , 2 , 4 ]' into a Python list of ints."""
    stripped = line.strip()
    if stripped == "[  ]":
        return []
    inner = stripped[1:-1].strip()
    return [int(x.strip()) for x in inner.split(",")]


@pytest.mark.parametrize("script", ["mapfilter.lox", "mapfilter_ns.lox"])
def test_mapfilter_line_count(script):
    lines = run_lox(script)
    # 100 iterations × 2 lines (map result + filter result) + nil
    assert len(lines) == 201
    assert lines[-1] == "nil"


@pytest.mark.parametrize("script", ["mapfilter.lox", "mapfilter_ns.lox"])
def test_mapfilter_first_iteration(script):
    lines = run_lox(script)
    # i=0: makeList(0) == [], map doubles nothing, filter nothing
    assert lines[0] == "[  ]"
    assert lines[1] == "[  ]"


@pytest.mark.parametrize("script", ["mapfilter.lox", "mapfilter_ns.lox"])
def test_mapfilter_map_doubles(script):
    lines = run_lox(script)
    # For i=10: makeList(10)=[0..9], map doubles → [0,2,4,6,8,10,12,14,16,18]
    map_line = lines[20]  # i=10 is at index 20 (i=0→lines 0,1; i=1→lines 2,3 ... i=10→lines 20,21)
    mapped = _parse_list(map_line)
    assert mapped == [x * 2 for x in range(10)]


@pytest.mark.parametrize("script", ["mapfilter.lox", "mapfilter_ns.lox"])
def test_mapfilter_filter_divisible_by_6(script):
    lines = run_lox(script)
    # All filter results should only contain multiples of 6
    # (map doubles then filter picks multiples of 3 → multiples of 6)
    for i in range(100):
        filter_line = lines[i * 2 + 1]
        filtered = _parse_list(filter_line)
        for val in filtered:
            assert val % 6 == 0, f"Expected multiple of 6, got {val} at iteration {i}"


@pytest.mark.parametrize("script", ["mapfilter.lox", "mapfilter_ns.lox"])
def test_mapfilter_last_iteration(script):
    lines = run_lox(script)
    # i=99: makeList(99)=[0..98], map doubles → 99 elements, 0,2,4,...,196
    map_line = lines[198]
    mapped = _parse_list(map_line)
    assert len(mapped) == 99
    assert mapped == [x * 2 for x in range(99)]
