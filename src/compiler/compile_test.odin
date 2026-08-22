package compiler

import "../core"
import "core:testing"

// Compiler-level tests: compile real source and inspect the resulting
// Chunk's opcode sequence. There's no VM yet (Phase 4) to run any of
// this against, so these tests check *shape* -- which opcodes came out,
// in what order, with which operand where it matters -- the same way
// scanner_test.odin checks token-type shape rather than exact bytes.

// -----------------------------------------------------------------------
// Decoding helper: walks a Chunk's code one instruction at a time,
// skipping the right number of operand bytes per opcode (including the
// two variable-length ones, Closure and Import_From). Not the
// disassembler -- exists only so tests can assert "opcode X appears here"
// without hand-counting byte offsets or risking a false match against an
// unrelated operand byte.

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
		     .Static_Method, .Class_Var, .Get_Super:
			n = 1
		case .Jump_If_False, .Jump, .Loop, .Try, .End_Try, .Add_Nn,
		     .Incr_Const_N, .Sub_Nn, .Decr_Const_N, .Mul_Nn, .Mul_Const_N,
		     .Div_Nn, .Div_Const_N, .Super_Invoke, .Import, .Get_Property,
		     .Set_Local_Vec_Field, .Set_Global_Vec_Field, .Set_Upvalue_Vec_Field,
		     .Set_Property_Vec_Field, .Class, .Set_Field_Slot:
			// Get_Property: [name_const][cache_idx]; Set_*_Vec_Field:
			// [slot_or_const][swizzle_name_const] -- see expr.odin's
			// dot/emit_property_cache and emit_expr.odin's emit_swizzle_set.
			// Class: [name_const][field_slot_table_idx]. Set_Field_Slot:
			// [slot][name_const] -- see emit_expr.odin's emit_property.
			n = 2
		case .Invoke, .Get_Field_Slot:
			// Invoke: [name_const][arg_count][cache_idx] -- see expr.odin's
			// dot. Get_Field_Slot: [slot][name_const][cache_idx] -- see
			// emit_expr.odin's emit_property.
			n = 3
		case .Except:
			// [type_const][skip_hi][skip_lo] -- see stmt.odin's
			// try_except_statement and vm/exceptions.odin's header
			// comment for why Except carries its own skip offset.
			n = 3
		case .Jump_If_Defined:
			n = 3
		case .Foreach:
			n = 4
		case .Next:
			// [jump_hi][jump_lo][var_slot][iter_slot]
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
compile_ok :: proc(t: ^testing.T, source: string) -> ^core.Chunk {
	env := core.make_environment("test")
	fn, ok := Compile(source, "test.lox", env)
	testing.expectf(t, ok, "expected %q to compile without error", source)
	return fn.chunk
}

// -----------------------------------------------------------------------
// Smoke test: a program exercising most of the language surface this
// phase covers, compiling successfully end to end. This is the single
// most valuable test in this file -- it's what would have caught almost
// every one of the "undeclared name" / "field collision" / wrong-operand
// mistakes made while writing this compiler, if it had existed sooner.

