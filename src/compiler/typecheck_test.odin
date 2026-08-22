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

// This feature's own implementation surfaced a real gap between the
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

// -----------------------------------------------------------------------
// Class support

@(test)
test_typecheck_misspelled_method_call_diagnoses :: proc(t: ^testing.T) {
	source := `
class Circle {
	area() -> float {
		return 1.0
	}
}
var c = Circle()
c.aera()
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic for a misspelled method call, got %d: %v", len(diags), diags)
}

@(test)
test_typecheck_wrong_arg_type_to_method_and_constructor :: proc(t: ^testing.T) {
	source := `
class Box {
	__init__(value: int) {
		this.value = value
	}
	add(n: int) -> int {
		return this.value + n
	}
}
var b = Box("not an int")
b.add("also not an int")
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 2, "expected one diagnostic for the constructor call and one for the method call, got %d: %v", len(diags), diags)
}

@(test)
test_typecheck_wrong_return_type_from_annotated_method :: proc(t: ^testing.T) {
	source := `
class Greeter {
	greet() -> string {
		return 42
	}
}
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic, got %d: %v", len(diags), diags)
}

@(test)
test_typecheck_field_type_from_init_checked_everywhere_else_is_open :: proc(t: ^testing.T) {
	// Once __init__ establishes a field's type, an incompatible assignment
	// anywhere else in the class is diagnosed...
	bad := `
class Counter {
	__init__() {
		this.n = 0
	}
	reset() {
		this.n = "zero"
	}
}
`
	_, bad_diags := parse_resolve_typecheck(t, bad)
	testing.expectf(t, len(bad_diags) == 1, "expected exactly one diagnostic, got %d: %v", len(bad_diags), bad_diags)

	// ...but a field *never* mentioned in __init__, assigned dynamically
	// from outside the class, is the open-field escape valve -- zero
	// diagnostics, explicitly tested to prevent regression toward
	// over-tightening.
	open_field := `
class Bag {
	__init__() {
	}
}
var b = Bag()
b.anything = "whatever"
b.anything = 123
`
	_, open_diags := parse_resolve_typecheck(t, open_field)
	testing.expectf(t, len(open_diags) == 0, "expected zero diagnostics for a field never mentioned in __init__, got %v", open_diags)
}

@(test)
test_typecheck_override_compatibility :: proc(t: ^testing.T) {
	incompatible := `
class Animal {
	speak(volume: int) -> string {
		return "..."
	}
}
class Dog < Animal {
	speak(volume: int, extra: int) -> int {
		return volume + extra
	}
}
`
	_, incompatible_diags := parse_resolve_typecheck(t, incompatible)
	testing.expectf(t, len(incompatible_diags) == 1, "expected exactly one diagnostic for an incompatible override, got %d: %v", len(incompatible_diags), incompatible_diags)

	compatible := `
class Animal {
	speak(volume: int) -> string {
		return "..."
	}
}
class Dog < Animal {
	speak(volume: int) -> string {
		return "woof"
	}
}
`
	_, compatible_diags := parse_resolve_typecheck(t, compatible)
	testing.expectf(t, len(compatible_diags) == 0, "expected zero diagnostics for a compatible override, got %v", compatible_diags)

	unannotated := `
class Animal {
	speak(volume: int) -> string {
		return "..."
	}
}
class Dog < Animal {
	speak(volume) {
		return "woof"
	}
}
`
	_, unannotated_diags := parse_resolve_typecheck(t, unannotated)
	testing.expectf(t, len(unannotated_diags) == 0, "expected zero diagnostics when the override leaves its own param/return unannotated, got %v", unannotated_diags)

	// A constructor is exempt from override-compatibility checking
	// entirely -- never called polymorphically, so a subclass's __init__
	// legitimately takes a completely different parameter list.
	init_override := `
class Animal {
	__init__(name: string) {
		this.name = name
	}
}
class Dog < Animal {
	__init__(name: string, breed: string) {
		super.__init__(name)
		this.breed = breed
	}
}
`
	_, init_diags := parse_resolve_typecheck(t, init_override)
	testing.expectf(t, len(init_diags) == 0, "expected zero diagnostics for an __init__ override with a different arity, got %v", init_diags)
}

// class Foo < Bar where Bar is declared *after* Foo in source order --
// exercises the fixpoint/recursive-flattening pass's ordering
// independence directly, the scenario resolve_class_decl's own doc
// comment calls out as legal today via ordinary variable resolution.
@(test)
test_typecheck_superclass_declared_after_subclass_still_flattens :: proc(t: ^testing.T) {
	source := `
class Foo < Bar {
	callBase() -> int {
		return this.base()
	}
}
class Bar {
	base() -> int {
		return 1
	}
}
var f = Foo()
f.base()
f.notAMethod()
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic (the genuinely missing method), got %d: %v", len(diags), diags)
}

