from lox_helper import run_lox


def test_builtin_modules():
    lines = run_lox("builtin_modules.lox")
    assert lines[0] == "10"        # gfx.decode_rgba(gfx.encode_rgba(...))
    assert lines[1] == "20"
    assert lines[2] == "30"
    assert lines[3] == "true"      # from gfx import encode_rgba
    assert lines[4] == "builtin"   # from sys import clock (native from-import)
    assert lines[5] == "builtin"   # physics.physics_world namespaced
    assert lines[-1] == "nil"
