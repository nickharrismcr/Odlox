package compiler

import "core:testing"

// AST-shape tests for statement/declaration parsing (parser.odin/
// stmt.odin) -- same rationale as ast_expr_test.odin: checks tree shape
// directly, at the layer parser bugs actually occur, complementary to
// compile_test.odin's opcode-level assertions.

// destroy_scanner is deliberately not called here -- see
// v2_ast_expr_test.odin's parse_expr for why.
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

// parse_one is parse_program for the common single-statement case.
@(private = "file")
parse_one :: proc(t: ^testing.T, source: string) -> Stmt {
	stmts := parse_program(t, source)
	testing.expectf(t, len(stmts) == 1, "expected exactly one top-level statement, got %d", len(stmts))
	if len(stmts) == 0 {
		return nil
	}
	return stmts[0]
}

@(test)
test_ast_var_and_const_decl_shape :: proc(t: ^testing.T) {
	v := parse_one(t, "var x = 1")
	vd, ok := v.(^Stmt_Var_Decl)
	testing.expect(t, ok, "expected Stmt_Var_Decl")
	testing.expect(t, lexeme(vd.name) == "x")
	testing.expect(t, !vd.is_const)
	testing.expect(t, vd.init != nil)

	novalue := parse_one(t, "var y")
	nvd, nvd_ok := novalue.(^Stmt_Var_Decl)
	testing.expect(t, nvd_ok, "expected Stmt_Var_Decl")
	testing.expect(t, nvd.init == nil, "expected no initializer to leave init nil")

	c := parse_one(t, "const z = 2")
	cd, cd_ok := c.(^Stmt_Var_Decl)
	testing.expect(t, cd_ok, "expected Stmt_Var_Decl")
	testing.expect(t, cd.is_const)
}

@(test)
test_ast_var_decl_type_annotation_shape :: proc(t: ^testing.T) {
	untyped := parse_one(t, "var x = 1")
	uvd, uvd_ok := untyped.(^Stmt_Var_Decl)
	testing.expect(t, uvd_ok, "expected Stmt_Var_Decl")
	testing.expect(t, uvd.type_annotation == nil, "expected no annotation to leave type_annotation nil")

	typed := parse_one(t, "var x: int = 1")
	tvd, tvd_ok := typed.(^Stmt_Var_Decl)
	testing.expect(t, tvd_ok, "expected Stmt_Var_Decl")
	testing.expect(t, tvd.type_annotation != nil, "expected annotation to be captured")
	testing.expect_value(t, tvd.type_annotation.kind, Type_Expr_Kind.Named)
	testing.expect_value(t, lexeme(tvd.type_annotation.name), "int")

	no_init := parse_one(t, "var y: string")
	nvd, nvd_ok := no_init.(^Stmt_Var_Decl)
	testing.expect(t, nvd_ok, "expected Stmt_Var_Decl")
	testing.expect(t, nvd.type_annotation != nil, "expected annotation without an initializer to still be captured")
	testing.expect(t, nvd.init == nil)
}

// Regression test, at the parser level, for the same bug
// test_eol_kept_after_nilable_type_annotation exercises at the scanner
// level: a nilable annotation ending a var decl (no initializer) must
// terminate as its own complete statement, not swallow the next line.
@(test)
test_ast_nilable_var_decl_terminates_before_next_statement :: proc(t: ^testing.T) {
	stmts := parse_program(t, "var c: string?\nvar d = 1")
	testing.expect(t, len(stmts) == 2, "expected two separate statements")
	vd, ok := stmts[0].(^Stmt_Var_Decl)
	testing.expect(t, ok, "expected Stmt_Var_Decl")
	testing.expect(t, vd.type_annotation != nil)
	testing.expect_value(t, vd.type_annotation.kind, Type_Expr_Kind.Nilable)
	testing.expect(t, vd.init == nil)
}

@(test)
test_ast_implicit_assignment_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "x = 1")
	a, ok := s.(^Stmt_Implicit_Assign)
	testing.expect(t, ok, "expected Stmt_Implicit_Assign")
	testing.expect(t, lexeme(a.name) == "x")
	testing.expect(t, a.resolved.kind == .Unresolved, "resolution happens in the Resolver, not the parser")
}