// Nominal mismatch: two unrelated classes with identically-shaped
// methods are still incompatible where an annotated parameter names one
// specific class -- the design doc's "cost of nominal types" example,
// verified as intentional-by-design rather than accidentally over-strict.
@(test)
test_typecheck_nominal_mismatch_between_unrelated_classes :: proc(t: ^testing.T) {
	source := `
class Point {
	__init__(x: int) {
		this.x = x
	}
}
class Vector {
	__init__(x: int) {
		this.x = x
	}
}
func takesPoint(p: Point) {
	return p
}
takesPoint(Vector(1))
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic for a nominal type mismatch, got %d: %v", len(diags), diags)
}

// A subclass instance fits wherever a superclass-typed parameter is
// expected (ordinary OOP substitutability) -- the flip side of the
// nominal-mismatch test above: nominal, but not *exact-match-only*.
@(test)
test_typecheck_subclass_instance_satisfies_superclass_annotation :: proc(t: ^testing.T) {
	source := `
class Animal {
}
class Dog < Animal {
}
func takesAnimal(a: Animal) {
	return a
}
takesAnimal(Dog())
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics -- a Dog satisfies an Animal-typed parameter, got %v", diags)
}

// this/super typing inside a method resolves to the right Class_Type,
// including a method inherited (flattened) into a subclass and invoked
// via super.method() -- and a wrong-typed argument through super.method
// is still caught.
@(test)
test_typecheck_this_and_super_resolve_correctly :: proc(t: ^testing.T) {
	source := `
class Animal {
	speak(volume: int) -> string {
		return "..."
	}
}
class Dog < Animal {
	speak(volume: int) -> string {
		return super.speak(volume)
	}
	bad_speak() -> string {
		return super.speak("not an int")
	}
}
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic (bad_speak's wrong-typed super call), got %d: %v", len(diags), diags)
}

// A callable stored in a field is invoked via `this.fn(...)`/`obj.fn(...)`
// -- a real runtime-supported pattern (see vm/call.odin's field-shadow
// check in invoke) that must never be treated as a missing method, even
// though `fn` isn't in Class_Type.methods at all.
@(test)
test_typecheck_callable_field_invoke_never_diagnoses_as_missing_method :: proc(t: ^testing.T) {
	source := `
class Runner {
	__init__(fn) {
		this.fn = fn
	}
	run(x) {
		return this.fn(x)
	}
}
var r = Runner(func(n) { return n * 10 })
print r.run(5)
print r.fn(4)
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics for a callable stored in a field, got %v", diags)
}

// A static method called via the bare class name (`ClassName.method()`)
// must be checked against Class_Type.static_methods, not .methods --
// a real false positive this surfaced against the corpus (logging.lox's
// own `Logger.level_name(...)`).
@(test)
test_typecheck_static_method_call_via_class_name :: proc(t: ^testing.T) {
	source := `
class MathHelper {
	static square(x: int) -> int {
		return x * x
	}
}
print MathHelper.square(5)
print MathHelper.square("not an int")
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic (the bad argument), got %d: %v", len(diags), diags)
}

// A superclass name that can't be resolved within this compilation unit
// (a genuine typo, or -- just as likely in practice -- a class imported
// from another module file, which typecheck_program can't see since it
// runs per-file) must not make the subclass's own methods table look
// falsely "closed" -- see Class_Type.methods_uncertain's own doc comment.
@(test)
test_typecheck_unresolvable_superclass_leaves_methods_open :: proc(t: ^testing.T) {
	source := `
class Widget < ExternalBase {
}
var w = Widget()
w.someMethodFromElsewhere()
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics -- an unresolvable superclass must not make .methods look falsely closed, got %v", diags)
}

// An unannotated var's inferred type (record_inferred_type/is_pinned,
// typecheck.odin) is *widened*, not enforced, on reassignment -- a real
// gap this feature's own implementation surfaced: without this, `var c =
// Circle()` (the overwhelmingly common, idiomatic way to hold an
// instance -- nobody writes `var c: Circle = Circle()`) would never get
// Class_Type-based checking at all, making every one of this feature's
// own class-checking catches unreachable in ordinary code. Reassigning
// `c` to an unrelated value must still never diagnose (the same escape
// valve already guaranteed for primitives).
@(test)
test_typecheck_unannotated_object_var_widens_on_reassignment :: proc(t: ^testing.T) {
	source := `
class Circle {
	area() -> float {
		return 1.0
	}
}
var c = Circle()
c.aera()
c = 5
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 1, "expected exactly one diagnostic (the misspelled method call, not the reassignment), got %d: %v", len(diags), diags)
}

// `this.x = nil` in __init__ is the standard "optional reference,
// assigned its real value later" idiom (a linked-list/tree node's own
// `next`/`left`/`right`) -- a real full-corpus false positive this
// surfaced (pickle_basic.lox's Node.next). Must not pin the field's
// type to "always nil", which would flag every legitimate later
// assignment of an actual value.
@(test)
test_typecheck_nil_initialized_field_stays_open :: proc(t: ^testing.T) {
	source := `
class Node {
	__init__(value) {
		this.value = value
		this.next = nil
	}
}
var a = Node(1)
var b = Node(2)
a.next = b
`
	_, diags := parse_resolve_typecheck(t, source)
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics -- nil-initialized fields must not be pinned to always-nil, got %v", diags)
}
