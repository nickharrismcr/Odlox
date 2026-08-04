package compiler

import "core:testing"

// Direct Resolver tests for implementation phase 4 of docs/plans/
// compiler-ast-split.md: resolved slot numbers and expected validity
// errors against known-good/known-bad programs, exercising resolve_program
// directly rather than through Compile (which doesn't exist for the new
// pipeline yet -- that's phase 5+).

// destroy_scanner is deliberately not called here -- see
// v2_ast_expr_test.odin's parse_expr_ast for why.
@(private = "file")
parse_and_resolve :: proc(t: ^testing.T, source: string) -> (stmts: []Stmt, globals: Global_Table, had_error: bool) {
	scn := tokenize(source)
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	list: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration_ast(&p)
		if s != nil {
			append(&list, s)
		}
	}
	testing.expectf(t, !p.had_error, "expected %q to parse without error", source)
	stmts = list[:]
	globals, had_error = resolve_program(stmts)
	return
}

@(test)
test_resolve_block_locals_get_increasing_slots :: proc(t: ^testing.T) {
	stmts, _, had_error := parse_and_resolve(t, "{\nvar a = 1\nvar b = 2\n}")
	testing.expect(t, !had_error)
	block, ok := stmts[0].(^Stmt_Block)
	testing.expect(t, ok, "expected Stmt_Block")
	a := block.stmts[0].(^Stmt_Var_Decl)
	b := block.stmts[1].(^Stmt_Var_Decl)
	testing.expect(t, a.is_local && b.is_local)
	testing.expect(t, a.declared_slot == 1, "slot 0 is reserved") // reserved slot 0, so a is the first real local
	testing.expect(t, b.declared_slot == 2)
	testing.expectf(t, len(block.local_exits) == 2, "expected 2 local exits, got %d", len(block.local_exits))
	// Reverse declaration order: b (last declared) exits first.
	testing.expect(t, block.local_exits[0].slot == b.declared_slot)
	testing.expect(t, block.local_exits[1].slot == a.declared_slot)
}

@(test)
test_resolve_global_gets_slot_on_first_mention :: proc(t: ^testing.T) {
	stmts, globals, had_error := parse_and_resolve(t, "print x\nvar x = 1")
	testing.expect(t, !had_error)
	print_stmt := stmts[0].(^Stmt_Print)
	var_ref, ok := print_stmt.expr.(^Expr_Variable)
	testing.expect(t, ok, "expected Expr_Variable")
	testing.expect(t, var_ref.resolved.kind == .Global)
	testing.expect(t, var_ref.resolved.slot == 0)

	decl := stmts[1].(^Stmt_Var_Decl)
	testing.expect(t, !decl.is_local)
	testing.expect(t, decl.declared_slot == 0, "declaration should reuse the slot its earlier reference already claimed")
	testing.expect(t, globals.count == 1)
}

@(test)
test_resolve_implicit_assign_self_reference_errors :: proc(t: ^testing.T) {
	_, _, had_error := parse_and_resolve(t, "func f() {\nx = x\n}")
	testing.expect(t, had_error, "expected first-mention `x = x` to trip the own-initializer check, unlike `var x = x`")
}

@(test)
test_resolve_var_self_reference_does_not_error :: proc(t: ^testing.T) {
	_, _, had_error := parse_and_resolve(t, "func f() {\nvar x = x\n}")
	testing.expect(t, !had_error, "var's initializer resolves before declaring the local, same as Compile() today")
}

@(test)
test_resolve_duplicate_local_in_same_scope_errors :: proc(t: ^testing.T) {
	_, _, had_error := parse_and_resolve(t, "{\nvar a = 1\nvar a = 2\n}")
	testing.expect(t, had_error)
}

@(test)
test_resolve_shadowing_in_nested_scope_is_fine :: proc(t: ^testing.T) {
	_, _, had_error := parse_and_resolve(t, "{\nvar a = 1\n{\nvar a = 2\n}\n}")
	testing.expect(t, !had_error)
}

@(test)
test_resolve_break_continue_validity :: proc(t: ^testing.T) {
	_, _, bad_break := parse_and_resolve(t, "break")
	testing.expect(t, bad_break, "expected break outside loop to error")

	_, _, bad_continue := parse_and_resolve(t, "continue")
	testing.expect(t, bad_continue, "expected continue outside loop to error")

	_, _, ok_break := parse_and_resolve(t, "while (true) {\nbreak\n}")
	testing.expect(t, !ok_break)

	_, _, ok_foreach_continue := parse_and_resolve(t, "foreach (x in list) {\ncontinue\n}")
	testing.expect(t, !ok_foreach_continue)
}

