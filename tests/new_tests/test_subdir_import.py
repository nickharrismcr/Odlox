from lox_helper import run_lox


# nested_module.lox lives in lox/subdir_mods/, not next to subdir_import.lox --
# covers getPath()'s recursive subdirectory search.
def test_subdir_import():
    lines = run_lox("subdir_import.lox")
    assert lines[0] == "hello world"
    assert lines[1] == "found in subfolder"
    assert lines[-1] == "nil"
