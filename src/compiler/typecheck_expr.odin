package compiler

import "core:fmt"

// Bottom-up type synthesis, one case per Expr variant -- mirrors resolve_
// expr's switch shape (resolve.odin) since it's the same traversal, now
// returning a ^Type instead of mutating scope state. Every case is
// visited unconditionally for its own diagnostics/nested recursion even
// where the synthesized result ends up Dynamic -- gradual typing's own
// discipline is "never skip a sub-expression", not "stop once something's
// unknown".
typecheck_expr :: proc(tc: ^Type_Checker, e: Expr) -> ^Type {
	if e == nil {
		return dynamic_type()
	}
	switch v in e {
	case ^Expr_Literal:
		return literal_type(v.kind)
	case ^Expr_Str_Call:
		typecheck_expr(tc, v.inner)
		return string_type() // str(expr) always returns a string, matching runtime -- accepts anything, checks nothing
	case ^Expr_Tuple:
		for el in v.elements {
			typecheck_expr(tc, el)
		}
		return dynamic_type() // no named type site to annotate a tuple against -- revisit only if a real gap shows up in practice
	case ^Expr_Unary:
		return typecheck_unary(tc, v)
	case ^Expr_Binary:
		return typecheck_binary(tc, v)
	case ^Expr_Logical:
		left := typecheck_expr(tc, v.left)
		right := typecheck_expr(tc, v.right)
		return union_type(left, right)
	case ^Expr_Conditional:
		typecheck_expr(tc, v.condition)
		then_type := typecheck_expr(tc, v.then_branch)
		else_type := typecheck_expr(tc, v.else_branch)
		return union_type(then_type, else_type)
	case ^Expr_Variable:
		return lookup_var_type(tc, v.resolved)
	case ^Expr_Assign:
		return typecheck_assign(tc, v)
	case ^Expr_This:
		return dynamic_type() // Phase 3: synthesizes tc.current_class's own Class_Type
	case ^Expr_Super:
		for a in v.args {
			typecheck_expr(tc, a)
		}
		return dynamic_type() // Phase 3: synthesizes tc.current_class.superclass's Class_Type
	case ^Expr_Call:
		return typecheck_call(tc, v)
	case ^Expr_Property:
		typecheck_expr(tc, v.object)
		typecheck_expr(tc, v.value)
		for a in v.args {
			typecheck_expr(tc, a)
		}
		return dynamic_type() // Phase 3: checks against the receiver's Class_Type.fields/.methods
	case ^Expr_Subscript:
		return typecheck_subscript(tc, v)
	case ^Expr_List:
		return typecheck_list(tc, v)
	case ^Expr_Dict:
		return typecheck_dict(tc, v)
	case ^Expr_Lambda:
		return typecheck_function_decl(tc, v.decl)
	}
	return dynamic_type()
}

@(private = "file")
literal_type :: proc(kind: Literal_Kind) -> ^Type {
	switch kind {
	case .Int:
		return int_type()
	case .Float:
		return float_type()
	case .String:
		return string_type()
	case .Bool:
		return bool_type()
	case .Nil:
		return nil_type()
	}
	return dynamic_type()
}

// expr_token extracts a diagnostic-anchoring Token from an arbitrary Expr
// -- every variant embeds Node_Base via `using`, but a union doesn't let
// callers reach into that without a type switch (unlike a common base
// class in an OO language).
expr_token :: proc(e: Expr) -> Token {
	switch v in e {
	case ^Expr_Literal:
		return v.token
	case ^Expr_Str_Call:
		return v.token
	case ^Expr_Tuple:
		return v.token
	case ^Expr_Unary:
		return v.token
	case ^Expr_Binary:
		return v.token
	case ^Expr_Logical:
		return v.token
	case ^Expr_Conditional:
		return v.token
	case ^Expr_Variable:
		return v.token
	case ^Expr_Assign:
		return v.token
	case ^Expr_This:
		return v.token
	case ^Expr_Super:
		return v.token
	case ^Expr_Call:
		return v.token
	case ^Expr_Property:
		return v.token
	case ^Expr_Subscript:
		return v.token
	case ^Expr_List:
		return v.token
	case ^Expr_Dict:
		return v.token
	case ^Expr_Lambda:
		return v.token
	}
	return Token{}
}

