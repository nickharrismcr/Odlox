from lox_helper import run_lox


def test_float_array_3d():
    """gfx.float_array_3d(w, h, d): the 3D counterpart to float_array --
    construction, get/set/clear, dimensions, string form, type(), and
    bounds checking (both get and set) raise a catchable RunTimeError."""
    lines = run_lox("float_array_3d.lox")
    assert lines == [
        "4",  # width()
        "3",  # height()
        "2",  # depth()
        "0",  # get(0, 0, 0) before any set -- new cells start at zero
        "42.5",  # get(1, 2, 1) after set(1, 2, 1, 42.5)
        "0",  # get(0, 0, 0) unaffected by the set above
        "7",  # get(0, 0, 0) after clear(7.0)
        "7",  # get(3, 2, 1) after clear(7.0)
        "<FloatArray3D 4x3x2>",
        "builtin",  # type(arr)
        "get oob: Index out of bounds: (4, 0, 0) for array size 4x3x2.",
        "set oob: Index out of bounds: (0, 0, -1) for array size 4x3x2.",
        "float_array_3d complete",
        "nil",  # the script's own top-level expression result
    ]
