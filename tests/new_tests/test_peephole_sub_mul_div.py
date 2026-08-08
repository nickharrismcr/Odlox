from lox_helper import run_lox


def test_peephole_sub_mul_div():
    """Peephole fusion for Subtract/Multiply/Divide (Sub_Nn/Mul_Nn/Div_Nn
    and their _Const_N local-constant siblings) plus the Inc_Local
    `x += 1` shortcut. The important assertions are the vector-
    subtraction and string-repetition cases: Subtract/Multiply are not
    purely numeric operators, so the fused opcodes must fall back to the
    exact unfused behavior rather than corrupting non-numeric operands,
    including a call site that starts numeric and later sees a vector."""
    lines = run_lox("peephole_sub_mul_div.lox")
    assert lines == [
        "7",  # sub_local_local(): 10 - 3
        "10",  # sub_const(): 10.5 - 0.5
        "4",  # sub_vec().x: vec3(5,5,5) - vec3(1,2,3)
        "3",  # sub_vec().y
        "2",  # sub_vec().z
        "7",  # sub_poly(10, 3) -- patches the call site to Sub_Ii
        "4",  # sub_poly(vec2(5,5), vec2(1,1)).x -- same site, now a vector
        "4",  # sub_poly(...).y
        "42",  # mul_local_local(): 6 * 7
        "10",  # mul_const(): 2.5 * 4.0
        "ababab",  # mul_str(): "ab" * 3, through the same fused shape
        "5",  # div_local_local(): 20 / 4
        "4.5",  # div_const(): 9.0 / 2.0
        "caught: Division by zero.",  # div_zero() via the fused Div_Ii shape
        "3",  # inc_local(): three `i += 1`
        "10",  # loop_sum(): 0+1+2+3+4, accumulator + Inc_Local counter together
        "peephole_sub_mul_div complete",
        "nil",  # the script's own top-level expression result
    ]
