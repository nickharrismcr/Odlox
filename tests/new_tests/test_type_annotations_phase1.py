from lox_helper import run_lox


def test_type_annotations_phase1():
    # Phase 1 (grammar surface) of optional type annotations: annotations
    # parse at all three sites (param, var decl, return type), plus
    # generic (List[int]) and nilable (string?) forms, and are silently
    # ignored -- runtime behaviour is unaffected either way.
    lines = run_lox("type_annotations_phase1.lox")
    assert lines[0] == "1"
    assert lines[1] == "[ 1 , 2 , 3 ]"
    assert lines[2] == "nil"           # var c: string? with no initializer
    assert lines[3] == "15"            # add(5) -> default y = 10
    assert lines[4] == "25"            # add(5, 20)
    assert lines[5] == "hello, stranger"
    assert lines[6] == "hello, Sam"
    assert lines[7] == "42"            # Box(42).get()
