package compiler

import "../core"
import "core:testing"

// Opcode-sequence tests for the Emitter, exercised end to end through
// Compile()/Compile_Repl(). Duplicates compile_test.odin's own decode()/
// op_sequence()/contains_op()/count_op() helpers (file-private there, so
// can't be shared directly) and reuses several of its exact source
// strings for direct opcode-for-opcode parity checks, plus dedicated
// coverage for try/finally *crossing* (a return/break/continue whose
// target is outside an enclosing try) -- something the old single-pass
// compiler's trampoline design made hard to test deliberately, so
// compile_test.odin has no equivalent of its own.

@(private = "file")
Decoded :: struct {
	op:       core.Op_Code,
	operands: []u8,
}

@(private = "file")
decode :: proc(c: ^core.Chunk) -> [dynamic]Decoded {
	out: [dynamic]Decoded
	code := c.code[:]
	i := 0
	for i < len(code) {
		op := core.Op_Code(code[i])
		i += 1
		n := 0
		#partial switch op {
		case .Constant, .Get_Local, .Set_Local, .Inc_Local,
		     .Get_Global, .Set_Global, .Define_Global, .Define_Global_Const,
		     .Get_Upvalue, .Set_Upvalue, .Call, .Create_List, .Create_Dict,
		     .Create_Tuple, .Unpack, .Set_Property, .Method,
		     .Static_Method, .Class_Var, .Get_Super, .Class:
			n = 1
		case .Jump_If_False, .Jump, .Loop, .Try, .End_Try, .Add_Nn,
		     .Incr_Const_N, .Add_Vv, .Sub_Nn, .Decr_Const_N, .Mul_Nn,
		     .Mul_Const_N, .Div_Nn, .Div_Const_N, .Super_Invoke, .Import,
		     .Get_Property:
			n = 2
		case .Invoke:
			n = 3
		case .Except:
			n = 3
		case .Jump_If_Defined:
			n = 3
		case .Foreach:
			n = 4
		case .Next:
			n = 4
		case .Closure:
			const_idx := code[i]
			fn := core.as_function(c.constants[const_idx])
			n = 1 + 2 * fn.upvalue_count
		case .Import_From:
			count := code[i + 1]
			n = 2 + int(count)
		case:
			n = 0
		}
		append(&out, Decoded{op = op, operands = code[i:i + n]})
		i += n
	}
	return out
}

@(private = "file")
op_sequence :: proc(c: ^core.Chunk) -> [dynamic]core.Op_Code {
	out: [dynamic]core.Op_Code
	for d in decode(c) {
		append(&out, d.op)
	}
	return out
}

@(private = "file")
contains_op :: proc(c: ^core.Chunk, op: core.Op_Code) -> bool {
	for d in decode(c) {
		if d.op == op {
			return true
		}
	}
	return false
}

@(private = "file")
count_op :: proc(c: ^core.Chunk, op: core.Op_Code) -> int {
	n := 0
	for d in decode(c) {
		if d.op == op {
			n += 1
		}
	}
	return n
}

@(private = "file")
inner_function_chunk :: proc(t: ^testing.T, c: ^core.Chunk) -> ^core.Chunk {
	for v in c.constants {
		if v.type == .Obj && v.obj_type == .Function {
			return core.as_function(v).chunk
		}
	}
	testing.fail(t)
	return nil
}

@(private = "file")
compile_ok :: proc(t: ^testing.T, source: string) -> ^core.Chunk {
	env := core.make_environment("test")
	fn, ok := Compile(source, "test.lox", env)
	testing.expectf(t, ok, "expected %q to compile without error", source)
	return fn.chunk
}

// -----------------------------------------------------------------------
// Smoke test -- same source as compile_test.odin's
// test_kitchen_sink_program_compiles (no crossing return/break/continue
// out of the try, so squarely within this phase's scope).

