package compiler

import "core:testing"

// Direct tests for Typecheck_Module_Signature/build_module_signature --
// no file I/O, no vm package, no real resolver: these exercise the
// compiler-package half of cross-module type checking in isolation. See
// typecheck_test.odin's cross-module consultation tests for the other
// half (a fake Resolve_Module_Proc standing in for a real module lookup).

@(test)
test_module_signature_extracts_top_level_bindings :: proc(t: ^testing.T) {
	source := `
func add(x: int, y: int) -> int {
	return x + y
}
var count: int = 0
class Animal {
	__init__(name: string) {
		this.name = name
	}
}
`
	sig, diags, ok := Typecheck_Module_Signature("animals", source, "animals.lox")
	testing.expect(t, ok, "expected Typecheck_Module_Signature to succeed")
	testing.expectf(t, len(diags) == 0, "expected zero diagnostics on a clean module, got %v", diags)
	testing.expect_value(t, sig.name, "animals")

	add_type, has_add := sig.vars["add"]
	testing.expect(t, has_add, "expected 'add' in the module's own vars")
	if has_add {
		testing.expect_value(t, add_type.kind, Type_Kind.Func)
		testing.expect(t, len(add_type.func_params) == 2)
	}

	count_type, has_count := sig.vars["count"]
	testing.expect(t, has_count, "expected 'count' in the module's own vars")
	if has_count {
		testing.expect_value(t, count_type.kind, Type_Kind.Int)
	}

	_, has_class_var := sig.vars["Animal"]
	testing.expect(t, has_class_var, "expected the class's own top-level binding in vars too")

	animal_class, has_class := sig.classes["Animal"]
	testing.expect(t, has_class, "expected 'Animal' in the module's own classes")
	if has_class {
		_, has_init := animal_class.methods["__init__"]
		testing.expect(t, has_init)
	}
}

@(test)
test_module_signature_omits_undeclared_and_local_names :: proc(t: ^testing.T) {
	// Only genuinely top-level, declared bindings are exported -- a local
	// inside a function body must not leak into the module's own signature.
	source := `
func f() {
	var local_var = 1
	return local_var
}
`
	sig, _, ok := Typecheck_Module_Signature("m", source, "m.lox")
	testing.expect(t, ok)
	_, has_local := sig.vars["local_var"]
	testing.expect(t, !has_local, "expected a function-local var to be absent from the module's own signature")
	_, has_f := sig.vars["f"]
	testing.expect(t, has_f, "expected the top-level function itself to be present")
}

@(test)
test_typecheck_module_signature_fails_on_parse_error :: proc(t: ^testing.T) {
	_, _, ok := Typecheck_Module_Signature("broken", "func f( {\n", "broken.lox")
	testing.expect(t, !ok, "expected a genuine parse error to fail Typecheck_Module_Signature")
}

@(test)
test_typecheck_module_signature_fails_on_resolve_error :: proc(t: ^testing.T) {
	_, _, ok := Typecheck_Module_Signature("broken", "break\n", "broken.lox") // break outside any loop
	testing.expect(t, !ok, "expected a genuine resolve error to fail Typecheck_Module_Signature")
}
