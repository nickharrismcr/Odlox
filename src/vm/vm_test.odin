package vm

import "../core"
import "core:strings"
import "core:testing"

// End-to-end VM tests: compile and *run* real source, then inspect the
// resulting state. Unlike compile_test.odin (which only checks bytecode
// shape, since no VM existed yet), these are what actually caught every
// real bug found while building this phase -- see ROADMAP.md's Phase 4
// section for the list. A top-level script's own "return value" is
// always nil by construction (end_compiler always emits Nil+Return for
// Function_Type.Script -- see compiler/compiler_state.odin), so these
// tests bind a computed value to a global and inspect that directly
// rather than relying on Interpret's returned result string.

@(private = "file")
run_and_get_global :: proc(t: ^testing.T, source: string, var_name: string) -> core.Value {
	vm_instance := new_vm("test")
	status, _ := interpret(vm_instance, source)
	testing.expectf(t, status == .Ok, "expected %q to run without error, got %v: %s", source, status, vm_instance.error_msg)
	if status != .Ok {
		// testing.expect* records a failure but doesn't abort the test
		// proc (unlike a fatal assertion) -- bail out here rather than
		// fall through to indexing environment.globals, which
		// env_grow_globals never sized on a failed compile (interpret()
		// returns before reaching that call), even though
		// env_slot_for_name can still report a slot that got recorded
		// during the *successful* part of a partially-compiled script.
		// Found via exactly that: a bad test source crashed with an
		// out-of-range panic instead of just failing the assertion.
		return core.NIL_VALUE
	}
	slot := core.env_slot_for_name(vm_instance.environment, var_name)
	testing.expectf(t, slot >= 0, "expected a global named %q", var_name)
	if slot < 0 || slot >= len(vm_instance.environment.globals) {
		return core.NIL_VALUE
	}
	return vm_instance.environment.globals[slot]
}

@(private = "file")
expect_runtime_error :: proc(t: ^testing.T, source: string) {
	vm_instance := new_vm("test")
	status, _ := interpret(vm_instance, source)
	testing.expectf(t, status == .Runtime_Error, "expected %q to raise a runtime error, got %v", source, status)
}

// -----------------------------------------------------------------------
// Arithmetic, comparisons, strings

@(test)
test_arithmetic_precedence :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var result = 1 + 2 * 3\n", "result")
	testing.expect_value(t, core.as_int(v), 7)
}

@(test)
test_int_float_mixed_add_produces_float :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var result = 1 + 2.5\n", "result")
	testing.expect(t, core.is_float(v))
	testing.expect_value(t, core.as_float(v), 3.5)
}

@(test)
test_division_by_zero_is_runtime_error :: proc(t: ^testing.T) {
	expect_runtime_error(t, "var x = 1 / 0\n")
}

@(test)
test_string_concat :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `var result = "foo" & "bar"` + "\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "foobar")
}

@(test)
test_string_comparison_and_indexing :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `var result = "abc" < "abd"` + "\n", "result")
	testing.expect_value(t, core.as_bool(v), true)

	v2 := run_and_get_global(t, `var s = "hello"` + "\nvar result = s[1:3]\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v2)), "el")
}

@(test)
test_str_builtin_stringifies :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var result = str(42)\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "42")
}

// toString() dispatch (run.odin's Op_Str case). str(instance) and
// print instance both go through Op_Str, so both should pick up a
// class's own toString() rather than falling back to the generic
// "<instance ClassName>" -- print's own path was a real, separate bug
// (print_statement never emitted Op_Str at all before this, only
// str(x) did -- see stmt.odin's print_statement), covered by the
// second test below.
@(test)
test_to_string_dispatch_via_str_builtin :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
class Point {
	init(x, y) { this.x = x; this.y = y }
	toString() { return "(" & str(this.x) & ", " & str(this.y) & ")" }
}
var result = str(Point(1, 2))
`, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "(1, 2)")
}

@(test)
test_instance_without_to_string_uses_generic_fallback :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
class Plain {
	init() { this.x = 1 }
}
var result = str(Plain())
`, "result")
	testing.expect(t, strings.has_prefix(core.string_get(core.as_string(v)), "<instance"))
}

