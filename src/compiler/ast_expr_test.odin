package compiler

import "core:testing"

// AST-shape tests for the Pratt parser's expression handling (parser.odin/
// rules.odin/expr.odin) -- exercises the parser in isolation, checking
// tree shape directly rather than going through Compile()'s full parse/
// resolve/emit pipeline and inspecting opcodes (compile_test.odin's own
// style). Complementary to that file, not a replacement for it: this
// catches parser bugs precisely, at the layer they actually occur.

// destroy_scanner is deliberately not called/deferred here: Token.source
// (scanner.odin) slices into the scanner's own normalized-source buffer,
// and AST nodes returned by expression hold onto raw Tokens whose
// lexeme() a caller may still read after this helper returns -- unlike
// Compile(), which never keeps a Token alive past its own single pass.
@(private = "file")
parse_expr :: proc(t: ^testing.T, source: string) -> Expr {
	scn := tokenize(source)
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	e := expression(&p)
	testing.expectf(t, !p.had_error, "expected %q to parse without error", source)
	return e
}

@(test)
test_ast_arithmetic_precedence_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "1 + 2 * 3")
	add, ok := e.(^Expr_Binary)
	testing.expect(t, ok, "expected top-level Expr_Binary")
	testing.expect(t, add.op == .Plus)
	_, left_ok := add.left.(^Expr_Literal)
	testing.expect(t, left_ok, "expected left operand to be a literal")
	mul, right_ok := add.right.(^Expr_Binary)
	testing.expect(t, right_ok, "expected right operand to be a nested Expr_Binary")
	testing.expect(t, mul.op == .Star)
}

@(test)
test_ast_plain_assignment_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "x = 1")
	a, ok := e.(^Expr_Assign)
	testing.expect(t, ok, "expected Expr_Assign")
	testing.expect(t, lexeme(a.name) == "x")
	testing.expect(t, !a.is_compound)
	testing.expect(t, a.resolved.kind == .Unresolved, "resolution happens in the Resolver, not the parser")
}

@(test)
test_ast_compound_assignment_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "x += 1")
	a, ok := e.(^Expr_Assign)
	testing.expect(t, ok, "expected Expr_Assign")
	testing.expect(t, a.is_compound)
	testing.expect(t, a.compound_op == .Plus_Equal)
}

@(test)
test_ast_ternary_conditional_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "a ? b : c")
	c, ok := e.(^Expr_Conditional)
	testing.expect(t, ok, "expected Expr_Conditional")
	_, cond_ok := c.condition.(^Expr_Variable)
	testing.expect(t, cond_ok)
	_, then_ok := c.then_branch.(^Expr_Variable)
	testing.expect(t, then_ok)
	_, else_ok := c.else_branch.(^Expr_Variable)
	testing.expect(t, else_ok)
}

@(test)
test_ast_ternary_chains_right_associatively :: proc(t: ^testing.T) {
	e := parse_expr(t, "a ? b : c ? d : e")
	outer, ok := e.(^Expr_Conditional)
	testing.expect(t, ok, "expected outer Expr_Conditional")
	_, inner_ok := outer.else_branch.(^Expr_Conditional)
	testing.expect(t, inner_ok, "expected else branch to itself be a conditional")
}

@(test)
test_ast_call_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "f(1, 2)")
	c, ok := e.(^Expr_Call)
	testing.expect(t, ok, "expected Expr_Call")
	_, callee_ok := c.callee.(^Expr_Variable)
	testing.expect(t, callee_ok)
	testing.expect(t, len(c.args) == 2)
}

@(test)
test_ast_property_get_set_invoke_shape :: proc(t: ^testing.T) {
	get := parse_expr(t, "obj.prop")
	g, g_ok := get.(^Expr_Property)
	testing.expect(t, g_ok, "expected Expr_Property")
	testing.expect(t, g.kind == .Get)

	set := parse_expr(t, "obj.prop = 1")
	s, s_ok := set.(^Expr_Property)
	testing.expect(t, s_ok, "expected Expr_Property")
	testing.expect(t, s.kind == .Set)

	compound := parse_expr(t, "obj.prop += 1")
	cs, cs_ok := compound.(^Expr_Property)
	testing.expect(t, cs_ok, "expected Expr_Property")
	testing.expect(t, cs.kind == .Compound_Set)
	testing.expect(t, cs.compound_op == .Plus_Equal)

	invoke := parse_expr(t, "obj.method(1)")
	i, i_ok := invoke.(^Expr_Property)
	testing.expect(t, i_ok, "expected Expr_Property")
	testing.expect(t, i.kind == .Invoke)
	testing.expect(t, len(i.args) == 1)
}

