package compiler

import "core:testing"

// parse_and_resolve is resolve_test.odin's own helper, duplicated here
// (file-private there, so can't be shared directly -- same convention
// emit_test.odin's own header comment documents for compile_test.odin's
// decode()/op_sequence()/contains_op()).
@(private = "file")
parse_and_resolve :: proc(t: ^testing.T, source: string) -> (stmts: []Stmt, globals: Global_Table, had_error: bool) {
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
	globals, had_error = resolve_program(stmts)
	return
}

// Tests for compile-time-baked instance field slots (resolve.odin's
// discover_field_slots) -- TODO.md's Phase 7 "compile-time-baked
// instance field slots" item. discover_field_slots only ever looks at
// top-level, unconditional, plain-assignment `this.name = value`
// statements inside a class's own init -- these tests pin down exactly
// which shapes qualify and which fall back to the ordinary map path
// unchanged.

@(test)
test_resolve_class_init_top_level_fields_get_slots :: proc(t: ^testing.T) {
	// count/total, not a/b -- a and b are themselves swizzle-component
	// names (r/g/b/a), which must never get a slot; see
	// test_resolve_swizzle_named_field_never_gets_a_slot below.
	stmts, _, had_error := parse_and_resolve(t, "class P {\ninit(count, total) {\nthis.count = count\nthis.total = total\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 2, "expected 2 discovered slots, got %d", len(class.field_slot_names))
	testing.expect(t, class.field_slot_names[0] == "count")
	testing.expect(t, class.field_slot_names[1] == "total")

	init_method := class.members[0].(^Method)
	set_a, a_ok := init_method.decl.body[0].(^Stmt_Expression).expr.(^Expr_Property)
	testing.expect(t, a_ok)
	testing.expect(t, set_a.field_slot == 0)
	set_b, b_ok := init_method.decl.body[1].(^Stmt_Expression).expr.(^Expr_Property)
	testing.expect(t, b_ok)
	testing.expect(t, set_b.field_slot == 1)
}

@(test)
test_resolve_conditional_field_assignment_gets_no_slot :: proc(t: ^testing.T) {
	// "flag", not a swizzle-component name, so this genuinely tests the
	// conditional-assignment exclusion, not the separate swizzle one.
	stmts, _, had_error := parse_and_resolve(t, "class P {\ninit(x) {\nif (x) {\nthis.flag = 1\n}\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 0, "expected no discovered slots, got %d", len(class.field_slot_names))

	init_method := class.members[0].(^Method)
	if_stmt := init_method.decl.body[0].(^Stmt_If)
	then_block := if_stmt.then_branch.(^Stmt_Block)
	set_flag, ok := then_block.stmts[0].(^Stmt_Expression).expr.(^Expr_Property)
	testing.expect(t, ok)
	testing.expect(t, set_flag.field_slot == -1, "a field assigned only inside a conditional must never resolve to a slot")
}

@(test)
test_resolve_field_assigned_in_non_init_method_gets_no_slot :: proc(t: ^testing.T) {
	// Mirrors tests/new_tests/lox/class_this.lox's real shape: a field
	// with no init at all, assigned only from an ordinary method.
	stmts, _, had_error := parse_and_resolve(t, "class P {\nmethod1(a) {\nthis.field1 = a\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 0, "expected no discovered slots (no init at all), got %d", len(class.field_slot_names))

	method := class.members[0].(^Method)
	set_field, ok := method.decl.body[0].(^Stmt_Expression).expr.(^Expr_Property)
	testing.expect(t, ok)
	testing.expect(t, set_field.field_slot == -1)
}

@(test)
test_resolve_compound_set_at_top_level_gets_no_slot :: proc(t: ^testing.T) {
	// this.count += 1 reads before writing -- can never be treated as
	// unconditionally *defining* the field, even though it's textually
	// at the top level of init. "count", not a swizzle-component name,
	// so this genuinely tests the compound-set exclusion.
	stmts, _, had_error := parse_and_resolve(t, "class P {\ninit() {\nthis.count += 1\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 0, "expected no discovered slots, got %d", len(class.field_slot_names))

	init_method := class.members[0].(^Method)
	compound_set, ok := init_method.decl.body[0].(^Stmt_Expression).expr.(^Expr_Property)
	testing.expect(t, ok)
	testing.expect(t, compound_set.kind == .Compound_Set)
	testing.expect(t, compound_set.field_slot == -1)
}

@(test)
test_resolve_swizzle_named_field_never_gets_a_slot :: proc(t: ^testing.T) {
	// this.x = x at the top level of init would otherwise qualify, but a
	// field literally named x/y/z/w/r/g/b/a must stay on the swizzle
	// write-back path (emit_expr.odin's emit_swizzle_set) entirely, in
	// case `this` ever turns out to hold a vector at runtime -- the
	// compiler can't know that here.
	stmts, _, had_error := parse_and_resolve(t, "class P {\ninit(x) {\nthis.x = x\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 0, "expected no discovered slots for a swizzle-shaped field name, got %d", len(class.field_slot_names))

	init_method := class.members[0].(^Method)
	set_x, ok := init_method.decl.body[0].(^Stmt_Expression).expr.(^Expr_Property)
	testing.expect(t, ok)
	testing.expect(t, set_x.field_slot == -1)
}

@(test)
test_resolve_invoke_never_gets_a_field_slot :: proc(t: ^testing.T) {
	// this.cb() must never be routed through the field-slot fast path,
	// even when "cb" is itself a discovered slot name (a callable stored
	// in a slot-optimized field, called later) -- Get_Field_Slot/
	// Set_Field_Slot only exist for .Get/.Set/.Compound_Set.
	stmts, _, had_error := parse_and_resolve(t, "class P {\ninit(fn) {\nthis.cb = fn\n}\nrun() {\nreturn this.cb()\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 1 && class.field_slot_names[0] == "cb", "expected exactly one discovered slot, \"cb\"")

	run_method := class.members[1].(^Method)
	ret := run_method.decl.body[0].(^Stmt_Return)
	invoke_expr, ok := ret.value.(^Expr_Property)
	testing.expect(t, ok)
	testing.expect(t, invoke_expr.kind == .Invoke)
	testing.expect(t, invoke_expr.field_slot == -1, "this.cb() must never resolve to a field slot, even though \"cb\" is itself a discovered slot name")
}

@(test)
test_resolve_if_else_both_branches_assigning_same_field_gets_a_slot :: proc(t: ^testing.T) {
	// Exactly benchmarks/lox/binary_trees.lox's own shape: a field
	// assigned in both branches of a top-level if/else is provably
	// always set, so it qualifies even though no single top-level
	// statement assigns it unconditionally.
	stmts, _, had_error := parse_and_resolve(t, "class T {\ninit(d) {\nif (d) {\nthis.left = 1\n} else {\nthis.left = 2\n}\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 1 && class.field_slot_names[0] == "left", "expected exactly one discovered slot, \"left\", got %v", class.field_slot_names)
}

@(test)
test_resolve_if_else_mismatched_branch_fields_get_no_slot :: proc(t: ^testing.T) {
	// Each branch assigns a *different* field -- neither is provably
	// always set (only one branch runs), so neither qualifies.
	stmts, _, had_error := parse_and_resolve(t, "class T {\ninit(d) {\nif (d) {\nthis.left = 1\n} else {\nthis.right = 2\n}\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 0, "expected no discovered slots, got %v", class.field_slot_names)
}

@(test)
test_resolve_if_with_no_else_still_gets_no_slot :: proc(t: ^testing.T) {
	// A bare if (no else) can never prove a field is always set, even
	// after the if/else extension -- trees.lox's own shape
	// (`if (depth > 0) { this.a = ... }`, no else).
	stmts, _, had_error := parse_and_resolve(t, "class T {\ninit(d) {\nif (d) {\nthis.a = 1\n}\n}\n}")
	testing.expect(t, !had_error)
	class := stmts[0].(^Stmt_Class_Decl)
	testing.expectf(t, len(class.field_slot_names) == 0, "expected no discovered slots, got %v", class.field_slot_names)
}

@(test)
test_resolve_field_slot_names_independent_per_subclass :: proc(t: ^testing.T) {
	// A subclass's own discovered slot table only ever reflects its own
	// init -- no compile-time splicing of the superclass's table (see
	// vm/run.odin's Get_Field_Slot/Set_Field_Slot owner_class guard,
	// which is what makes this safe under inheritance instead).
	stmts, _, had_error := parse_and_resolve(t, "class Animal {\ninit(name) {\nthis.name = name\n}\n}\nclass Dog < Animal {\ninit(name, breed) {\nsuper.init(name)\nthis.breed = breed\n}\n}")
	testing.expect(t, !had_error)
	animal := stmts[0].(^Stmt_Class_Decl)
	dog := stmts[1].(^Stmt_Class_Decl)
	testing.expectf(t, len(animal.field_slot_names) == 1 && animal.field_slot_names[0] == "name", "expected Animal's own slot table to be [\"name\"]")
	testing.expectf(t, len(dog.field_slot_names) == 1 && dog.field_slot_names[0] == "breed", "expected Dog's own slot table to be [\"breed\"] only -- not splicing in Animal's \"name\"")
}