@(test)
test_ast_destructuring_shape :: proc(t: ^testing.T) {
	single_rhs := parse_one(t, "a, b = pair()")
	d, ok := single_rhs.(^Stmt_Destructure)
	testing.expect(t, ok, "expected Stmt_Destructure")
	testing.expect(t, len(d.targets) == 2)
	_, is_call := d.value.(^Expr_Call)
	testing.expect(t, is_call, "single RHS value should be used directly, not wrapped in a tuple")

	multi_rhs := parse_one(t, "a, b = 1, 2")
	d2, ok2 := multi_rhs.(^Stmt_Destructure)
	testing.expect(t, ok2, "expected Stmt_Destructure")
	_, is_tuple := d2.value.(^Expr_Tuple)
	testing.expect(t, is_tuple, "multiple RHS values should wrap into an Expr_Tuple")
}

@(test)
test_ast_block_has_no_scope_bookkeeping :: proc(t: ^testing.T) {
	s := parse_one(t, "{ var x = 1\nprint x }")
	b, ok := s.(^Stmt_Block)
	testing.expect(t, ok, "expected Stmt_Block")
	testing.expect(t, len(b.stmts) == 2)
}

@(test)
test_ast_if_else_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "if (a) print 1\nelse print 2")
	i, ok := s.(^Stmt_If)
	testing.expect(t, ok, "expected Stmt_If")
	_, then_ok := i.then_branch.(^Stmt_Print)
	testing.expect(t, then_ok)
	_, else_ok := i.else_branch.(^Stmt_Print)
	testing.expect(t, else_ok)

	no_else := parse_one(t, "if (a) print 1")
	i2, ok2 := no_else.(^Stmt_If)
	testing.expect(t, ok2, "expected Stmt_If")
	testing.expect(t, i2.else_branch == nil)
}

@(test)
test_ast_else_if_chains_via_nested_stmt_if :: proc(t: ^testing.T) {
	s := parse_one(t, "if (a) print 1\nelse if (b) print 2\nelse print 3")
	outer, ok := s.(^Stmt_If)
	testing.expect(t, ok, "expected outer Stmt_If")
	_, inner_ok := outer.else_branch.(^Stmt_If)
	testing.expect(t, inner_ok, "expected else branch to itself be a Stmt_If")
}

@(test)
test_ast_while_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "while (a) print 1")
	w, ok := s.(^Stmt_While)
	testing.expect(t, ok, "expected Stmt_While")
	_, cond_ok := w.condition.(^Expr_Variable)
	testing.expect(t, cond_ok)
	_, body_ok := w.body.(^Stmt_Print)
	testing.expect(t, body_ok)
}

@(test)
test_ast_for_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "for (var i = 0; i < 10; i = i + 1) { print i }")
	f, ok := s.(^Stmt_For)
	testing.expect(t, ok, "expected Stmt_For")
	_, init_ok := f.init.(^Stmt_Var_Decl)
	testing.expect(t, init_ok, "expected var-led init clause")
	testing.expect(t, f.condition != nil)
	testing.expect(t, f.increment != nil)
	body, body_ok := f.body.(^Stmt_Block)
	testing.expect(t, body_ok, "expected braced body")
	testing.expect(t, len(body.stmts) == 1)
}

@(test)
test_ast_for_bare_init_uses_implicit_assign :: proc(t: ^testing.T) {
	s := parse_one(t, "for (i = 0; i < 10; i = i + 1) { print i }")
	f, ok := s.(^Stmt_For)
	testing.expect(t, ok, "expected Stmt_For")
	_, init_ok := f.init.(^Stmt_Implicit_Assign)
	testing.expect(t, init_ok, "expected bare init clause to reuse Stmt_Implicit_Assign")
}

@(test)
test_ast_foreach_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "foreach (x in list) { print x }")
	f, ok := s.(^Stmt_Foreach)
	testing.expect(t, ok, "expected Stmt_Foreach")
	testing.expect(t, lexeme(f.var_name) == "x")
	_, iter_ok := f.iterable.(^Expr_Variable)
	testing.expect(t, iter_ok)
}