// -----------------------------------------------------------------------
// Control flow

@(test)
test_if_else_branches :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var x = 5\nvar result = 0\nif x > 3 { result = 1 } else { result = 2 }\n", "result")
	testing.expect_value(t, core.as_int(v), 1)
}

@(test)
test_while_loop_accumulates :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var i = 0\nvar result = 0\nwhile i < 5 { result = result + i; i = i + 1 }\n", "result")
	testing.expect_value(t, core.as_int(v), 10) // 0+1+2+3+4
}

@(test)
test_for_loop_with_break_and_continue :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
var result = 0
for var i = 0; i < 10; i = i + 1 {
	if i == 5 { break }
	if i == 2 { continue }
	result = result + i
}
`, "result")
	testing.expect_value(t, core.as_int(v), 8) // 0+1+3+4 (2 skipped, stops before 5)
}

@(test)
test_ternary_conditional :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var x = 7\nvar result = x > 5 ? \"big\" : \"small\"\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "big")
}

// -----------------------------------------------------------------------
// Functions: closures, recursion, defaults, variadics

@(test)
test_closure_captures_and_mutates_upvalue :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
func make_counter() {
	var n = 0
	return func() {
		n = n + 1
		return n
	}
}
var c = make_counter()
c()
c()
var result = c()
`, "result")
	testing.expect_value(t, core.as_int(v), 3)
}

@(test)
test_recursion :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
func fib(n) {
	if n < 2 { return n }
	return fib(n - 1) + fib(n - 2)
}
var result = fib(10)
`, "result")
	testing.expect_value(t, core.as_int(v), 55)
}

@(test)
test_default_parameters :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "func f(a, b=10) { return a + b }\nvar result = f(1)\n", "result")
	testing.expect_value(t, core.as_int(v), 11)

	v2 := run_and_get_global(t, "func f(a, b=10) { return a + b }\nvar result = f(1, 2)\n", "result")
	testing.expect_value(t, core.as_int(v2), 3)
}

@(test)
test_variadic_parameters :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
func total(*xs) {
	var sum = 0
	foreach x in xs { sum = sum + x }
	return sum
}
var result = total(1, 2, 3, 4)
`, "result")
	testing.expect_value(t, core.as_int(v), 10)
}

@(test)
test_wrong_argument_count_is_runtime_error :: proc(t: ^testing.T) {
	expect_runtime_error(t, "func f(a, b) { return a + b }\nf(1)\n")
}

@(test)
test_lambda_expression :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var f = func(x) { return x * 2 }\nvar result = f(21)\n", "result")
	testing.expect_value(t, core.as_int(v), 42)
}

// -----------------------------------------------------------------------
// Classes

@(test)
test_instance_field_and_method :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
class Point {
	init(x, y) {
		this.x = x
		this.y = y
	}
	sum() {
		return this.x + this.y
	}
}
var result = Point(3, 4).sum()
`, "result")
	testing.expect_value(t, core.as_int(v), 7)
}

@(test)
test_inheritance_and_super :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
class Animal {
	speak() { return "..." }
}
class Dog < Animal {
	speak() { return super.speak() & "woof" }
}
var result = Dog().speak()
`, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "...woof")
}