@(test)
test_emit_kitchen_sink_program_compiles :: proc(t: ^testing.T) {
	compile_ok(t, `
class Animal {
	init(name) {
		this.name = name
	}
	speak() {
		return this.name & " makes a sound"
	}
}

class Dog < Animal {
	speak() {
		return super.speak() & "!"
	}
}

func make_counter(start=0) {
	var count = start
	return func() {
		count += 1
		return count
	}
}

var counter = make_counter()
var total = 0
for var i = 0; i < 5; i += 1 {
	total = total + counter()
}

var animals = [Animal("Cat"), Dog("Rex")]
foreach a in animals {
	print a.speak()
}

var config = {"retries": 3, "timeout": 10}
x, y = 1, 2

try {
	if x == 1 {
		raise "boom"
	}
} except RunTimeError as e {
	print e
} finally {
	print "cleanup"
}

import sys
from math import sqrt, pow
`)
}

// -----------------------------------------------------------------------
// Expressions

@(test)
test_emit_arithmetic_precedence_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "1 + 2 * 3\n")
	seq := op_sequence(c)
	testing.expectf(t, len(seq) >= 5, "expected at least 5 opcodes, got %d", len(seq))
	testing.expect_value(t, seq[0], core.Op_Code.Constant)
	testing.expect_value(t, seq[1], core.Op_Code.Constant)
	testing.expect_value(t, seq[2], core.Op_Code.Constant)
	testing.expect_value(t, seq[3], core.Op_Code.Multiply)
	testing.expect_value(t, seq[4], core.Op_Code.Add_Numeric)
}

@(test)
test_emit_comparison_operators_map_to_flip_plus_not :: proc(t: ^testing.T) {
	le := compile_ok(t, "1 <= 2\n")
	testing.expect(t, contains_op(le, .Greater))
	testing.expect(t, contains_op(le, .Not))

	ne := compile_ok(t, "1 != 2\n")
	testing.expect(t, contains_op(ne, .Equal))
	testing.expect(t, contains_op(ne, .Not))
}

@(test)
test_emit_vector_add_uses_plus_plus :: proc(t: ^testing.T) {
	c := compile_ok(t, "a ++ b\n")
	testing.expect(t, contains_op(c, .Add_Vector))
	testing.expect(t, !contains_op(c, .Add_Numeric))
}

@(test)
test_emit_ternary_conditional_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "x ? 1 : 2\n")
	testing.expect_value(t, count_op(c, .Jump_If_False), 1)
	testing.expect_value(t, count_op(c, .Jump), 1)
}

@(test)
test_emit_and_or_short_circuit_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "x and y\n")
	testing.expect(t, contains_op(c, .Jump_If_False))

	c2 := compile_ok(t, "x or y\n")
	testing.expect_value(t, count_op(c2, .Jump_If_False), 1)
	testing.expect_value(t, count_op(c2, .Jump), 1)
}

@(test)
test_emit_str_call_emits_str_opcode :: proc(t: ^testing.T) {
	c := compile_ok(t, "str(x)\n")
	testing.expect(t, contains_op(c, .Str))
}

@(test)
test_emit_list_dict_tuple_literals :: proc(t: ^testing.T) {
	l := compile_ok(t, "[1, 2, 3]\n")
	testing.expect(t, contains_op(l, .Create_List))

	d := compile_ok(t, `var d = {"a": 1}` + "\n")
	testing.expect(t, contains_op(d, .Create_Dict))

	tup := compile_ok(t, "(1, 2)\n")
	testing.expect(t, contains_op(tup, .Create_Tuple))
}

@(test)
test_emit_index_and_slice :: proc(t: ^testing.T) {
	idx := compile_ok(t, "x[0]\n")
	testing.expect(t, contains_op(idx, .Index))

	sl := compile_ok(t, "x[1:2]\n")
	testing.expect(t, contains_op(sl, .Slice))

	open_sl := compile_ok(t, "x[:]\n")
	testing.expect(t, contains_op(open_sl, .Slice))
}

@(test)
test_emit_compound_assignment_desugars_no_dedicated_opcode :: proc(t: ^testing.T) {
	c := compile_ok(t, "var x = 1\nx += 2\n")
	seq := op_sequence(c)
	found := false
	for i in 0 ..< len(seq) - 2 {
		if seq[i] == .Get_Global && seq[i + 2] == .Add_Numeric {
			found = true
		}
	}
	testing.expect(t, found)
}

// -----------------------------------------------------------------------
// Declarations

@(test)
test_emit_global_var_declaration_emits_define_global :: proc(t: ^testing.T) {
	c := compile_ok(t, "var x = 5\n")
	testing.expect(t, contains_op(c, .Define_Global))
}