@(test)
test_ast_break_continue_shape :: proc(t: ^testing.T) {
	// break/continue-outside-loop validity is the Resolver's job now, so
	// these parse cleanly even outside any loop here.
	b := parse_one(t, "break")
	_, b_ok := b.(^Stmt_Break)
	testing.expect(t, b_ok, "expected Stmt_Break")

	c := parse_one(t, "continue")
	_, c_ok := c.(^Stmt_Continue)
	testing.expect(t, c_ok, "expected Stmt_Continue")
}

@(test)
test_ast_return_shape :: proc(t: ^testing.T) {
	bare := parse_one(t, "return")
	r, ok := bare.(^Stmt_Return)
	testing.expect(t, ok, "expected Stmt_Return")
	testing.expect(t, r.value == nil)

	with_value := parse_one(t, "return 1")
	r2, ok2 := with_value.(^Stmt_Return)
	testing.expect(t, ok2, "expected Stmt_Return")
	testing.expect(t, r2.value != nil)
}

@(test)
test_ast_function_declaration_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "func add(a, b=1, *rest) { return a + b }")
	fd, ok := s.(^Stmt_Function_Decl)
	testing.expect(t, ok, "expected Stmt_Function_Decl")
	testing.expect(t, lexeme(fd.decl.name) == "add")
	testing.expect(t, len(fd.decl.params) == 3)
	testing.expect(t, !fd.decl.params[0].is_rest && fd.decl.params[0].default == nil)
	testing.expect(t, fd.decl.params[1].default != nil, "expected b's default to be captured")
	testing.expect(t, fd.decl.params[2].is_rest, "expected *rest to be marked is_rest")
	testing.expect(t, len(fd.decl.body) == 1)
}

@(test)
test_ast_function_declaration_type_annotations_shape :: proc(t: ^testing.T) {
	untyped := parse_one(t, "func add(a, b) { return a + b }")
	ufd, ufd_ok := untyped.(^Stmt_Function_Decl)
	testing.expect(t, ufd_ok, "expected Stmt_Function_Decl")
	testing.expect(t, ufd.decl.params[0].type_annotation == nil)
	testing.expect(t, ufd.decl.return_type == nil)

	// Annotation must parse before the default expression: `a: int = 5`.
	typed := parse_one(t, "func add(a: int, b: int = 5) -> int { return a + b }")
	tfd, tfd_ok := typed.(^Stmt_Function_Decl)
	testing.expect(t, tfd_ok, "expected Stmt_Function_Decl")
	testing.expect(t, len(tfd.decl.params) == 2)
	testing.expect(t, tfd.decl.params[0].type_annotation != nil, "expected a's annotation to be captured")
	testing.expect_value(t, lexeme(tfd.decl.params[0].type_annotation.name), "int")
	testing.expect(t, tfd.decl.params[1].type_annotation != nil, "expected b's annotation to be captured")
	testing.expect(t, tfd.decl.params[1].default != nil, "expected b's default to still be captured alongside its annotation")
	testing.expect(t, tfd.decl.return_type != nil, "expected the return-type annotation to be captured")
	testing.expect_value(t, lexeme(tfd.decl.return_type.name), "int")
}

@(test)
test_ast_lambda_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "var f = func(x) { return x }")
	vd, ok := s.(^Stmt_Var_Decl)
	testing.expect(t, ok, "expected Stmt_Var_Decl")
	lam, lam_ok := vd.init.(^Expr_Lambda)
	testing.expect(t, lam_ok, "expected Expr_Lambda")
	testing.expect(t, len(lam.decl.params) == 1)
}

@(test)
test_ast_class_declaration_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "class Dog < Animal {\n__init__(name) { this.name = name }\nstatic count = 0\nbark() { print \"woof\" }\n}")
	cd, ok := s.(^Stmt_Class_Decl)
	testing.expect(t, ok, "expected Stmt_Class_Decl")
	testing.expect(t, lexeme(cd.name) == "Dog")
	testing.expect(t, cd.has_superclass)
	testing.expect(t, lexeme(cd.superclass) == "Animal")
	testing.expect(t, len(cd.members) == 3, "expected __init__, count, bark as members in source order")

	init_method, init_ok := cd.members[0].(^Method)
	testing.expect(t, init_ok, "expected first member to be a Method")
	testing.expect(t, init_method.decl.fn_type == .Initializer)

	static_field, static_ok := cd.members[1].(^Class_Var_Member)
	testing.expect(t, static_ok, "expected second member to be a Class_Var_Member")
	testing.expect(t, lexeme(static_field.name) == "count")

	bark_method, bark_ok := cd.members[2].(^Method)
	testing.expect(t, bark_ok, "expected third member to be a Method")
	testing.expect(t, bark_method.decl.fn_type == .Method)
}