@(test)
test_static_method_and_class_var :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
class Counter {
	static total = 0
	static make() {
		return "made"
	}
}
var result = Counter.make()
`, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "made")
}

// -----------------------------------------------------------------------
// Collections

@(test)
test_list_append_and_index :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var l = [1, 2, 3]\nl.append(4)\nvar result = l[3]\n", "result")
	testing.expect_value(t, core.as_int(v), 4)
}

@(test)
test_list_index_assign :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var l = [1, 2, 3]\nl[1] = 99\nvar result = l[1]\n", "result")
	testing.expect_value(t, core.as_int(v), 99)
}

@(test)
test_dict_get_and_set :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `var d = {"a": 1}` + "\nvar result = d.get(\"a\", 0)\n", "result")
	testing.expect_value(t, core.as_int(v), 1)
}

@(test)
test_destructuring_assignment :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "a, b = 1, 2\nvar result = a + b\n", "result")
	testing.expect_value(t, core.as_int(v), 3)
}

@(test)
test_list_out_of_range_is_runtime_error :: proc(t: ^testing.T) {
	expect_runtime_error(t, "var l = [1]\nvar x = l[5]\n")
}

// -----------------------------------------------------------------------
// Foreach

@(test)
test_foreach_over_list_sums :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var result = 0\nforeach x in [1, 2, 3, 4] { result = result + x }\n", "result")
	testing.expect_value(t, core.as_int(v), 10)
}

@(test)
test_foreach_over_string_counts_chars :: proc(t: ^testing.T) {
	v := run_and_get_global(t, "var result = 0\nforeach c in \"hello\" { result = result + 1 }\n", "result")
	testing.expect_value(t, core.as_int(v), 5)
}

// -----------------------------------------------------------------------
// User-level iterator protocol (__iter__/__next__ -- foreach.odin).
// Needs a nested run(vm, .Current_Function) call to invoke each method
// synchronously mid-opcode (unlike Op_Str's toString dispatch, which
// doesn't -- see foreach.odin's call_closure_now doc comment for why
// the two cases differ). Deferred out of Phase 4's scope originally;
// picked up once the native iterable path (list/string/range, tested
// above) had real coverage to build the nested-call path against.

@(test)
test_foreach_over_class_with_iter_protocol :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
class Range {
	init(n) { this.n = n }
	__iter__() { return RangeIterator(this.n) }
}
class RangeIterator {
	init(n) { this.n = n; this.i = 0 }
	__next__() {
		if this.i >= this.n { return nil }
		var v = this.i
		this.i = this.i + 1
		return v
	}
}
var result = 0
foreach x in Range(5) {
	result = result + x
}
`, "result")
	testing.expect_value(t, core.as_int(v), 0 + 1 + 2 + 3 + 4)
}

@(test)
test_foreach_over_class_iter_protocol_respects_break_and_continue :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
class Range {
	init(n) { this.n = n }
	__iter__() { return RangeIterator(this.n) }
}
class RangeIterator {
	init(n) { this.n = n; this.i = 0 }
	__next__() {
		if this.i >= this.n { return nil }
		var v = this.i
		this.i = this.i + 1
		return v
	}
}
var result = 0
foreach y in Range(10) {
	if y == 3 { continue }
	if y == 7 { break }
	result = result + y
}
`, "result")
	// 0+1+2 (skip 3) +4+5+6, break before 7
	testing.expect_value(t, core.as_int(v), 0 + 1 + 2 + 4 + 5 + 6)
}

@(test)
test_foreach_over_instance_without_iter_is_runtime_error :: proc(t: ^testing.T) {
	expect_runtime_error(t, `
class NotIterable {
	init() { this.x = 1 }
}
foreach z in NotIterable() {
	print z
}
`)
}

@(test)
test_foreach_iter_result_without_next_is_runtime_error :: proc(t: ^testing.T) {
	expect_runtime_error(t, `
class BadIterator {
	init() { this.x = 1 }
}
class BadIterable {
	__iter__() { return BadIterator() }
}
foreach z in BadIterable() {
	print z
}
`)
}

// -----------------------------------------------------------------------
// Exceptions

@(test)
test_try_except_catches_raised_string :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
var result = ""
try {
	raise "boom"
} except RunTimeError as e {
	result = e.msg
}
`, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "boom")
}