@(test)
test_emit_local_var_declaration_has_no_define_global :: proc(t: ^testing.T) {
	c := compile_ok(t, "func f() { var x = 5; return x }\n")
	fn_chunk := inner_function_chunk(t, c)
	testing.expect(t, !contains_op(fn_chunk, .Define_Global))
	testing.expect(t, contains_op(fn_chunk, .Get_Local))
}

@(test)
test_emit_const_declaration_uses_define_global_const :: proc(t: ^testing.T) {
	c := compile_ok(t, "const X = 1\n")
	testing.expect(t, contains_op(c, .Define_Global_Const))
}

@(test)
test_emit_const_without_initializer_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("const X\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_emit_implicit_global_declaration :: proc(t: ^testing.T) {
	c := compile_ok(t, "x = 5\n")
	testing.expect(t, contains_op(c, .Define_Global))
}

@(test)
test_emit_destructuring_assignment_global :: proc(t: ^testing.T) {
	c := compile_ok(t, "a, b = 1, 2\n")
	testing.expect(t, contains_op(c, .Unpack))
	testing.expect_value(t, count_op(c, .Define_Global), 2)
}

// -----------------------------------------------------------------------
// Control flow

@(test)
test_emit_if_else_jump_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "if x { print 1 } else { print 2 }\n")
	testing.expect_value(t, count_op(c, .Jump_If_False), 1)
	testing.expect_value(t, count_op(c, .Jump), 1)
}

@(test)
test_emit_while_loop_has_back_edge :: proc(t: ^testing.T) {
	c := compile_ok(t, "while x { print 1 }\n")
	testing.expect(t, contains_op(c, .Loop))
	testing.expect_value(t, count_op(c, .Jump_If_False), 1)
}

@(test)
test_emit_break_and_continue_in_loop :: proc(t: ^testing.T) {
	c := compile_ok(t, "while x { if y { break } if z { continue } }\n")
	testing.expect_value(t, count_op(c, .Loop), 2) // 1 real back-edge + 1 from `continue`
}

@(test)
test_emit_break_outside_loop_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("break\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_emit_foreach_emits_iterator_trio :: proc(t: ^testing.T) {
	c := compile_ok(t, "foreach x in items { print x }\n")
	testing.expect(t, contains_op(c, .Foreach))
	testing.expect(t, contains_op(c, .Next))
	testing.expect(t, contains_op(c, .End_Foreach))
}

@(test)
test_emit_for_with_parens_and_no_increment :: proc(t: ^testing.T) {
	c := compile_ok(t, "for (var i = 0; i < 3;) { print i }\n")
	testing.expect(t, contains_op(c, .Loop))
}

@(test)
test_emit_break_pops_locals_declared_inside_loop_body :: proc(t: ^testing.T) {
	// A local declared inside the loop body must be popped right at the
	// break site, since the jump bypasses that block's own Stmt_Block
	// local_exits cleanup -- see ast.odin's Stmt_Break doc comment.
	c := compile_ok(t, "while x {\nvar y = 1\nif y { break }\n}\n")
	fn_chunk := c
	// Two Pop-producing scope exits should exist: one for the break's own
	// pop_exits (popping y before jumping out) and one for the normal
	// end-of-block cleanup on the non-break path through the same block.
	testing.expect(t, count_op(fn_chunk, .Pop) >= 2)
}

// -----------------------------------------------------------------------
// Functions/closures

@(test)
test_emit_default_parameter_emits_jump_if_defined :: proc(t: ^testing.T) {
	c := compile_ok(t, "func f(a, b=1) { return a + b }\n")
	fn_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(fn_chunk, .Jump_If_Defined))
}

@(test)
test_emit_non_default_after_default_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("func f(a=1, b) { return a }\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_emit_closure_captures_upvalue :: proc(t: ^testing.T) {
	c := compile_ok(t, `
func outer() {
	var x = 1
	return func() { return x }
}
`)
	outer_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(outer_chunk, .Closure))
	inner_chunk := inner_function_chunk(t, outer_chunk)
	testing.expect(t, contains_op(inner_chunk, .Get_Upvalue))
}

@(test)
test_emit_lambda_expression_compiles :: proc(t: ^testing.T) {
	c := compile_ok(t, "var f = func(x) { return x }\n")
	testing.expect(t, contains_op(c, .Closure))
}

