package compiler

import "core:testing"

// Direct Type_Checker tests: warnings-only diagnostics against known-good/
// known-bad programs, exercising typecheck_program directly rather than
// through Compile()'s full pipeline -- same rationale as resolve_test.
// odin's own parse_and_resolve helper, one layer further down the
// pipeline (parse -> resolve -> typecheck).

@(private = "file")
parse_resolve_typecheck :: proc(t: ^testing.T, source: string) -> (stmts: []Stmt, diagnostics: []Type_Diagnostic) {
	scn := tokenize(source)
	p := Parser{scn = &scn, filename = "test.lox"}
	advance(&p)
	list: [dynamic]Stmt
	for !match(&p, .Eof) {
		s := declaration(&p)
		if s != nil {
			append(&list, s)
		}
	}
	testing.expectf(t, !p.had_error, "expected %q to parse without error", source)
	stmts = list[:]
	_, had_error := resolve_program(stmts)
	testing.expectf(t, !had_error, "expected %q to resolve without error", source)
	diagnostics = typecheck_program(stmts)
	return
}

@(test)
test_typecheck_wrong_argument_type_to_annotated_function :: proc(t: ^testing.T) {
	_, diags := parse_resolve_typecheck(t, "func add(x: int, y: int) -> int {\nreturn x + y\n}\nadd(1, \"two\")")
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic, got %d: %v", len(diags), diags)
	if len(diags) == 1 {
		testing.expect(t, diags[0].token.line == 4, "expected the diagnostic anchored at the bad call's own line")
	}
}

@(test)
test_typecheck_wrong_return_type_from_annotated_function :: proc(t: ^testing.T) {
	_, diags := parse_resolve_typecheck(t, "func greet() -> string {\nreturn 42\n}")
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic, got %d: %v", len(diags), diags)
}

@(test)
test_typecheck_incompatible_assign_to_annotated_var_diagnoses :: proc(t: ^testing.T) {
	_, diags := parse_resolve_typecheck(t, "var x: int = 1\nx = \"hello\"")
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic, got %d: %v", len(diags), diags)
}

// The gradual-typing escape valve: an unannotated var's slot always stays
// Dynamic, so reassigning it to a different type never diagnoses --
// worth its own test precisely because it's the easiest thing to
// accidentally over-tighten later (see typecheck_stmt.odin's own header
// comment on why an unannotated var's *inferred* initializer type is
// deliberately never persisted for this reason).
@(test)
test_typecheck_assign_to_unannotated_var_never_diagnoses :: proc(t: ^testing.T) {
	_, diags := parse_resolve_typecheck(t, "var x = 1\nx = \"hello\"\nx = true")
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics for an unannotated var, got %v", diags)
}

// A call through an unannotated (Dynamic) parameter never diagnoses, even
// when the actual runtime value would mismatch -- the gradual-typing
// contract, worth a test precisely because it's the easiest thing to
// accidentally over-tighten later.
@(test)
test_typecheck_call_through_unannotated_param_never_diagnoses :: proc(t: ^testing.T) {
	_, diags := parse_resolve_typecheck(t, "func f(x) {\nreturn x\n}\nf(\"anything goes\")")
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics through an unannotated param, got %v", diags)
}

// Nested/lambda functions type-check independently: an inner function's
// param type doesn't leak into an outer variable of the same slot number
// in a different function -- exercises Local_Type_Scope.enclosing's own
// chaining (a fresh scope per function activation, not shared).
@(test)
test_typecheck_nested_function_params_dont_leak_slots :: proc(t: ^testing.T) {
	source := `
func outer(a: int) -> int {
	func inner(a: string) -> string {
		return a
	}
	return a
}
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics, got %v", diags)
}

// Same shape, but via an upvalue read instead of a same-named shadow --
// exercises lookup_upvalue_type's walk through Function_Decl.upvalues
// rather than a same-scope slot lookup.
@(test)
test_typecheck_upvalue_read_sees_enclosing_annotated_type :: proc(t: ^testing.T) {
	source := `
func outer() {
	var x: int = 1
	func inner() {
		x = "bad"
	}
	inner()
}
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic (upvalue write through an annotated int), got %d: %v", len(diags), diags)
}