@(test)
test_ast_subscript_index_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "a[1]")
	s, ok := e.(^Expr_Subscript)
	testing.expect(t, ok, "expected Expr_Subscript")
	testing.expect(t, !s.is_slice)
	testing.expect(t, s.index != nil)
	testing.expect(t, s.assign_value == nil)
}

@(test)
test_ast_subscript_slice_open_bounds_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "a[:]")
	s, ok := e.(^Expr_Subscript)
	testing.expect(t, ok, "expected Expr_Subscript")
	testing.expect(t, s.is_slice)
	testing.expect(t, s.slice_start == nil)
	testing.expect(t, s.slice_end == nil)
}

@(test)
test_ast_subscript_index_assign_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "a[1] = 2")
	s, ok := e.(^Expr_Subscript)
	testing.expect(t, ok, "expected Expr_Subscript")
	testing.expect(t, !s.is_slice)
	testing.expect(t, s.assign_value != nil)
}

@(test)
test_ast_literal_kinds :: proc(t: ^testing.T) {
	i := parse_expr(t, "42")
	il, il_ok := i.(^Expr_Literal)
	testing.expect(t, il_ok && il.kind == .Int)

	f := parse_expr(t, "4.5")
	fl, fl_ok := f.(^Expr_Literal)
	testing.expect(t, fl_ok && fl.kind == .Float)

	s := parse_expr(t, "\"hi\"")
	sl, sl_ok := s.(^Expr_Literal)
	testing.expect(t, sl_ok && sl.kind == .String)

	bt := parse_expr(t, "true")
	btl, btl_ok := bt.(^Expr_Literal)
	testing.expect(t, btl_ok && btl.kind == .Bool)

	n := parse_expr(t, "nil")
	nl, nl_ok := n.(^Expr_Literal)
	testing.expect(t, nl_ok && nl.kind == .Nil)
}

@(test)
test_ast_tuple_shapes :: proc(t: ^testing.T) {
	single := parse_expr(t, "(1)")
	_, single_is_literal := single.(^Expr_Literal)
	testing.expect(t, single_is_literal, "a single parenthesized expr should not become a tuple node")

	pair := parse_expr(t, "(1, 2, 3)")
	tup, tup_ok := pair.(^Expr_Tuple)
	testing.expect(t, tup_ok, "expected Expr_Tuple")
	testing.expect(t, len(tup.elements) == 3)

	empty := parse_expr(t, "()")
	etup, etup_ok := empty.(^Expr_Tuple)
	testing.expect(t, etup_ok, "expected Expr_Tuple")
	testing.expect(t, len(etup.elements) == 0)
}

@(test)
test_ast_list_and_dict_literal_shape :: proc(t: ^testing.T) {
	list := parse_expr(t, "[1, 2, 3]")
	l, l_ok := list.(^Expr_List)
	testing.expect(t, l_ok, "expected Expr_List")
	testing.expect(t, len(l.elements) == 3)

	dict := parse_expr(t, "{\"a\": 1, \"b\": 2}")
	d, d_ok := dict.(^Expr_Dict)
	testing.expect(t, d_ok, "expected Expr_Dict")
	testing.expect(t, len(d.entries) == 2)
}

@(test)
test_ast_str_call_shape :: proc(t: ^testing.T) {
	e := parse_expr(t, "str(1)")
	s, ok := e.(^Expr_Str_Call)
	testing.expect(t, ok, "expected Expr_Str_Call")
	testing.expect(t, s.inner != nil)
}

@(test)
test_ast_this_and_super_shape :: proc(t: ^testing.T) {
	// this/super don't check class context -- that's the
	// Resolver's job (implementation phase 4) -- so these parse cleanly
	// even outside any class here.
	th := parse_expr(t, "this")
	_, th_ok := th.(^Expr_This)
	testing.expect(t, th_ok, "expected Expr_This")

	sup := parse_expr(t, "super.method()")
	sp, sp_ok := sup.(^Expr_Super)
	testing.expect(t, sp_ok, "expected Expr_Super")
	testing.expect(t, sp.has_args)
	testing.expect(t, lexeme(sp.method_name) == "method")
}