// -----------------------------------------------------------------------
// Classes

@(test)
test_emit_class_declaration_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, `
class Point {
	init(x, y) {
		this.x = x
		this.y = y
	}
	static count = 0
}
`)
	testing.expect(t, contains_op(c, .Class))
	testing.expect(t, contains_op(c, .Method))
	testing.expect(t, contains_op(c, .Class_Var))
}

@(test)
test_emit_class_inheritance_emits_inherit_and_super :: proc(t: ^testing.T) {
	c := compile_ok(t, `
class A { greet() { return "a" } }
class B < A { greet() { return super.greet() } }
`)
	testing.expect(t, contains_op(c, .Inherit))
}

// -----------------------------------------------------------------------
// try / except / finally (no crossing -- see this file's header comment)

@(test)
test_emit_try_except_finally_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, `
try {
	raise "x"
} except RunTimeError as e {
	print e
} finally {
	print "done"
}
`)
	testing.expect(t, contains_op(c, .Try))
	testing.expect(t, contains_op(c, .Except))
	testing.expect(t, contains_op(c, .End_Except))
	testing.expect(t, contains_op(c, .Finally))
	testing.expect(t, contains_op(c, .Raise))
	// finally_body is emitted twice (see emit_try's own doc comment) --
	// once after Op_Finally, once at the shared landing point -- so its
	// Print should appear twice, plus the except clause's own print e.
	testing.expect_value(t, count_op(c, .Print), 3)
}

@(test)
test_emit_try_without_except_or_finally_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("try {\nraise \"x\"\n}\n", "test.lox", env)
	testing.expect(t, !ok)
}

// -----------------------------------------------------------------------
// try/finally *crossing* (implementation phase 6) -- return/break/
// continue whose target is outside an enclosing try. No equivalent
// existed in compile_test.odin (the old pipeline's trampoline design
// makes this hard to reach deliberately); these lock in the "N+1 finally
// copies for N crossing sites" behavior the plan doc's own try/finally
// section predicts.

@(test)
test_emit_return_crossing_finally_replays_it_a_third_time :: proc(t: ^testing.T) {
	c := compile_ok(t, `
func f() {
	try {
		return 1
	} finally {
		print "cleanup"
	}
}
`)
	fn_chunk := inner_function_chunk(t, c)
	// 2 structural copies (after Op_Finally, at the landing point) + 1 for
	// the crossing return -- landing point is emitted unconditionally even
	// though this body's only statement always returns.
	testing.expect_value(t, count_op(fn_chunk, .Print), 3)
	// 1 structural (post-body) + 1 from the crossing itself.
	testing.expect_value(t, count_op(fn_chunk, .End_Try), 2)
	testing.expect(t, contains_op(fn_chunk, .Get_Local)) // retval_slot reload after the finally replay
}

@(test)
test_emit_return_crossing_try_without_finally_only_end_try :: proc(t: ^testing.T) {
	c := compile_ok(t, `
func f() {
	try {
		return 1
	} except Exception as e {
		print e
	}
}
`)
	fn_chunk := inner_function_chunk(t, c)
	testing.expect_value(t, count_op(fn_chunk, .Print), 1) // just the except clause's own print e
	testing.expect_value(t, count_op(fn_chunk, .End_Try), 2) // 1 structural + 1 crossing, no finally to replay
}

@(test)
test_emit_break_crossing_finally_replays_it_a_third_time :: proc(t: ^testing.T) {
	c := compile_ok(t, `
func f() {
	while (true) {
		try {
			break
		} finally {
			print "cleanup"
		}
	}
}
`)
	fn_chunk := inner_function_chunk(t, c)
	testing.expect_value(t, count_op(fn_chunk, .Print), 3)
	testing.expect_value(t, count_op(fn_chunk, .End_Try), 2)
	// The break's own terminal jump, patched to the loop exit -- confirms
	// emit_try_crossings doesn't consume/replace it.
	testing.expect(t, contains_op(fn_chunk, .Jump))
}