// -----------------------------------------------------------------------
// Unary / binary / compound-assignment arithmetic
//
// Checked directly against vm/arithmetic.odin's actual runtime dispatch
// (add_numeric/numeric_binop/negate), not assumed from the design doc's
// prose -- two of its claims don't hold for this VM and were caught by a
// full-corpus regression run: `+` (add_numeric) is numeric-only, no
// string-concatenation case (that's `&`/concat's job exclusively, a
// separate operator -- odlox has no `+`-as-concat the way some Lox
// dialects do); `*` (numeric_binop) additionally accepts (String, Int) or
// (Int, String) for string repetition (`"-" * 50`), checked *before* the
// plain-numeric fallback there. `-`'s vm-level vector case (`Vec2 - Vec2`
// etc.) is deliberately not special-cased here: no Type_Kind models a
// vector, so any expression that's actually vector-valued at runtime is
// already Dynamic in this lattice (there's no annotation surface that
// produces anything else for one), which already always passes
// check_numeric_operand's Dynamic escape hatch. `!` synthesizes Bool
// unconditionally (matches runtime truthiness coercion -- every value has
// a truthiness, so there's nothing to check). Comparisons (`== != < <= >
// >= in`) synthesize Bool unconditionally too: equality and `in`-
// membership are defined for any pair of types at runtime, and `<`/`>`
// etc. accept either two numbers or two strings (see arithmetic.odin's
// compare), so there's no single "wrong type" rule that wouldn't
// misfire on the string-comparison case -- not checked here. `++`
// (vector in-place-shaped add) and `&` (string/list concat) aren't
// modeled by this v1 lattice at all -- always Dynamic, never diagnosed,
// the same "don't model it, don't flag it" treatment Expr_Tuple/Expr_This
// get elsewhere in this file.

@(private = "file")
typecheck_unary :: proc(tc: ^Type_Checker, v: ^Expr_Unary) -> ^Type {
	operand := typecheck_expr(tc, v.operand)
	if v.op == .Bang {
		return bool_type()
	}
	// .Minus
	check_numeric_operand(tc, expr_token(v.operand), operand)
	return operand
}

@(private = "file")
typecheck_binary :: proc(tc: ^Type_Checker, v: ^Expr_Binary) -> ^Type {
	left := typecheck_expr(tc, v.left)
	right := typecheck_expr(tc, v.right)

	#partial switch v.op {
	case .Plus, .Minus, .Slash, .Percent:
		check_numeric_operand(tc, expr_token(v.left), left)
		check_numeric_operand(tc, expr_token(v.right), right)
		return numeric_result(left, right)
	case .Star:
		if left.kind == .Dynamic || right.kind == .Dynamic {
			// Can't rule out a valid (String, Int)/(Int, String) repeat
			// pairing when one side is unknown -- e.g. `" " * int(x)`,
			// where the untyped builtin `int(...)` synthesizes Dynamic
			// (see typecheck_call) -- so a concrete String on the other
			// side must not be flagged here the way it would be for the
			// purely-numeric operators above.
			return dynamic_type()
		}
		if is_string_repeat_operands(left, right) {
			return string_type()
		}
		check_numeric_operand(tc, expr_token(v.left), left)
		check_numeric_operand(tc, expr_token(v.right), right)
		return numeric_result(left, right)
	case .Bang_Equal, .Equal_Equal, .Greater, .Greater_Equal, .Less, .Less_Equal, .In:
		return bool_type()
	}
	// .Plus_Plus, .Ampersand
	return dynamic_type()
}

@(private = "file")
check_numeric_operand :: proc(tc: ^Type_Checker, tok: Token, t: ^Type) {
	if t.kind != .Int && t.kind != .Float && t.kind != .Dynamic {
		diagnose(tc, tok, fmt.tprintf("expected a numeric operand, got %s", type_string(t)))
	}
}

// is_string_repeat_operands matches numeric_binop's own `*` special case
// (vm/arithmetic.odin) exactly: (String, Int) or (Int, String) is string
// repetition, not an error -- checked before the ordinary numeric
// fallback, same order as the runtime check it mirrors.
@(private = "file")
is_string_repeat_operands :: proc(left, right: ^Type) -> bool {
	return (left.kind == .String && right.kind == .Int) || (left.kind == .Int && right.kind == .String)
}

// numeric_result mirrors ordinary numeric promotion: Dynamic infects the
// result if present on either side (nothing statically known), else a
// Float on either side promotes the result to Float, else both sides are
// Int and so is the result.
@(private = "file")
numeric_result :: proc(left, right: ^Type) -> ^Type {
	if left.kind == .Dynamic || right.kind == .Dynamic {
		return dynamic_type()
	}
	if left.kind == .Float || right.kind == .Float {
		return float_type()
	}
	return int_type()
}

// -----------------------------------------------------------------------
// Assignment

@(private = "file")
typecheck_assign :: proc(tc: ^Type_Checker, v: ^Expr_Assign) -> ^Type {
	value_type := typecheck_expr(tc, v.value)
	existing := lookup_var_type(tc, v.resolved)

	result_type := value_type
	if v.is_compound {
		result_type = compound_result_type(tc, v.token, v.compound_op, existing, value_type)
	}

	if !types_compatible(existing, result_type) {
		diagnose(
			tc,
			v.token,
			fmt.tprintf("cannot assign %s to '%s' of type %s", type_string(result_type), lexeme(v.name), type_string(existing)),
		)
	}

	return result_type
}