@(test)
test_resolve_return_validity :: proc(t: ^testing.T) {
	_, _, top_level := parse_and_resolve(t, "return 1")
	testing.expect(t, top_level, "expected return at top level to error")

	_, _, in_func := parse_and_resolve(t, "func f() {\nreturn 1\n}")
	testing.expect(t, !in_func)

	_, _, value_in_init := parse_and_resolve(t, "class A {\ninit() {\nreturn 1\n}\n}")
	testing.expect(t, value_in_init, "expected returning a value from an initializer to error")

	_, _, bare_in_init := parse_and_resolve(t, "class A {\ninit() {\nreturn\n}\n}")
	testing.expect(t, !bare_in_init, "bare return should be fine in an initializer")
}

@(test)
test_resolve_this_super_outside_class_errors :: proc(t: ^testing.T) {
	_, _, this_err := parse_and_resolve(t, "print this")
	testing.expect(t, this_err)

	_, _, super_err := parse_and_resolve(t, "print super.foo")
	testing.expect(t, super_err)
}

@(test)
test_resolve_const_reassignment_errors :: proc(t: ^testing.T) {
	_, _, via_implicit := parse_and_resolve(t, "func f() {\nconst x = 1\nx = 2\n}")
	testing.expect(t, via_implicit, "expected reassigning a local const via bare statement-level assignment to error")

	_, _, via_expr := parse_and_resolve(t, "func f() {\nconst x = 1\nprint (x = 2)\n}")
	testing.expect(t, via_expr, "expected reassigning a local const via an assignment expression to error")
}

@(test)
test_resolve_upvalue_capture_marks_outer_local_captured :: proc(t: ^testing.T) {
	source := `
func outer() {
	{
		var x = 1
		var f = func() { return x }
	}
}
`
	stmts, _, had_error := parse_and_resolve(t, source)
	testing.expect(t, !had_error)

	outer_decl := stmts[0].(^Stmt_Function_Decl)
	block := outer_decl.decl.body[0].(^Stmt_Block)
	x_decl := block.stmts[0].(^Stmt_Var_Decl)
	f_decl := block.stmts[1].(^Stmt_Var_Decl)

	lambda := f_decl.init.(^Expr_Lambda)
	ret := lambda.decl.body[0].(^Stmt_Return)
	var_ref, ok := ret.value.(^Expr_Variable)
	testing.expect(t, ok, "expected Expr_Variable")
	testing.expect(t, var_ref.resolved.kind == .Upvalue)
	testing.expect(t, len(lambda.decl.upvalues) == 1)
	testing.expect(t, lambda.decl.upvalues[0].is_local, "captured directly from the enclosing block, not transitively")

	testing.expectf(t, len(block.local_exits) == 2, "expected 2 local exits, got %d", len(block.local_exits))
	// Reverse declaration order: f (last declared) exits first.
	testing.expect(t, block.local_exits[0].slot == f_decl.declared_slot)
	testing.expect(t, !block.local_exits[0].is_captured, "f itself is never captured")
	testing.expect(t, block.local_exits[1].slot == x_decl.declared_slot)
	testing.expect(t, block.local_exits[1].is_captured, "expected x to be marked captured since the lambda references it")
}

@(test)
test_resolve_class_superclass_and_super_reference :: proc(t: ^testing.T) {
	source := `
class Animal {
}
class Dog < Animal {
	speak() {
		return super.speak()
	}
}
`
	stmts, _, had_error := parse_and_resolve(t, source)
	testing.expect(t, !had_error)

	dog := stmts[1].(^Stmt_Class_Decl)
	testing.expect(t, dog.has_superclass)
	testing.expect(t, dog.superclass_ref.kind == .Global, "Animal is declared as a global")

	speak := dog.members[0].(^Method)
	ret := speak.decl.body[0].(^Stmt_Return)
	super_expr := ret.value.(^Expr_Super)
	testing.expect(t, super_expr.this_ref.kind == .Local, "'this' is speak's own slot 0")
	testing.expect(
		t,
		super_expr.super_ref.kind == .Upvalue,
		"'super' lives in the class's own wrapping scope, one function-scope out from the method",
	)
}

@(test)
test_resolve_self_inheritance_still_flagged_at_parse_time :: proc(t: ^testing.T) {
	// Confirms resolve_program doesn't need to (and doesn't) re-check
	// this -- class_declaration_ast already rejects it during parsing.
	scn := tokenize("class Foo < Foo {\n}")
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	advance(&p) // consume 'class'
	class_declaration_ast(&p)
	testing.expect(t, p.had_error)
}
