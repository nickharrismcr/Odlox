import pytest
from lox_helper import run_lox


@pytest.mark.parametrize("script", ["class_static_var.lox", "class_static_var_ns.lox"])
def test_class_static_var(script):
    lines = run_lox(script)
    assert lines[0] == "2"     # Animal.count after two instances (base and subclass)
    assert lines[1] == "2"     # Dog.count reads the same shared value via Super
    assert lines[2] == "nil"   # Animal.label defaults to nil, like a bare "var"
    assert lines[3] == "99"    # Dog.count = 99 shadows, only affects Dog
    assert lines[4] == "2"     # Animal.count is untouched by the Dog shadow
    assert lines[5] == "3"     # Animal.count += 1 works via compound assignment
    assert lines[6] == "Rex is an animal"  # static method still works alongside static vars in the same class
    assert lines[7] == "25"    # static method on a class with no static vars at all
    assert lines[-1] == "nil"