@(test)
test_finally_runs_on_normal_completion :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
var result = 0
try {
	result = 1
} finally {
	result = result + 10
}
`, "result")
	testing.expect_value(t, core.as_int(v), 11)
}

@(test)
test_finally_runs_when_exception_is_caught :: proc(t: ^testing.T) {
	v := run_and_get_global(t, `
var result = 0
try {
	raise "x"
} except RunTimeError as e {
	result = result + 1
} finally {
	result = result + 10
}
`, "result")
	testing.expect_value(t, core.as_int(v), 11)
}

@(test)
test_uncaught_exception_is_runtime_error :: proc(t: ^testing.T) {
	expect_runtime_error(t, `
try {
	raise "x"
} except EOFError as e {
	var unreachable = 1
}
`)
}

// Regression test for a real, reproduced crash in
// exceptions.odin's match_clause_chain: when a raised exception's type
// doesn't match a try's only except clause, the VM has to decide "is
// there another clause to check, or is this genuinely uncaught?" by
// reading whatever bytecode sits right after this clause's own body --
// which previously only checked whether that position was still
// *within the chunk's bounds*, not whether it actually held another
// Except/Finally opcode. Real scripts almost always have *something*
// after a try/except (this test's own `var tail = 1`, deliberately
// placed there rather than left implicit the way
// test_uncaught_exception_is_runtime_error above happens to via
// end_compiler's always-emitted trailing Nil+Return), which put a real,
// in-bounds, unrelated instruction at that position -- reading it as
// [type_const][skip_hi][skip_lo] operand bytes crashed with an
// out-of-range panic. Fixed by checking the opcode actually there, not
// just the chunk bounds.
@(test)
test_uncaught_exception_with_trailing_code_does_not_crash :: proc(t: ^testing.T) {
	expect_runtime_error(t, `
var tail = 0
try {
	raise "x"
} except EOFError as e {
	var unreachable = 1
}
tail = 1
`)
}

@(test)
test_undefined_variable_is_runtime_error :: proc(t: ^testing.T) {
	expect_runtime_error(t, "print undefined_name\n")
}

// -----------------------------------------------------------------------
// REPL

@(test)
test_repl_second_line_sees_first_lines_global :: proc(t: ^testing.T) {
	vm_instance := new_vm("test")
	set_repl(vm_instance, true)

	status1, _ := interpret(vm_instance, "var x = 10\n")
	testing.expect_value(t, status1, Interpret_Result.Ok)

	// KNOWN GAP: a bare expression's value doesn't survive as
	// Interpret's "result" -- expression_statement always emits Pop
	// (see compiler/stmt.odin) and end_compiler always emits Nil before
	// Return regardless of what preceded it (see
	// compiler_state.odin's end_compiler), so a REPL line's own
	// "result" is unconditionally "nil" today, not the last expression's
	// value. Proper REPL "print last value" UX (`> 2 + 2` showing `4`)
	// needs the compiler to recognize "this is the final statement of a
	// REPL line" and skip both the Pop and the trailing Nil for that
	// one case -- not built yet; this test asserts the *actual* current
	// behavior (global-slot persistence across lines, which does work)
	// rather than the UX gap, so it doesn't silently start passing for
	// the wrong reason if that Pop/Nil interaction changes later.
	status2, result2 := interpret(vm_instance, "x + 5\n")
	testing.expect_value(t, status2, Interpret_Result.Ok)
	testing.expect_value(t, result2, "nil")

	// The cross-line slot persistence this test is really about: a
	// second reference to `x` resolves to the same global `var x = 10`
	// declared on the first line, not a compile error or a fresh slot.
	status3, _ := interpret(vm_instance, "var y = x + 5\n")
	testing.expect_value(t, status3, Interpret_Result.Ok)
	slot := core.env_slot_for_name(vm_instance.environment, "y")
	testing.expect(t, slot >= 0)
	testing.expect_value(t, core.as_int(vm_instance.environment.globals[slot]), 15)
}
