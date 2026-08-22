package compiler

import "core:testing"

// Direct parser-level tests for parse_type_expr (type_expr.odin), Phase 1
// of optional type annotations. These parse a type expression in
// isolation, not through one of the three annotation sites (params, var
// decls, return types) -- those sites are covered separately in
// ast_expr_test.odin/ast_stmt_test.odin, which check the annotation lands
// on the right field; these tests check the shape of the Type_Expr tree
// itself.

@(private = "file")
parse_type :: proc(t: ^testing.T, source: string) -> ^Type_Expr {
	scn := tokenize(source)
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	te := parse_type_expr(&p)
	testing.expectf(t, !p.had_error, "expected %q to parse without error", source)
	return te
}

@(test)
test_type_expr_named :: proc(t: ^testing.T) {
	te := parse_type(t, "int")
	testing.expect_value(t, te.kind, Type_Expr_Kind.Named)
	testing.expect_value(t, lexeme(te.name), "int")
}

@(test)
test_type_expr_class_name :: proc(t: ^testing.T) {
	// A type name is any identifier, not just the built-in primitives --
	// this is what lets a class name be used as an annotation with no
	// separate grammar path.
	te := parse_type(t, "Animal")
	testing.expect_value(t, te.kind, Type_Expr_Kind.Named)
	testing.expect_value(t, lexeme(te.name), "Animal")
}

@(test)
test_type_expr_generic_single_arg :: proc(t: ^testing.T) {
	te := parse_type(t, "List[int]")
	testing.expect_value(t, te.kind, Type_Expr_Kind.Generic)
	testing.expect_value(t, lexeme(te.name), "List")
	testing.expect(t, len(te.args) == 1, "expected one type argument")
	testing.expect_value(t, te.args[0].kind, Type_Expr_Kind.Named)
	testing.expect_value(t, lexeme(te.args[0].name), "int")
}

@(test)
test_type_expr_generic_two_args :: proc(t: ^testing.T) {
	te := parse_type(t, "Dict[string, int]")
	testing.expect_value(t, te.kind, Type_Expr_Kind.Generic)
	testing.expect_value(t, lexeme(te.name), "Dict")
	testing.expect(t, len(te.args) == 2, "expected two type arguments")
	testing.expect_value(t, lexeme(te.args[0].name), "string")
	testing.expect_value(t, lexeme(te.args[1].name), "int")
}

@(test)
test_type_expr_nilable :: proc(t: ^testing.T) {
	te := parse_type(t, "int?")
	testing.expect_value(t, te.kind, Type_Expr_Kind.Nilable)
	testing.expect(t, te.inner != nil, "expected inner type to be captured")
	testing.expect_value(t, te.inner.kind, Type_Expr_Kind.Named)
	testing.expect_value(t, lexeme(te.inner.name), "int")
}

@(test)
test_type_expr_nilable_generic :: proc(t: ^testing.T) {
	// `?` applies to the whole preceding type_expr, including a generic
	// one -- `List[int]?` is a nilable list, not a list of nilable ints.
	te := parse_type(t, "List[int]?")
	testing.expect_value(t, te.kind, Type_Expr_Kind.Nilable)
	testing.expect_value(t, te.inner.kind, Type_Expr_Kind.Generic)
	testing.expect_value(t, lexeme(te.inner.name), "List")
}

@(test)
test_type_expr_unclosed_bracket_is_error :: proc(t: ^testing.T) {
	scn := tokenize("List[int")
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	parse_type_expr(&p)
	testing.expect(t, p.had_error, "expected an unclosed '[' to be a parse error")
}

@(test)
test_type_expr_missing_identifier_is_error :: proc(t: ^testing.T) {
	scn := tokenize("123")
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	parse_type_expr(&p)
	testing.expect(t, p.had_error, "expected a non-identifier type name to be a parse error")
}