// compound_result_type is compound assignment's (`+=` etc.) own version
// of typecheck_binary -- same rules, but the left "operand" is the
// target's already-recorded type rather than a fresh sub-expression to
// visit (there is none; the target is a name, not an expression), so
// there's no expr_token to anchor a diagnostic on beyond the assignment's
// own token. compound_op stores the original two-character token
// (.Plus_Equal, not .Plus -- see expr.odin's compound_assign_token).
@(private = "file")
compound_result_type :: proc(tc: ^Type_Checker, tok: Token, op: Token_Type, left, right: ^Type) -> ^Type {
	#partial switch op {
	case .Plus_Equal, .Minus_Equal, .Slash_Equal, .Percent_Equal:
		check_numeric_operand(tc, tok, left)
		check_numeric_operand(tc, tok, right)
		return numeric_result(left, right)
	case .Star_Equal:
		if left.kind == .Dynamic || right.kind == .Dynamic {
			return dynamic_type() // see typecheck_binary's .Star case
		}
		if is_string_repeat_operands(left, right) {
			return string_type()
		}
		check_numeric_operand(tc, tok, left)
		check_numeric_operand(tc, tok, right)
		return numeric_result(left, right)
	}
	return dynamic_type()
}

// -----------------------------------------------------------------------
// Calls

// typecheck_call resolves the callee's type via the ordinary Expr
// synthesis above (an Expr_Variable naming an already-type-checked
// Stmt_Function_Decl/Expr_Lambda synthesizes exactly the Func type that
// declaration built -- see typecheck_stmt.odin's build_func_type/Stmt_
// Function_Decl case -- so no separate memoized-lookup path is needed
// here beyond what Expr_Variable already does), then checks each
// position both sides have in common. A call with more args than
// declared params (absorbed by a `*rest` parameter) or fewer (covered by
// defaults) is never flagged as an arity mismatch in Phase 2 -- only
// positions that exist on both sides are compared, matching the
// implementation plan's own scope for this phase.
@(private = "file")
typecheck_call :: proc(tc: ^Type_Checker, call: ^Expr_Call) -> ^Type {
	callee_type := typecheck_expr(tc, call.callee)

	for a, i in call.args {
		arg_type := typecheck_expr(tc, a)
		if callee_type.kind == .Func && i < len(callee_type.func_params) {
			if !types_compatible(callee_type.func_params[i], arg_type) {
				diagnose(
					tc,
					expr_token(a),
					fmt.tprintf(
						"argument %d: expected %s, got %s",
						i + 1,
						type_string(callee_type.func_params[i]),
						type_string(arg_type),
					),
				)
			}
		}
	}

	if callee_type.kind == .Func {
		return callee_type.func_return
	}
	return dynamic_type()
}

// -----------------------------------------------------------------------
// Subscript / list / dict

// typecheck_subscript always visits every sub-expression Expr_Subscript
// might carry (index.odin's own emit path is the read/write/slice/
// slice-write four-way split this mirrors), regardless of which shape
// this particular node is -- typecheck_expr(tc, nil) is a harmless no-op,
// see its own guard clause above.
@(private = "file")
typecheck_subscript :: proc(tc: ^Type_Checker, v: ^Expr_Subscript) -> ^Type {
	obj_type := typecheck_expr(tc, v.object)
	typecheck_expr(tc, v.index)
	typecheck_expr(tc, v.slice_start)
	typecheck_expr(tc, v.slice_end)
	typecheck_expr(tc, v.assign_value)

	if v.is_slice {
		// A slice of a List[T]/Dict[K,V] is the same collection type.
		if obj_type.kind == .List || obj_type.kind == .Dict {
			return obj_type
		}
		return dynamic_type()
	}

	#partial switch obj_type.kind {
	case .List:
		return obj_type.list_elem
	case .Dict:
		return obj_type.dict_value
	}
	return dynamic_type()
}

// typecheck_list/typecheck_dict unify their elements' types pairwise: all
// entries agreeing on a type synthesizes List[T]/Dict[K,V]; any
// disagreement (or no entries at all) degrades to List[Dynamic]/
// Dict[Dynamic,Dynamic] -- unification failure degrades, it never
// errors, matching this phase's warnings-only, never-over-tighten
// contract. Every element is still visited for its own diagnostics
// regardless of what the running unification has already degraded to.

@(private = "file")
typecheck_list :: proc(tc: ^Type_Checker, v: ^Expr_List) -> ^Type {
	if len(v.elements) == 0 {
		return new_clone(Type{kind = .List, list_elem = dynamic_type()})
	}
	elem := typecheck_expr(tc, v.elements[0])
	for el in v.elements[1:] {
		t := typecheck_expr(tc, el)
		if !types_equal(elem, t) {
			elem = dynamic_type()
		}
	}
	return new_clone(Type{kind = .List, list_elem = elem})
}

@(private = "file")
typecheck_dict :: proc(tc: ^Type_Checker, v: ^Expr_Dict) -> ^Type {
	if len(v.entries) == 0 {
		return new_clone(Type{kind = .Dict, dict_key = dynamic_type(), dict_value = dynamic_type()})
	}
	key := typecheck_expr(tc, v.entries[0].key)
	value := typecheck_expr(tc, v.entries[0].value)
	for entry in v.entries[1:] {
		k := typecheck_expr(tc, entry.key)
		val := typecheck_expr(tc, entry.value)
		if !types_equal(key, k) {
			key = dynamic_type()
		}
		if !types_equal(value, val) {
			value = dynamic_type()
		}
	}
	return new_clone(Type{kind = .Dict, dict_key = key, dict_value = value})
}
