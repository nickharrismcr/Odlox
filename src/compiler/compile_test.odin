package compiler

import "../core"
import "core:testing"

// Compiler-level tests: compile real source and inspect the resulting
// Chunk's opcode sequence. There's no VM yet (Phase 4) to run any of
// this against, so these tests check *shape* -- which opcodes came out,
// in what order, with which operand where it matters -- the same way
// scanner_test.odin checks token-type shape rather than exact bytes.

// -----------------------------------------------------------------------
// Decoding helper: walks a Chunk's code, one instruction at a time,
// skipping the right number of operand bytes per opcode (including the
// two variable-length ones, Closure and Import_From, which need to
// consult the constant pool / a count byte respectively to know their
// own width). This is deliberately *not* Phase 5's disassembler -- it
// exists only so these tests can assert "opcode X appears here" without
// either hand-counting byte offsets everywhere or risking a false match
// against some unrelated instruction's operand byte that happens to
// equal X's numeric value.

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
		     .Create_Tuple, .Unpack, .Get_Property, .Set_Property, .Method,
		     .Static_Method, .Class_Var, .Get_Super, .Class:
			n = 1
		case .Jump_If_False, .Jump, .Loop, .Try, .End_Try, .Add_Nn,
		     .Incr_Const_N, .Invoke, .Super_Invoke, .Import:
			n = 2
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

// Regression test: print_statement must emit Op_Str before Op_Print --
// Op_Str is also the toString() dispatch point (run.odin's Op_Str
// case), so skipping it (an earlier version did) meant `print instance`
// never picked up a class's own toString() even after toString
// dispatch was wired up in Op_Str itself, since print never routed
// through that opcode at all. str(x) (expr.odin's str_call, a
// different call site) already emitted Op_Str correctly, which is
// exactly what made this easy to miss -- str(x) "worked" while print
// x on the same value silently didn't.
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
	// `x` here is a *global* (top-level `var`), so this exercises
	// Get_Global/Set_Global, not Get_Local/Set_Local -- the peephole
	// optimizer only ever fuses local-slot sequences (see
	// peephole_optimise's own doc comment), so this shape is never a
	// fusion candidate regardless of DebugSkipPeephole, deliberately
	// sidestepping that flag's race against other tests under Odin's
	// parallel test runner (test_peephole_disabled_by_flag toggles it
	// too, and both can run concurrently).
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
// Parenthesized control-flow headers and unbraced bodies (glox's real
// grammar requires the parens unconditionally -- see stmt.odin's
// parse_condition doc comment; this port makes them optional instead,
// to add the parenthesized fixtures the ported test suite actually
// uses without breaking the bare style every existing test already
// relies on). One shape test per statement kind, both forms, plus the
// unbraced-body case parens make possible.

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

// Regression test for a real bug found via the ported pytest suite
// (tests/new_tests/lox/str_class_toString.lox writes exactly this
// shape): glox's own parser explicitly tolerates an Eol between a
// method's `)` and its `{` (compile.go: `p.match(TOKEN_EOL) // allow
// EOL after parameters`) -- this port initially didn't, so any method
// written with its opening brace on its own line failed to compile.
@(test)
test_method_brace_on_next_line_compiles :: proc(t: ^testing.T) {
	c := compile_ok(t, "class A {\n\tgreet()\n\t{\n\t\treturn 1\n\t}\n}\n")
	testing.expect(t, contains_op(c, .Method))
}

// Regression test for the bug that made the missing tolerance above
// far worse than a wrong-but-quick compile error: class_declaration's
// member loop had no panic_mode/synchronize check of its own (unlike
// declaration() at the top level), so a malformed method whose error
// path returned without consuming a token made the loop call method()
// again on the exact same token forever. Before both fixes (this one
// and functions.odin's Eol tolerance), this exact input hung the
// compiler indefinitely rather than reporting a compile error -- a
// real, reproduced hang in the compiled odlox binary, not a
// hypothetical. If this regresses, this test itself will hang
// `odin test src/compiler` rather than failing cleanly; that's an
// acceptable trade-off for pinning down an infinite loop specifically
// (a timeout-based test would only prove "eventually terminates",
// which isn't what an infinite loop bug threatens).
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

// Both the default-enabled and explicitly-disabled peephole behaviors
// are checked in one test function (rather than two separate @(test)
// procs) deliberately: DebugSkipPeephole is a package-level flag
// (mirroring glox's own core.DebugSkipPeephole -- a real CLI-flag-backed
// toggle, not just a test convenience) that end_compiler snapshots into
// each Parser's own skip_peephole field at construction time (see
// parser.odin), specifically so one compile's behavior can't be
// affected by another compile concurrently flipping the *global* --
// but two separate test functions each toggling that same global around
// their own compile_ok call could still race against each other under
// Odin's parallel test runner (each sees a consistent snapshot for its
// own compile, but which value that snapshot holds isn't guaranteed if
// both tests' set/defer-reset windows overlap in time). Keeping both
// checks sequential inside one test function removes that risk instead
// of just documenting it.
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
