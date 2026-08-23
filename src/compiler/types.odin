package compiler

import "core:fmt"
import "core:strings"

// The type lattice for optional type annotations (docs/plans/
// optional-type-checking-implementation.md): gradual typing, where
// `Dynamic` (an unannotated site) is compatible with everything in both
// directions. Deliberately pure data plus a handful of predicates over
// it, no AST dependency beyond Type_Expr itself (type_from_expr) -- the
// rest is unit-testable without ever building a Parser/Resolver.
// `Class_Type` (referenced from `Type.class_type` below) is defined in
// typecheck_class.odin, not here, since building one needs Stmt_Class_
// Decl/Method -- this file deliberately doesn't depend on the AST beyond
// Type_Expr itself. (type_from_expr *does* take a ^Type_Checker, since a
// class name in an annotation needs tc.classes to resolve to anything
// but Dynamic -- the one place this file isn't fully self-contained.)
Type_Kind :: enum {
	Dynamic, // top: bidirectionally compatible with everything
	Nil,
	Bool,
	Int,
	Float,
	String,
	List, // element type in .list_elem; Dynamic in v1 (generic args parsed but not propagated beyond one level -- see Scope in the implementation plan)
	Dict, // key/value types in .dict_key/.dict_value; Dynamic in v1
	Func, // .func_params/.func_return
	Class, // .class_type -- represents *both* "the class itself" (a bare class-name reference, e.g. Expr_Call's callee -- see typecheck_expr.odin's typecheck_call) and "an instance of this class" (this/super, a constructor call's own result, an annotation naming a class), one shared representation per the design doc; nothing needs to tell the two apart, since the only things that ever consult a .Class Type are a callee-kind check (constructor-call detection) and field/method lookups (only ever meaningful for an instance) -- see typecheck_class.odin.
}

Type :: struct {
	kind:        Type_Kind,
	nilable:     bool, // from a `?` suffix -- orthogonal to kind: `int?` is Type{kind = .Int, nilable = true}, not a separate kind
	list_elem:   ^Type, // meaningful only for .List
	dict_key:    ^Type, // meaningful only for .Dict
	dict_value:  ^Type, // meaningful only for .Dict
	func_params: []^Type, // meaningful only for .Func
	func_return: ^Type, // meaningful only for .Func; never nil for a .Func Type (Dynamic when the function's own return type is unannotated -- see typecheck_stmt.odin's build_func_type)
	class_type:  ^Class_Type, // meaningful only for .Class
}

// -----------------------------------------------------------------------
// Constructors -- every Type is heap-allocated fresh (no canonical
// singleton instances), so comparisons throughout this package are always
// by field (kind/nilable/...), never by pointer identity.

dynamic_type :: proc() -> ^Type {return new_clone(Type{kind = .Dynamic})}
nil_type :: proc() -> ^Type {return new_clone(Type{kind = .Nil})}
bool_type :: proc() -> ^Type {return new_clone(Type{kind = .Bool})}
int_type :: proc() -> ^Type {return new_clone(Type{kind = .Int})}
float_type :: proc() -> ^Type {return new_clone(Type{kind = .Float})}
string_type :: proc() -> ^Type {return new_clone(Type{kind = .String})}

// -----------------------------------------------------------------------
// type_from_expr -- resolves a parsed Type_Expr into a checked Type. A
// name that isn't one of the primitives below is looked up in tc.classes
// (the class-name table, already fully populated by the time any
// annotation is resolved -- see typecheck_class.odin's
// typecheck_collect_class_signatures, which runs before anything else);
// still-unrecognized names (a typo, a name that was never a class)
// synthesize Dynamic.

@(private = "file")
primitive_kind :: proc(name: string) -> (kind: Type_Kind, ok: bool) {
	switch name {
	case "int":
		return .Int, true
	case "float":
		return .Float, true
	case "string":
		return .String, true
	case "bool":
		return .Bool, true
	}
	return .Dynamic, false
}

type_from_expr :: proc(tc: ^Type_Checker, te: ^Type_Expr) -> ^Type {
	if te == nil {
		return dynamic_type()
	}
	switch te.kind {
	case .Named:
		name := lexeme(te.name)
		if kind, ok := primitive_kind(name); ok {
			return new_clone(Type{kind = kind})
		}
		if ct, ok := tc.classes[name]; ok {
			return new_clone(Type{kind = .Class, class_type = ct})
		}
		// A from-imported class is registered into tc.classes directly, up
		// front, by typecheck_register_imported_classes (typecheck_stmt.
		// odin) before this ever runs -- so no separate resolver
		// consultation belongs here; the lookup above already covers it.
		return dynamic_type()
	case .Generic:
		elem := type_from_expr(tc, te.args[0]) if len(te.args) > 0 else dynamic_type()
		switch lexeme(te.name) {
		case "List":
			return new_clone(Type{kind = .List, list_elem = elem})
		case "Dict":
			value := type_from_expr(tc, te.args[1]) if len(te.args) > 1 else dynamic_type()
			return new_clone(Type{kind = .Dict, dict_key = elem, dict_value = value})
		case:
			return dynamic_type() // an unrecognized generic name -- out of scope for v1, see the implementation plan's Scope section
		}
	case .Nilable:
		inner := type_from_expr(tc, te.inner)
		result := inner^
		result.nilable = true
		return new_clone(result)
	}
	return dynamic_type()
}

