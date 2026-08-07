from lox_helper import run_lox


def test_gui_hover():
    lines = run_lox("gui_hover.lox")
    assert lines == ["over", "leave", "nil"]


def test_gui_click():
    lines = run_lox("gui_click.lox")
    assert lines == ["left_click", "right_click", "nil"]


def test_gui_drag():
    lines = run_lox("gui_drag.lox")
    assert lines == ["start", "drag", "drag", "end", "true", "true", "nil"]


def test_gui_z_order():
    lines = run_lox("gui_z_order.lox")
    assert lines == ["b", "nil"]
