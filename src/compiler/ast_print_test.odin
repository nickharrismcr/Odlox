package compiler

import "core:testing"

// Output-shape tests for ast_print.odin -- exact string comparison against
// small fixtures, following ast_expr_test.odin/ast_stmt_test.odin's own
// parse-in-isolation pattern (own copy of the helper: @(private = "file")
// doesn't cross files, so each of these test files keeps its own).

// destroy_scanner is deliberately not called here -- see
// ast_expr_test.odin's parse_expr for why.
@(private = "file")
parse_program :: proc(t: ^testing.T, source: string) -> []Stmt {
	scn := tokenize(source)
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	stmts: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration(&p)
		if s != nil {
			append(&stmts, s)
		}
	}
	testing.expectf(t, !p.had_error, "expected %q to parse without error", source)
	return stmts[:]
}

@(test)
test_print_ast_literal :: proc(t: ^testing.T) {
	stmts := parse_program(t, "42")
	testing.expect_value(t, print_ast(stmts), "(expr-stmt 42)\n")
}

@(test)
test_print_ast_binary_precedence :: proc(t: ^testing.T) {
	stmts := parse_program(t, "1 + 2 * 3")
	testing.expect_value(t, print_ast(stmts), "(expr-stmt (+ 1 (* 2 3)))\n")
}

@(test)
test_print_ast_if_else_block_nesting :: proc(t: ^testing.T) {
	stmts := parse_program(t, "if (a) { print 1 } else { print 2 }")
	expected := "(if a\n  (block\n    (print 1)\n  )\nelse\n  (block\n    (print 2)\n  )\n)\n"
	testing.expect_value(t, print_ast(stmts), expected)
}

@(test)
test_print_ast_function_decl :: proc(t: ^testing.T) {
	stmts := parse_program(t, "func add(a, b=1, *rest) { return a + b }")
	expected := "(func add (a b=1 *rest)\n  (return (+ a b))\n)\n"
	testing.expect_value(t, print_ast(stmts), expected)
}

@(test)
test_print_ast_var_and_const_decl :: proc(t: ^testing.T) {
	stmts := parse_program(t, "var x = 1")
	testing.expect_value(t, print_ast(stmts), "(var x 1)\n")

	stmts2 := parse_program(t, "var y")
	testing.expect_value(t, print_ast(stmts2), "(var y)\n")

	stmts3 := parse_program(t, "const z = 2")
	testing.expect_value(t, print_ast(stmts3), "(const z 2)\n")
}

// Type_Expr printing mirrors surface syntax (`: int`, `-> int`,
// `List[int]`, `int?`) at all three annotation sites -- see this file's
// header comment and docs/plans/optional-type-checking-implementation.md's
// open question 4.
@(test)
test_print_ast_var_decl_type_annotation :: proc(t: ^testing.T) {
	stmts := parse_program(t, "var x: int = 1")
	testing.expect_value(t, print_ast(stmts), "(var x: int 1)\n")

	stmts2 := parse_program(t, "var y: List[int]")
	testing.expect_value(t, print_ast(stmts2), "(var y: List[int])\n")
}

@(test)
test_print_ast_function_decl_type_annotations :: proc(t: ^testing.T) {
	stmts := parse_program(t, "func add(a: int, b: int?) -> int { return a }")
	expected := "(func add (a: int b: int?) -> int\n  (return a)\n)\n"
	testing.expect_value(t, print_ast(stmts), expected)
}

@(test)
test_print_ast_class_decl_with_superclass_and_static_member :: proc(t: ^testing.T) {
	stmts := parse_program(t, "class Dog < Animal { static count = 0\n bark() { print 1 } }")
	expected := "(class Dog < Animal\n  (static-var count 0)\n  (method bark ()\n    (print 1)\n  )\n)\n"
	testing.expect_value(t, print_ast(stmts), expected)
}

@(test)
test_print_ast_try_except_finally :: proc(t: ^testing.T) {
	stmts := parse_program(t, "try { raise 1 } except Error as e { print e } finally { print 2 }")
	expected :=
		"(try\n" +
		"  (raise 1)\n" +
		"except Error as e\n" +
		"  (print e)\n" +
		"finally\n" +
		"  (print 2)\n" +
		")\n"
	testing.expect_value(t, print_ast(stmts), expected)
}

// A bare `func(x) {...}` isn't valid at statement level -- the top-level
// declaration() dispatch always treats a leading `func` token as a named
// function_declaration (requiring an identifier next), so a lambda only
// ever appears nested in an expression context; `var f = func(x) {...}`
// is the simplest one.
@(test)
test_print_ast_lambda :: proc(t: ^testing.T) {
	stmts := parse_program(t, "var f = func(x) { return x }")
	expected := "(var f (lambda (x)\n  (return x)\n))\n"
	testing.expect_value(t, print_ast(stmts), expected)
}