@(test)
test_emit_continue_crossing_finally_replays_it_a_third_time :: proc(t: ^testing.T) {
	c := compile_ok(t, `
func f() {
	while (true) {
		try {
			continue
		} finally {
			print "cleanup"
		}
	}
}
`)
	fn_chunk := inner_function_chunk(t, c)
	testing.expect_value(t, count_op(fn_chunk, .Print), 3)
	testing.expect_value(t, count_op(fn_chunk, .End_Try), 2)
	// The while loop's own back-edge, plus continue's own back-edge.
	testing.expect_value(t, count_op(fn_chunk, .Loop), 2)
}

@(test)
test_emit_return_crossing_nested_trys_replays_both_finallys :: proc(t: ^testing.T) {
	c := compile_ok(t, `
func f() {
	try {
		try {
			return 1
		} finally {
			print "inner"
		}
	} finally {
		print "outer"
	}
}
`)
	fn_chunk := inner_function_chunk(t, c)
	// Each finally gets 2 structural copies + 1 crossing copy = 3 prints
	// each, 6 total; each try contributes 1 structural End_Try + 1
	// crossing End_Try = 4 total.
	testing.expect_value(t, count_op(fn_chunk, .Print), 6)
	testing.expect_value(t, count_op(fn_chunk, .End_Try), 4)
}

// -----------------------------------------------------------------------
// Peephole optimizer -- runs on the finished Chunk regardless of how it
// was generated, so this doubles as a check that Emit still produces the
// exact Get_Local/Get_Local/Add_Numeric/Set_Local/Pop shape the optimizer
// pattern-matches on.

@(test)
test_emit_peephole_fuses_local_increment :: proc(t: ^testing.T) {
	c := compile_ok(t, "func f() {\nvar a = 1\nvar b = 2\na = a + b\nreturn a\n}\n")
	fn_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(fn_chunk, .Add_Nn))
	testing.expect(t, !contains_op(fn_chunk, .Add_Numeric))
}

// docs/plans/vec-op-peephole.md's compiler-side coverage: `++` (Add_Vector)
// fuses into Add_Vv under the identical local-local-Set_Local-Pop shape
// Add_Nn already matches on, and (the negative case, which the numeric
// fusion has no equivalent test for today) leaves a non-local-operand
// `++` alone.
@(test)
test_emit_peephole_fuses_local_vector_add :: proc(t: ^testing.T) {
	c := compile_ok(t, "func f() {\nvar a = vec2(1, 1)\nvar b = vec2(2, 2)\na = a ++ b\nreturn a\n}\n")
	fn_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(fn_chunk, .Add_Vv))
	testing.expect(t, !contains_op(fn_chunk, .Add_Vector))
}

@(test)
test_emit_peephole_leaves_non_local_vector_add_unfused :: proc(t: ^testing.T) {
	c := compile_ok(t, "var a = vec2(1, 1)\nvar b = vec2(2, 2)\na = a ++ b\n")
	testing.expect(t, contains_op(c, .Add_Vector))
	testing.expect(t, !contains_op(c, .Add_Vv))
}

// -----------------------------------------------------------------------
// REPL global-slot continuity (implementation phase 7) -- same two
// regression tests compile_test.odin has for the old pipeline, run
// against Compile_Repl/Repl_State instead.

@(test)
test_emit_repl_second_line_reuses_first_lines_global_slot :: proc(t: ^testing.T) {
	env := core.make_environment("repl")
	st := make_repl_state(env)

	_, ok1 := Compile_Repl("var x = 1\n", &st)
	testing.expect(t, ok1)
	slot_after_line1 := st.globals["x"]

	fn2, ok2 := Compile_Repl("x = x + 1\n", &st)
	testing.expect(t, ok2)
	testing.expect_value(t, st.globals["x"], slot_after_line1)

	// Line 2 should read/write the *same* slot as line 1's declaration,
	// not treat `x` as a fresh, differently-numbered global.
	found := false
	for d in decode(fn2.chunk) {
		if d.op == .Get_Global && int(d.operands[0]) == slot_after_line1 {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
test_emit_repl_failed_line_does_not_corrupt_state :: proc(t: ^testing.T) {
	env := core.make_environment("repl")
	st := make_repl_state(env)

	_, ok1 := Compile_Repl("var x = 1\n", &st)
	testing.expect(t, ok1)
	count_before := st.global_count

	_, ok2 := Compile_Repl("var 1 = 2\n", &st) // syntax error
	testing.expect(t, !ok2)
	testing.expect_value(t, st.global_count, count_before)
}