// -----------------------------------------------------------------------
// types_compatible -- the core of gradual typing: true whenever either
// side is nil (no annotation) or Dynamic, or actual is Nil and expected
// accepts nil, or both sides structurally agree; false otherwise. Used
// both for "does this value fit this annotated site" (assignment,
// argument, return) checks.

types_compatible :: proc(expected, actual: ^Type) -> bool {
	if expected == nil || actual == nil {
		return true
	}
	if expected.kind == .Dynamic || actual.kind == .Dynamic {
		return true
	}
	if actual.kind == .Nil {
		return expected.nilable || expected.kind == .Nil
	}
	if expected.kind != actual.kind {
		return false
	}
	#partial switch expected.kind {
	case .List:
		return types_compatible(expected.list_elem, actual.list_elem)
	case .Dict:
		return types_compatible(expected.dict_key, actual.dict_key) && types_compatible(expected.dict_value, actual.dict_value)
	case .Func:
		if len(expected.func_params) != len(actual.func_params) {
			return false
		}
		for i in 0 ..< len(expected.func_params) {
			if !types_compatible(expected.func_params[i], actual.func_params[i]) {
				return false
			}
		}
		return types_compatible(expected.func_return, actual.func_return)
	case .Class:
		// Nominal, but substitutable up the inheritance chain -- a Dog
		// instance fits wherever an Animal is expected (ordinary OOP
		// substitutability), not just an exact same-class match. Two
		// unrelated classes with identically-shaped methods are still
		// incompatible (nominal, not structural) -- the design doc's own
		// "cost of nominal types" example, verified as intentional.
		for c := actual.class_type; c != nil; c = c.superclass {
			if c == expected.class_type {
				return true
			}
		}
		return false
	}
	return true
}

// types_equal is stricter than types_compatible (no Dynamic escape hatch)
// -- used to unify branches (Expr_Logical/Expr_Conditional's "same type on
// both sides degrades to Dynamic when they differ" rule, list/dict
// literal element unification), where the question is "are these actually
// the same type", not "does a value of one type fit where the other is
// expected".
types_equal :: proc(a, b: ^Type) -> bool {
	if a == nil || b == nil {
		return a == b
	}
	if a.kind != b.kind || a.nilable != b.nilable {
		return false
	}
	#partial switch a.kind {
	case .List:
		return types_equal(a.list_elem, b.list_elem)
	case .Dict:
		return types_equal(a.dict_key, b.dict_key) && types_equal(a.dict_value, b.dict_value)
	case .Func:
		if len(a.func_params) != len(b.func_params) {
			return false
		}
		for i in 0 ..< len(a.func_params) {
			if !types_equal(a.func_params[i], b.func_params[i]) {
				return false
			}
		}
		return types_equal(a.func_return, b.func_return)
	case .Class:
		// Strict here, unlike types_compatible -- unification (this
		// proc's only caller) asks "are these provably the exact same
		// type", not "does a value of one fit where the other is
		// expected", so no subclass-substitutability allowance.
		return a.class_type == b.class_type
	}
	return true
}

// union_type is Expr_Logical/Expr_Conditional's own rule: the same type on
// both branches, else Dynamic (matches runtime -- either branch's value
// can flow out, so a static type only survives if both branches agree).
union_type :: proc(a, b: ^Type) -> ^Type {
	if types_equal(a, b) {
		return a
	}
	return dynamic_type()
}

// -----------------------------------------------------------------------
// type_string -- diagnostic formatting, mirroring Type_Expr surface
// syntax (see ast_print.odin's print_type_expr for the parsed-side
// equivalent): `int`, `List[int]`, `int?`, `func(int, int) -> string`.

type_string :: proc(t: ^Type) -> string {
	if t == nil {
		return "dynamic"
	}
	base: string
	#partial switch t.kind {
	case .Dynamic:
		base = "dynamic"
	case .Nil:
		base = "nil"
	case .Bool:
		base = "bool"
	case .Int:
		base = "int"
	case .Float:
		base = "float"
	case .String:
		base = "string"
	case .List:
		base = fmt.tprintf("List[%s]", type_string(t.list_elem))
	case .Dict:
		base = fmt.tprintf("Dict[%s, %s]", type_string(t.dict_key), type_string(t.dict_value))
	case .Func:
		parts := make([dynamic]string, 0, len(t.func_params))
		for p in t.func_params {
			append(&parts, type_string(p))
		}
		base = fmt.tprintf("func(%s) -> %s", strings.join(parts[:], ", "), type_string(t.func_return))
	case .Class:
		base = t.class_type.name if t.class_type != nil else "class"
	}
	return fmt.tprintf("%s?", base) if t.nilable else base
}