// A representative unannotated sample -- the gradual-typing "must not
// break every untouched script" invariant, made concrete as a test
// rather than left as an assertion in prose.
@(test)
test_typecheck_unannotated_sample_has_zero_diagnostics :: proc(t: ^testing.T) {
	source := `
class Animal {
	__init__(name) {
		this.name = name
	}
	speak() {
		return "..."
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
var animals = [Animal("Rex")]
var pair = {"a": 1, "b": 2}
for (i = 0; i < 3; i = i + 1) {
	print i
}
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics on an unannotated sample, got %v", diags)
}

// List/Dict literal element-type unification, verified black-box through
// an annotated var: if [1, 2, 3] didn't correctly narrow to List[int]
// (e.g. if literal synthesis always degraded straight to List[Dynamic]),
// assigning it to a mismatched List[string]-annotated var would wrongly
// pass silently -- so a diagnostic firing here is proof unification
// narrowed correctly, not just that *something* got checked.
@(test)
test_typecheck_list_literal_unification :: proc(t: ^testing.T) {
	_, uniform_ok := parse_resolve_typecheck(t, "var xs: List[int] = [1, 2, 3]")
	testing.expectf(t, len(uniform_ok) == 0, "expected a matching List[int] annotation to never diagnose, got %v", uniform_ok)

	_, uniform_mismatch := parse_resolve_typecheck(t, "var xs: List[string] = [1, 2, 3]")
	testing.expectf(t, len(uniform_mismatch) == 1, "expected List[string] = [1,2,3] to diagnose an element-type mismatch, got %v", uniform_mismatch)

	// Mixed-element list unification failure degrades to List[Dynamic]
	// rather than erroring -- so it's still silently compatible with any
	// annotation, unannotated or not.
	_, mixed := parse_resolve_typecheck(t, "var ys: List[string] = [1, \"two\", 3]")
	testing.expectf(t, len(mixed) == 0, "expected mixed-element list unification to degrade without diagnosing, got %v", mixed)
}

@(test)
test_typecheck_dict_literal_unification :: proc(t: ^testing.T) {
	_, uniform_ok := parse_resolve_typecheck(t, `var d: Dict[string, int] = {"a": 1, "b": 2}`)
	testing.expectf(t, len(uniform_ok) == 0, "expected a matching Dict[string,int] annotation to never diagnose, got %v", uniform_ok)

	_, uniform_mismatch := parse_resolve_typecheck(t, `var d: Dict[string, string] = {"a": 1, "b": 2}`)
	testing.expectf(t, len(uniform_mismatch) == 1, "expected a Dict[string,string] annotation against int values to diagnose, got %v", uniform_mismatch)

	_, mixed := parse_resolve_typecheck(t, `var e: Dict[string, string] = {"a": 1, "b": "two"}`)
	testing.expectf(t, len(mixed) == 0, "expected mixed-value dict unification to degrade without diagnosing, got %v", mixed)
}

// This phase's own implementation surfaced a real gap between the
// implementation plan's prose and this VM's actual runtime semantics
// (see typecheck_expr.odin's typecheck_binary header comment, verified
// against vm/arithmetic.odin directly): `+` never concatenates strings
// here (only `&` does), and `*` additionally accepts (String, Int) for
// string repetition. Pinned down as tests so a future refactor can't
// silently regress back to the plan's incorrect assumption.
@(test)
test_typecheck_string_repeat_and_plus_match_runtime_semantics :: proc(t: ^testing.T) {
	_, repeat_diags := parse_resolve_typecheck(t, `print "-" * 10`)
	testing.expectf(t, len(repeat_diags) == 0, "expected string*int repetition to never diagnose, got %v", repeat_diags)

	_, plus_diags := parse_resolve_typecheck(t, `print "a" + "b"`)
	testing.expectf(t, len(plus_diags) > 0, "expected '+' on two strings to diagnose -- this VM never allows string concatenation via '+', only '&'")
}
