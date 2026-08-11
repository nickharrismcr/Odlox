from lox_helper import run_lox


def assert_all_true(script, count):
    """Assert a fixture printed `count` "true" lines followed by the CLI's
    trailing "nil" -- the shape of every fixture below that's just a
    sequence of boolean checks."""
    lines = run_lox(script)
    assert lines == ["true"] * count + ["nil"]


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


def test_gui_segmented_line():
    lines = run_lox("gui_segmented_line.lox")
    assert lines == [
        "start", "drag", "drag", "end",
        "true", "true", "true",
        "true", "true", "true", "true", "true",
        "nil",
    ]


def test_gui_pressed_vs_selected():
    lines = run_lox("gui_pressed_vs_selected.lox")
    assert lines == ["true", "true", "true", "nil"]


def test_gui_snap():
    assert_all_true("gui_snap.lox", 7)


def test_gui_checkbox():
    assert_all_true("gui_checkbox.lox", 10)


def test_gui_slider():
    assert_all_true("gui_slider.lox", 6)


def test_gui_button_group():
    assert_all_true("gui_button_group.lox", 17)


def test_gui_marquee():
    assert_all_true("gui_marquee.lox", 13)


def test_gui_screen_zorder_focus():
    assert_all_true("gui_screen_zorder_focus.lox", 6)


def test_gui_disabled():
    assert_all_true("gui_disabled.lox", 3)


def test_gui_label():
    assert_all_true("gui_label.lox", 12)


def test_gui_text_input():
    assert_all_true("gui_text_input.lox", 13)