@(test)
test_kitchen_sink_program_compiles :: proc(t: ^testing.T) {
	compile_ok(t, `
class Animal {
	__init__(name) {
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

// Regression test: print_statement must emit Op_Str before Op_Print --
// Op_Str is also the __str__() dispatch point (run.odin's Op_Str case),
// so skipping it meant `print instance` never picked up a class's own
// __str__() even though str(x) already routed through Op_Str correctly.
@(test)
test_print_statement_emits_str_before_print :: proc(t: ^testing.T) {
	c := compile_ok(t, "print 1\n")
	seq := op_sequence(c)
	testing.expect(t, len(seq) >= 2)
	str_idx := -1
	for op, i in seq {
		if op == .Str {
			str_idx = i
			break
		}
	}
	testing.expectf(t, str_idx >= 0, "expected Op_Str in %v", seq)
	if str_idx >= 0 {
		testing.expect_value(t, seq[str_idx + 1], core.Op_Code.Print)
	}
}

// -----------------------------------------------------------------------
// Expressions

@(test)
test_arithmetic_expression_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "1 + 2 * 3\n")
	seq := op_sequence(c)
	// Precedence: `2 * 3` binds tighter, so Multiply is emitted before
	// Add_Numeric even though `+` appears first in the source.
	testing.expect(t, len(seq) >= 5)
	testing.expect_value(t, seq[0], core.Op_Code.Constant)
	testing.expect_value(t, seq[1], core.Op_Code.Constant)
	testing.expect_value(t, seq[2], core.Op_Code.Constant)
	testing.expect_value(t, seq[3], core.Op_Code.Multiply)
	testing.expect_value(t, seq[4], core.Op_Code.Add_Numeric)
}

@(test)
test_comparison_operators_map_to_flip_plus_not :: proc(t: ^testing.T) {
	// `<=`/`>=`/`!=` have no opcode of their own -- each compiles as the
	// flipped strict comparison (or Equal) followed by Not.
	le := compile_ok(t, "1 <= 2\n")
	testing.expect(t, contains_op(le, .Greater))
	testing.expect(t, contains_op(le, .Not))

	ne := compile_ok(t, "1 != 2\n")
	testing.expect(t, contains_op(ne, .Equal))
	testing.expect(t, contains_op(ne, .Not))
}

@(test)
test_string_concat_uses_ampersand :: proc(t: ^testing.T) {
	c := compile_ok(t, `"a" & "b"` + "\n")
	testing.expect(t, contains_op(c, .Concat))
}

@(test)
test_vector_add_uses_plus_plus :: proc(t: ^testing.T) {
	c := compile_ok(t, "a ++ b\n")
	testing.expect(t, contains_op(c, .Add_Vector))
	testing.expect(t, !contains_op(c, .Add_Numeric))
}

// -----------------------------------------------------------------------
// Swizzle-component assignment write-back (`v.x = expr`) -- see
// emit_expr.odin's emit_swizzle_set. A top-level `var` resolves as a
// global, so this is the Global half of the family; the
// Local/Upvalue/Property halves are covered end-to-end in
// vm/builtins_test.odin instead, since they need the VM actually running.

@(test)
test_vec_swizzle_assign_uses_dedicated_opcode :: proc(t: ^testing.T) {
	c := compile_ok(t, "var v = vec2(1, 2)\nv.x = 5\n")
	testing.expect(t, contains_op(c, .Set_Global_Vec_Field))
	testing.expect(t, !contains_op(c, .Set_Property))
}

@(test)
test_vec_swizzle_assign_through_index_is_compile_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("var v = [vec2(1, 2)]\nv[0].x = 5\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_vec_swizzle_assign_through_call_result_is_compile_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("func get_v() { return vec2(1, 2) }\nget_v().x = 5\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_vec_swizzle_compound_assign_uses_dedicated_opcode :: proc(t: ^testing.T) {
	c := compile_ok(t, "var v = vec2(1, 2)\nv.x += 5\n")
	testing.expect(t, contains_op(c, .Set_Global_Vec_Field))
	testing.expect(t, !contains_op(c, .Set_Property))
}

@(test)
test_unary_negate_and_not :: proc(t: ^testing.T) {
	c := compile_ok(t, "-x\n")
	testing.expect(t, contains_op(c, .Negate))

	c2 := compile_ok(t, "!x\n")
	testing.expect(t, contains_op(c2, .Not))
}

@(test)
test_ternary_conditional_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "x ? 1 : 2\n")
	testing.expect_value(t, count_op(c, .Jump_If_False), 1)
	testing.expect_value(t, count_op(c, .Jump), 1)
	// 2 from conditional() itself (discarding the condition value on
	// whichever branch is taken) + 1 more from expression_statement's
	// own wrapper (discarding the ternary's own unused result, since
	// this whole expression is used as a bare statement here).
	testing.expect_value(t, count_op(c, .Pop), 3)
}

@(test)
test_and_or_short_circuit_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "x and y\n")
	testing.expect_value(t, count_op(c, .Jump_If_False), 1)

	c2 := compile_ok(t, "x or y\n")
	testing.expect_value(t, count_op(c2, .Jump_If_False), 1)
	testing.expect_value(t, count_op(c2, .Jump), 1)
}

@(test)
test_str_call_emits_str_opcode :: proc(t: ^testing.T) {
	c := compile_ok(t, "str(x)\n")
	testing.expect(t, contains_op(c, .Str))
}

@(test)
test_list_dict_tuple_literals :: proc(t: ^testing.T) {
	l := compile_ok(t, "[1, 2, 3]\n")
	testing.expect(t, contains_op(l, .Create_List))

	// A bare `{` at statement position is always a block (same
	// resolution most brace-delimited languages use for this
	// ambiguity), not a dict literal -- so this needs to appear on the
	// right-hand side of something to actually exercise dict_literal.
	d := compile_ok(t, `var d = {"a": 1}` + "\n")
	testing.expect(t, contains_op(d, .Create_Dict))

	tup := compile_ok(t, "(1, 2)\n")
	testing.expect(t, contains_op(tup, .Create_Tuple))
}

@(test)
test_index_and_slice :: proc(t: ^testing.T) {
	idx := compile_ok(t, "x[0]\n")
	testing.expect(t, contains_op(idx, .Index))
	testing.expect(t, !contains_op(idx, .Slice))

	sl := compile_ok(t, "x[1:2]\n")
	testing.expect(t, contains_op(sl, .Slice))

	open_sl := compile_ok(t, "x[:]\n")
	testing.expect(t, contains_op(open_sl, .Slice))
}

@(test)
test_compound_assignment_desugars_no_dedicated_opcode :: proc(t: ^testing.T) {
	// `x` here is a global (top-level `var`), so this exercises
	// Get_Global/Set_Global, not Get_Local/Set_Local -- the peephole
	// optimizer only fuses local-slot sequences, so this shape is never a
	// fusion candidate, sidestepping DebugSkipPeephole's race against other
	// tests under Odin's parallel test runner.
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
// Declarations: local vs. global

@(test)
test_global_var_declaration_emits_define_global :: proc(t: ^testing.T) {
	c := compile_ok(t, "var x = 5\n")
	testing.expect(t, contains_op(c, .Define_Global))
}

@(test)
test_local_var_declaration_has_no_define_global :: proc(t: ^testing.T) {
	// A local's initializer value already sits in the right stack slot
	// by construction -- no explicit store opcode, unlike a global.
	// (Semicolon between statements: there's no newline token at all
	// between `5` and `return` on one physical line, and only a `}`
	// counts as an implicit terminator -- not an arbitrary following
	// keyword -- so these two statements need an explicit separator.)
	c := compile_ok(t, "func f() { var x = 5; return x }\n")
	// The function body compiled into a nested Function_Object stored as
	// a chunk constant; walk into it via the Closure operand.
	fn_chunk := inner_function_chunk(t, c)
	testing.expect(t, !contains_op(fn_chunk, .Define_Global))
	testing.expect(t, contains_op(fn_chunk, .Get_Local)) // `return x`
}

@(test)
test_const_declaration_uses_define_global_const :: proc(t: ^testing.T) {
	c := compile_ok(t, "const X = 1\n")
	testing.expect(t, contains_op(c, .Define_Global_Const))
	testing.expect(t, !contains_op(c, .Define_Global))
}

@(test)
test_const_without_initializer_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("const X\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_implicit_global_declaration :: proc(t: ^testing.T) {
	// Bare `x = 5` for a name never declared with var/const still
	// creates the binding (Python/JS-style), rather than compiling to a
	// Set_Global that would fail at runtime as "undefined variable".
	c := compile_ok(t, "x = 5\n")
	testing.expect(t, contains_op(c, .Define_Global))
}

@(test)
test_destructuring_assignment_global :: proc(t: ^testing.T) {
	c := compile_ok(t, "a, b = 1, 2\n")
	testing.expect(t, contains_op(c, .Unpack))
	testing.expect_value(t, count_op(c, .Define_Global), 2)
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

// -----------------------------------------------------------------------
// Control flow

@(test)
test_if_else_jump_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "if x { print 1 } else { print 2 }\n")
	testing.expect_value(t, count_op(c, .Jump_If_False), 1)
	testing.expect_value(t, count_op(c, .Jump), 1)
	testing.expect_value(t, count_op(c, .Print), 2)
}

@(test)
test_while_loop_has_back_edge :: proc(t: ^testing.T) {
	c := compile_ok(t, "while x { print 1 }\n")
	testing.expect(t, contains_op(c, .Loop))
	testing.expect_value(t, count_op(c, .Jump_If_False), 1)
}

@(test)
test_break_and_continue_in_loop :: proc(t: ^testing.T) {
	c := compile_ok(t, "while x { if y { break } if z { continue } }\n")
	// break -> Jump (patched to loop exit); continue -> Loop (back-edge).
	testing.expect_value(t, count_op(c, .Loop), 2) // 1 real back-edge + 1 from `continue`
}

@(test)
test_break_outside_loop_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("break\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_foreach_emits_iterator_trio :: proc(t: ^testing.T) {
	c := compile_ok(t, "foreach x in items { print x }\n")
	testing.expect(t, contains_op(c, .Foreach))
	testing.expect(t, contains_op(c, .Next))
	testing.expect(t, contains_op(c, .End_Foreach))
}

// -----------------------------------------------------------------------
// Parenthesized control-flow headers and unbraced bodies. The reference
// implementation requires the parens unconditionally; this port makes
// them optional instead, to support parenthesized fixtures without
// breaking the bare style existing tests rely on.

@(test)
test_if_accepts_optional_parens_both_forms :: proc(t: ^testing.T) {
	bare := compile_ok(t, "if x { print 1 }\n")
	testing.expect_value(t, count_op(bare, .Jump_If_False), 1)

	paren := compile_ok(t, "if (x) { print 1 }\n")
	testing.expect_value(t, count_op(paren, .Jump_If_False), 1)
}

@(test)
test_if_body_can_be_unbraced_single_statement :: proc(t: ^testing.T) {
	// Regression test: `if (cond) break`/`if (n < 2) return n` (both real
	// ported-suite fixtures) couldn't even compile before -- if_statement
	// hard-required a `{` after the condition. contains_op(.Return) here
	// confirms the bare `return n` after the condition was actually
	// parsed as the if's body, not left dangling as a syntax error.
	c := compile_ok(t, "func f(n) {\n\tif (n < 2) return n\n\treturn 0\n}\n")
	fc := inner_function_chunk(t, c)
	// 2 explicit returns (the if's unbraced body, and the trailing one)
	// + 1 implicit one end_compiler always appends after every function
	// body regardless of whether the last statement already returned.
	testing.expect_value(t, count_op(fc, .Return), 3)
}

@(test)
test_else_if_chains_through_generic_statement_dispatch :: proc(t: ^testing.T) {
	// Regression test for the simplification in if_statement: `else`
	// now just calls statement(p) generically (which itself dispatches
	// back into if_statement for a following `if`) instead of a
	// hand-rolled `match(p, .If) { if_statement(p) } else { ...brace-only... }`
	// special case. Three chained else-if branches should still
	// produce three conditional jumps.
	c := compile_ok(t, "if a { print 1 } else if b { print 2 } else if c { print 3 } else { print 4 }\n")
	testing.expect_value(t, count_op(c, .Jump_If_False), 3)
}

@(test)
test_while_accepts_optional_parens :: proc(t: ^testing.T) {
	bare := compile_ok(t, "while x { print 1 }\n")
	paren := compile_ok(t, "while (x) { print 1 }\n")
	testing.expect(t, contains_op(bare, .Loop))
	testing.expect(t, contains_op(paren, .Loop))
}

@(test)
test_for_accepts_optional_parens_both_forms :: proc(t: ^testing.T) {
	bare := compile_ok(t, "for var i = 0; i < 3; i = i + 1 { print i }\n")
	paren := compile_ok(t, "for (var i = 0; i < 3; i = i + 1) { print i }\n")
	testing.expect(t, contains_op(bare, .Loop))
	testing.expect(t, contains_op(paren, .Loop))
}

@(test)
test_for_with_parens_and_no_increment :: proc(t: ^testing.T) {
	// Exercises has_increment's paren-aware branch specifically: with
	// parens, "no increment clause" is signalled by `)` immediately
	// following the condition's `;`, not by `{` (the bare-form signal) --
	// getting this wrong would either skip a real increment or treat the
	// body's own `{` as if it were an increment expression.
	c := compile_ok(t, "for (var i = 0; i < 3;) { print i }\n")
	testing.expect(t, contains_op(c, .Loop))
}

@(test)
test_foreach_accepts_optional_parens_and_var_keyword :: proc(t: ^testing.T) {
	forms := []string{
		"foreach x in items { print x }\n",
		"foreach (x in items) { print x }\n",
		"foreach var x in items { print x }\n",
		"foreach (var x in items) { print x }\n",
	}
	for src in forms {
		c := compile_ok(t, src)
		testing.expectf(t, contains_op(c, .Foreach), "expected %q to emit Foreach", src)
	}
}

@(test)
test_return_outside_function_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("return 1\n", "test.lox", env)
	testing.expect(t, !ok)
}

// -----------------------------------------------------------------------
// Functions: defaults, variadics, closures

@(test)
test_default_parameter_emits_jump_if_defined :: proc(t: ^testing.T) {
	c := compile_ok(t, "func f(a, b=1) { return a + b }\n")
	fn_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(fn_chunk, .Jump_If_Defined))
}

@(test)
test_non_default_after_default_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("func f(a=1, b) { return a }\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_closure_captures_upvalue :: proc(t: ^testing.T) {
	c := compile_ok(t, `
func outer() {
	var x = 1
	return func() { return x }
}
`)
	outer_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(outer_chunk, .Closure))
	// The inner closure's own body reads x as an upvalue, not a local.
	inner_chunk := inner_function_chunk(t, outer_chunk)
	testing.expect(t, contains_op(inner_chunk, .Get_Upvalue))
}

@(test)
test_lambda_expression_compiles :: proc(t: ^testing.T) {
	c := compile_ok(t, "var f = func(x) { return x }\n")
	testing.expect(t, contains_op(c, .Closure))
}

// -----------------------------------------------------------------------
// Classes

@(test)
test_class_declaration_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, `
class Point {
	__init__(x, y) {
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

// Regression test for a real bug found via the ported pytest suite
// (tests/new_tests/lox/str_class_dunder_str.lox writes exactly this
// shape): the reference implementation's own parser explicitly tolerates an Eol between a
// method's `)` and its `{` (compile.go: `p.match(TOKEN_EOL) // allow
// EOL after parameters`) -- this port initially didn't, so any method
// written with its opening brace on its own line failed to compile.
@(test)
test_method_brace_on_next_line_compiles :: proc(t: ^testing.T) {
	c := compile_ok(t, "class A {\n\tgreet()\n\t{\n\t\treturn 1\n\t}\n}\n")
	testing.expect(t, contains_op(c, .Method))
}

// Regression test: class_declaration's member loop had no
// panic_mode/synchronize check of its own, so a malformed method whose
// error path returned without consuming a token made the loop call
// method() again on the same token forever, hanging the compiler. If this
// regresses, this test itself hangs rather than failing cleanly -- an
// acceptable trade-off for pinning down an infinite loop specifically.
@(test)
test_malformed_method_does_not_hang_the_compiler :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("class A {\n\tgreet(\n\t{\n\t\treturn 1\n\t}\n}\nprint A\n", "test.lox", env)
	testing.expect(t, !ok)
}

@(test)
test_class_inheritance_emits_inherit_and_super :: proc(t: ^testing.T) {
	c := compile_ok(t, `
class A { greet() { return "a" } }
class B < A { greet() { return super.greet() } }
`)
	testing.expect(t, contains_op(c, .Inherit))
	b_method_chunk := inner_function_chunk(t, c) // A.greet is compiled first...
	// Walk both classes' methods for Get_Super/Super_Invoke rather than
	// assuming which constant is which.
	found_super := false
	for v in c.constants {
		if v.type == .Obj && v.obj_type == .Function {
			fc := core.as_function(v).chunk
			if contains_op(fc, .Get_Super) || contains_op(fc, .Super_Invoke) {
				found_super = true
			}
		}
	}
	_ = b_method_chunk
	testing.expect(t, found_super)
}

@(test)
test_self_inheritance_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("class A < A {}\n", "test.lox", env)
	testing.expect(t, !ok)
}

// -----------------------------------------------------------------------
// Exceptions

@(test)
test_try_except_finally_shape :: proc(t: ^testing.T) {
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
	// Finally's body is compiled twice (see stmt.odin's try_except_statement) --
	// once after Op_Finally, once at the shared landing point -- so its
	// Print should appear twice.
	testing.expect_value(t, count_op(c, .Print), 3) // "done" x2 + the except clause's `print e`
}

@(test)
test_try_without_except_or_finally_is_error :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("try { print 1 }\n", "test.lox", env)
	testing.expect(t, !ok)
}

// -----------------------------------------------------------------------
// Imports

@(test)
test_import_shape :: proc(t: ^testing.T) {
	c := compile_ok(t, "import sys\n")
	testing.expect(t, contains_op(c, .Import))
}

@(test)
test_from_import_named :: proc(t: ^testing.T) {
	c := compile_ok(t, "from math import sqrt, pow\n")
	testing.expect(t, contains_op(c, .Import_From))
}

@(test)
test_from_import_star :: proc(t: ^testing.T) {
	c := compile_ok(t, "from math import *\n")
	testing.expect(t, contains_op(c, .Import_From))
}

// -----------------------------------------------------------------------
// Peephole optimizer

// Both the default-enabled and explicitly-disabled peephole behaviors are
// checked in one test function rather than two: DebugSkipPeephole is a
// package-level flag that end_compiler snapshots into each Parser's own
// skip_peephole field at construction time, so two separate test
// functions each toggling that global could race under Odin's parallel
// test runner. Keeping both checks sequential removes that risk.
@(test)
test_peephole_enabled_by_default_and_disabled_by_flag :: proc(t: ^testing.T) {
	source := "func f(a, b) { a = a + b }\n"

	enabled := compile_ok(t, source)
	enabled_chunk := inner_function_chunk(t, enabled)
	testing.expect(t, contains_op(enabled_chunk, .Add_Nn))
	testing.expect(t, !contains_op(enabled_chunk, .Add_Numeric))

	DebugSkipPeephole = true
	disabled := compile_ok(t, source)
	DebugSkipPeephole = false
	disabled_chunk := inner_function_chunk(t, disabled)
	testing.expect(t, contains_op(disabled_chunk, .Add_Numeric))
	testing.expect(t, !contains_op(disabled_chunk, .Add_Nn))
}

// -----------------------------------------------------------------------
// Compile-time-baked instance field slots (resolve.odin's
// discover_field_slots) -- see TODO.md's Phase 7 entry.

@(test)
test_field_slot_get_set_compiles :: proc(t: ^testing.T) {
	c := compile_ok(t, "class P {\n__init__(count) {\nthis.count = count\n}\nbump() {\nthis.count = this.count + 1\n}\n}\n")
	init_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(init_chunk, .Set_Field_Slot), "expected this.count = count in init to compile to Set_Field_Slot")
	testing.expect(t, !contains_op(init_chunk, .Set_Property), "unslotted Set_Property must not also appear for the same assignment")

	bump_chunk: ^core.Chunk
	for v in c.constants {
		if v.type == .Obj && v.obj_type == .Function && core.as_function(v).chunk != init_chunk {
			bump_chunk = core.as_function(v).chunk
		}
	}
	testing.expect(t, bump_chunk != nil, "expected to find bump()'s own chunk")
	testing.expect(t, contains_op(bump_chunk, .Get_Field_Slot), "expected this.count read in bump() to compile to Get_Field_Slot")
	testing.expect(t, contains_op(bump_chunk, .Set_Field_Slot), "expected this.count = ... write in bump() to compile to Set_Field_Slot")
	testing.expect(t, !contains_op(bump_chunk, .Get_Property))
	testing.expect(t, !contains_op(bump_chunk, .Set_Property))
}

@(test)
test_field_slot_conditional_field_keeps_ordinary_property_ops :: proc(t: ^testing.T) {
	c := compile_ok(t, "class P {\n__init__(flag) {\nif (flag) {\nthis.maybe = 1\n}\n}\n}\n")
	init_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(init_chunk, .Set_Property), "a conditionally-assigned field must keep compiling through the ordinary Set_Property path")
	testing.expect(t, !contains_op(init_chunk, .Set_Field_Slot))
}

@(test)
test_field_slot_this_invoke_keeps_ordinary_invoke_op :: proc(t: ^testing.T) {
	c := compile_ok(t, "class P {\n__init__(fn) {\nthis.cb = fn\n}\nrun() {\nreturn this.cb()\n}\n}\n")
	init_chunk := inner_function_chunk(t, c)
	testing.expect(t, contains_op(init_chunk, .Set_Field_Slot), "\"cb\" should still be discovered and slot-optimized for its own assignment")

	run_chunk: ^core.Chunk
	for v in c.constants {
		if v.type == .Obj && v.obj_type == .Function && core.as_function(v).chunk != init_chunk {
			run_chunk = core.as_function(v).chunk
		}
	}
	testing.expect(t, run_chunk != nil, "expected to find run()'s own chunk")
	testing.expect(t, contains_op(run_chunk, .Invoke), "this.cb() must keep compiling to the ordinary Invoke opcode")
	testing.expect(t, !contains_op(run_chunk, .Get_Field_Slot), "this.cb() must never compile to Get_Field_Slot even though \"cb\" is itself slot-optimized")
}

// -----------------------------------------------------------------------
// REPL cross-line state

@(test)
test_repl_second_line_reuses_first_lines_global_slot :: proc(t: ^testing.T) {
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
test_repl_failed_line_does_not_corrupt_state :: proc(t: ^testing.T) {
	env := core.make_environment("repl")
	st := make_repl_state(env)

	_, ok1 := Compile_Repl("var x = 1\n", &st)
	testing.expect(t, ok1)
	count_before := st.global_count

	_, ok2 := Compile_Repl("var 1 = 2\n", &st) // syntax error
	testing.expect(t, !ok2)
	testing.expect_value(t, st.global_count, count_before)
}

// -----------------------------------------------------------------------
// Error recovery

@(test)
test_syntax_error_does_not_crash_compiler :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	_, ok := Compile("var = = =\nprint 1\n", "test.lox", env)
	testing.expect(t, !ok) // just must not panic; a wrong-but-recovered parse is fine
}

// -----------------------------------------------------------------------
// --strict-types (optional type annotations): the same optional-type
// diagnostic that's a warning by default becomes a hard
// compile failure under StrictTypes. StrictTypes is a package-level var
// (see compile.odin, same pattern as DebugSkipPeephole) -- every check
// below happens inside one test function rather than several, the same
// reasoning test_peephole_enabled_by_default_and_disabled_by_flag already
// documents for DebugSkipPeephole: two separate test functions each
// saving/restoring the global could still race against each other (and
// against any other test calling Compile while the toggle is briefly
// live) under Odin's parallel test runner. Keeping every check
// sequential in one function removes that risk entirely.
@(test)
test_strict_types_enforcement :: proc(t: ^testing.T) {
	bad_source := "func add(x: int, y: int) -> int {\nreturn x + y\n}\nadd(1, \"two\")\n"
	clean_source := "func add(x: int, y: int) -> int {\nreturn x + y\n}\nprint add(1, 2)\n"

	// Default: the bad call is a warning, compile still succeeds.
	env := core.make_environment("test")
	_, ok := Compile(bad_source, "test.lox", env)
	testing.expect(t, ok, "expected the default (warnings-only) mode to still compile")

	StrictTypes = true

	env2 := core.make_environment("test")
	_, ok2 := Compile(bad_source, "test.lox", env2)
	testing.expect(t, !ok2, "expected --strict-types to fail the compile on the same diagnostic")

	env3 := core.make_environment("test")
	_, ok3 := Compile(clean_source, "test.lox", env3)
	testing.expect(t, ok3, "expected --strict-types to be a no-op on a program with zero diagnostics")

	repl_env := core.make_environment("repl")
	st := make_repl_state(repl_env)
	_, ok4 := Compile_Repl(bad_source, &st)
	testing.expect(t, !ok4, "expected --strict-types to fail the compile in the REPL too")

	StrictTypes = false
}