@(test)
test_ast_self_inheritance_is_still_flagged :: proc(t: ^testing.T) {
	scn := tokenize("class Foo < Foo {\n}")
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	advance(&p) // consume 'class', as declaration's own dispatch does before calling this
	class_declaration(&p)
	testing.expect(t, p.had_error, "expected self-inheritance to be a parse-time error, same as class_declaration today")
}

@(test)
test_ast_try_except_finally_shape :: proc(t: ^testing.T) {
	s := parse_one(
		t,
		"try {\nrisky()\n} except ValueError as e {\nprint e\n} except TypeError {\nprint 1\n} finally {\ncleanup()\n}",
	)
	tr, ok := s.(^Stmt_Try)
	testing.expect(t, ok, "expected Stmt_Try")
	testing.expect(t, len(tr.body) == 1)
	testing.expect(t, len(tr.excepts) == 2)
	testing.expect(t, lexeme(tr.excepts[0].type_name) == "ValueError")
	testing.expect(t, tr.excepts[0].has_binding)
	testing.expect(t, lexeme(tr.excepts[0].binding) == "e")
	testing.expect(t, !tr.excepts[1].has_binding)
	testing.expect(t, tr.has_finally)
	testing.expect(t, len(tr.finally_body) == 1)
}

@(test)
test_ast_try_without_except_or_finally_is_error :: proc(t: ^testing.T) {
	scn := tokenize("try {\nrisky()\n}\nprint 1")
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	advance(&p) // consume 'try', as statement's own dispatch does before calling this
	try_except_statement(&p)
	testing.expect(t, p.had_error, "expected 'try' with neither except nor finally to be a parse-time error")
}

@(test)
test_ast_import_shape :: proc(t: ^testing.T) {
	s := parse_one(t, "import math, sys as system")
	imp, ok := s.(^Stmt_Import)
	testing.expect(t, ok, "expected Stmt_Import")
	testing.expect(t, len(imp.items) == 2)
	testing.expect(t, lexeme(imp.items[0].module) == "math")
	testing.expect(t, !imp.items[0].has_alias)
	testing.expect(t, lexeme(imp.items[1].module) == "sys")
	testing.expect(t, imp.items[1].has_alias)
	testing.expect(t, lexeme(imp.items[1].alias) == "system")
}

@(test)
test_ast_from_import_shape :: proc(t: ^testing.T) {
	named := parse_one(t, "from math import sqrt, pow")
	fi, ok := named.(^Stmt_From_Import)
	testing.expect(t, ok, "expected Stmt_From_Import")
	testing.expect(t, !fi.wildcard)
	testing.expect(t, len(fi.names) == 2)
	testing.expect(t, lexeme(fi.names[0].name) == "sqrt")

	wildcard := parse_one(t, "from math import *")
	fi2, ok2 := wildcard.(^Stmt_From_Import)
	testing.expect(t, ok2, "expected Stmt_From_Import")
	testing.expect(t, fi2.wildcard)
}

// A single program exercising most of the language surface this phase
// covers, parsed without error -- the AST-shape equivalent of
// compile_test.odin's test_kitchen_sink_program_compiles.
@(test)
test_ast_kitchen_sink_program_parses :: proc(t: ^testing.T) {
	source := `
class Animal {
	__init__(name) {
		this.name = name
	}
	speak() {
		return "..."
	}
}

class Dog < Animal {
	speak() {
		return super.speak() + " woof"
	}
}

func make_counter() {
	count = 0
	return func() {
		count = count + 1
		return count
	}
}

var counter = make_counter()
var animals = [Animal("Rex"), Dog("Fido")]
var pair = {"a": 1, "b": 2}
a, b = 1, 2

for (i = 0; i < 3; i = i + 1) {
	if (i == 1) {
		continue
	}
	print i
}

foreach (a in animals) {
	print a.name
}

try {
	raise "oops"
} except Exception as e {
	print e
} finally {
	print "cleanup"
}

from math import sqrt
import sys as system
`
	parse_program(t, source)
}
