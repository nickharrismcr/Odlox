from lox_helper import run_lox


def test_inspect_dump():
    lines = run_lox("inspect_dump.lox")
    assert lines[0] == "2"
    assert "Frame: init" in lines[2]
    assert "Frame: out" in "\n".join(lines)
    assert lines[-2] == "10"
    assert lines[-1] == "nil"


def test_inspect_frame_dict():
    lines = run_lox("inspect_frame_dict.lox")
    assert '( "function" , ":" , "test" )' in lines
    assert '( "file" , ":" , "inspect_frame_dict.lox" )' in lines
    assert '( "local1" , ":" , 3 )' in lines
    assert '( "local2" , ":" , 5 )' in lines
    assert '( "local3" , ":" , 4 )' in lines
    assert lines[-1] == "nil"


def test_inspect_prev_frame():
    lines = run_lox("inspect_prev_frame.lox")
    assert '( "function" , ":" , "test2" )' in lines
    assert '( "file" , ":" , "inspect_prev_frame.lox" )' in lines
    assert '( "prev_frame" , "dict" )' in lines
    assert lines[-1] == "nil"
