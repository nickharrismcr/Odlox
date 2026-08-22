package compiler

// Class support for optional type annotations (docs/plans/
// optional-type-checking-implementation.md). Class_Type is the per-class
// signature the rest of the checker consults (typecheck_expr.odin's
// Expr_This/Expr_Super/Expr_Property/typecheck_call, typecheck_stmt.
// odin's Stmt_Class_Decl case) -- built here in three passes before
// typecheck_program's ordinary statement walk even begins, since a class
// reference can appear anywhere in the program regardless of where (or
// whether, for a forward superclass reference) that class is declared.
Class_Type :: struct {
	name:              string,
	fields:            map[string]^Type, // open: a name never found here is Dynamic with no diagnostic (Instance_Object.fields genuinely accepts arbitrary runtime writes) -- see harvest_init_field_types for how a name gets in here at all
	methods:           map[string]^Type, // closed *unless* methods_uncertain (see below): a miss on Expr_Property's .Invoke (or a plain .Get naming a method) *is* a diagnostic -- flattened to include every inherited method too (see flatten_class), so no superclass walk is ever needed at a call site
	static_methods:    map[string]^Type, // NOT flattened -- do_inherit (vm/properties.odin) only ever copies .methods at runtime, never statics
	superclass:        ^Class_Type, // nil if no superclass, or if the superclass name didn't resolve to a known class -- degrades silently rather than erroring, matching do_inherit's own runtime-only "superclass must be a class" check
	overrides:         map[string]^Type, // name -> the superclass's own (pre-overlay) method type, for every name this class's own declared methods overlay during flattening -- consulted once, in typecheck_stmt.odin's typecheck_class_decl, to check override compatibility
	methods_uncertain: bool, // true when `class Foo < Bar` couldn't resolve Bar within *this compilation unit* -- typecheck_program runs per-file (see compile.odin), so a superclass imported from another module (`from other_module import Base`) is genuinely invisible to pass 1, not just "not yet built". .methods is then knowably *incomplete* (missing whatever the unresolved base would have contributed), so treating it as closed would be a guaranteed false positive on every inherited-but-unseen method -- propagates down the chain (a class whose superclass is itself uncertain is uncertain too), consulted by typecheck_expr.odin's typecheck_property (.Invoke) to suppress the "no method" diagnostic for this class specifically.
}

// -----------------------------------------------------------------------
// Pass 1 driver

// typecheck_collect_class_signatures builds every class's Class_Type in
// three steps, each needing the previous one fully done for every class
// first (not just the one at hand) -- see each step's own comment for
// why a single combined pass can't work:
//
//  1. register every class's *name* with a hollow (empty-map) Class_Type,
//     so any class name is resolvable via tc.classes/type_from_expr from
//     this point on, regardless of build order -- Class_Type is a
//     pointer, so a Type captured before step 2/3 fill it in still sees
//     the fully-populated version once anyone actually reads .fields/
//     .methods later (always in pass 2, well after this whole pass
//     completes).
//  2. populate each class's own, un-flattened members (its own methods'
//     Func types via build_func_type, its own field types harvested from
//     __init__) -- order-independent between classes, since step 1
//     already made every class name resolvable for any cross-class-
//     named param/return annotation a method signature might use.
//  3. link superclass relationships and flatten inherited fields/methods
//     in -- needs each class's *own* superclass already flattened first
//     (recursive, memoized, degrading a self/mutual cycle or an
//     unresolvable superclass name to "no inherited members" rather than
//     erroring or looping forever).
typecheck_collect_class_signatures :: proc(tc: ^Type_Checker, stmts: []Stmt) {
	decls := find_all_class_decls(stmts)
	class_decls := make(map[string]^Stmt_Class_Decl, len(decls))

	for decl in decls {
		name := lexeme(decl.name)
		tc.classes[name] = new_clone(
			Class_Type{
				name = name,
				fields = make(map[string]^Type),
				methods = make(map[string]^Type),
				static_methods = make(map[string]^Type),
				overrides = make(map[string]^Type),
			},
		)
		class_decls[name] = decl
	}

	for decl in decls {
		build_own_class_members(tc, tc.classes[lexeme(decl.name)], decl)
	}

	flattened := make(map[string]bool)
	in_progress := make(map[string]bool)
	for decl in decls {
		flatten_class(tc, tc.classes[lexeme(decl.name)], decl, class_decls, &flattened, &in_progress)
	}
}

// -----------------------------------------------------------------------
// Step 1 support: finding every Stmt_Class_Decl, at any statement-nesting
// depth (Lox allows local class declarations -- resolve.odin:1035
// handles both branches). Bounded to statement-level nesting (block/if/
// while/for/foreach/try bodies, function bodies, and a found class's own
// method bodies, since a method could itself declare a further-nested
// class) -- deliberately does *not* walk into arbitrary expression
// subtrees looking for a class declared inside e.g. a lambda used as a
// default-parameter value or a class-var initializer. Nothing in this
// codebase's own examples/tests corpus does that (verified against a
// full-corpus regression run), and the implementation plan's own test
// list doesn't exercise it either.

@(private = "file")
find_all_class_decls :: proc(stmts: []Stmt) -> []^Stmt_Class_Decl {
	out: [dynamic]^Stmt_Class_Decl
	collect_class_decls(stmts, &out)
	return out[:]
}

@(private = "file")
collect_class_decls :: proc(stmts: []Stmt, out: ^[dynamic]^Stmt_Class_Decl) {
	for s in stmts {
		collect_class_decls_stmt(s, out)
	}
}

@(private = "file")
collect_class_decls_stmt :: proc(s: Stmt, out: ^[dynamic]^Stmt_Class_Decl) {
	if s == nil {
		return
	}
	#partial switch v in s {
	case ^Stmt_Class_Decl:
		append(out, v)
		for member in v.members {
			if m, ok := member.(^Method); ok {
				collect_class_decls(m.decl.body, out)
			}
		}
	case ^Stmt_Block:
		collect_class_decls(v.stmts, out)
	case ^Stmt_If:
		collect_class_decls_stmt(v.then_branch, out)
		collect_class_decls_stmt(v.else_branch, out)
	case ^Stmt_While:
		collect_class_decls_stmt(v.body, out)
	case ^Stmt_For:
		collect_class_decls_stmt(v.body, out)
	case ^Stmt_Foreach:
		collect_class_decls_stmt(v.body, out)
	case ^Stmt_Try:
		collect_class_decls(v.body, out)
		for except in v.excepts {
			collect_class_decls(except.body, out)
		}
		if v.has_finally {
			collect_class_decls(v.finally_body, out)
		}
	case ^Stmt_Function_Decl:
		collect_class_decls(v.decl.body, out)
	}
}

// -----------------------------------------------------------------------
// Step 2 support: each class's own, un-flattened members.

@(private = "file")
build_own_class_members :: proc(tc: ^Type_Checker, ct: ^Class_Type, decl: ^Stmt_Class_Decl) {
	for member in decl.members {
		method, is_method := member.(^Method)
		if !is_method {
			continue
		}
		fn_type := build_func_type(tc, method.decl)
		if method.is_static {
			ct.static_methods[lexeme(method.name)] = fn_type
		} else {
			ct.methods[lexeme(method.name)] = fn_type
		}
	}

	if init_method := find_init_method(decl); init_method != nil {
		harvest_init_field_types(tc, ct, init_method.decl)
	}
}

@(private = "file")
find_init_method :: proc(decl: ^Stmt_Class_Decl) -> ^Method {
	for member in decl.members {
		if m, ok := member.(^Method); ok && m.decl.fn_type == .Initializer {
			return m
		}
	}
	return nil
}

// harvest_init_field_types scans init_decl's own body for top-level
// `this.x = expr` assignments -- the same *shape* of scan as resolve.
// odin's discover_field_slots (including its if/else-both-branches-
// assign special case), reimplemented here rather than reused: that
// logic is `@(private = "file")` and tuned for a different job (a hard
// compile-time field-slot-index optimization gate), this one is an
// advisory, all-open-on-miss diagnostic source recording an *inferred*
// ^Type per name instead of a slot index -- coupling the two would make
// either riskier to change later. Deliberately diagnostic-free (never
// calls typecheck_expr/diagnose): pass 2's ordinary typecheck_function_
// decl walk over this *exact same* body (ordinary Stmt_Function_Decl/
// Method handling) is what actually diagnoses it for real, once, when
// this class's own methods are checked -- calling the diagnosing
// machinery here too would double every diagnostic on this body, and
// run before tc.current_class/the rest of pass 2's context even exists.
@(private = "file")
harvest_init_field_types :: proc(tc: ^Type_Checker, ct: ^Class_Type, init_decl: ^Function_Decl) {
	for stmt in init_decl.body {
		harvest_field_stmt(tc, ct, init_decl, stmt)
	}
}

@(private = "file")
harvest_field_stmt :: proc(tc: ^Type_Checker, ct: ^Class_Type, init_decl: ^Function_Decl, stmt: Stmt) {
	#partial switch s in stmt {
	case ^Stmt_Expression:
		if name, rhs, ok := top_level_field_set(s); ok {
			ct.fields[name] = infer_field_type(tc, init_decl, rhs)
		}
	case ^Stmt_If:
		if s.else_branch == nil {
			return
		}
		then_assigns := field_assigns_in_branch(s.then_branch)
		defer delete(then_assigns)
		else_assigns := field_assigns_in_branch(s.else_branch)
		defer delete(else_assigns)
		for name, then_rhs in then_assigns {
			else_rhs, in_else := else_assigns[name]
			if !in_else {
				continue
			}
			ct.fields[name] = union_type(infer_field_type(tc, init_decl, then_rhs), infer_field_type(tc, init_decl, else_rhs))
		}
	}
}

@(private = "file")
field_assigns_in_branch :: proc(branch: Stmt) -> map[string]Expr {
	out: map[string]Expr
	if block, is_block := branch.(^Stmt_Block); is_block {
		for stmt in block.stmts {
			if expr_stmt, is_expr_stmt := stmt.(^Stmt_Expression); is_expr_stmt {
				if name, rhs, is_field := top_level_field_set(expr_stmt); is_field {
					out[name] = rhs
				}
			}
		}
	} else if expr_stmt, is_expr_stmt := branch.(^Stmt_Expression); is_expr_stmt {
		if name, rhs, is_field := top_level_field_set(expr_stmt); is_field {
			out[name] = rhs
		}
	}
	return out
}

// top_level_field_set reports the field name and RHS expression a bare
// `this.name = value` expression-statement assigns, if that's what stmt
// actually is (a plain .Set, not .Compound_Set -- a compound assignment
// reads before writing, so it can never be treated as *defining* a
// field -- mirrors resolve.odin's top_level_field_assign_name exactly).
@(private = "file")
top_level_field_set :: proc(stmt: ^Stmt_Expression) -> (name: string, rhs: Expr, ok: bool) {
	prop, is_prop := stmt.expr.(^Expr_Property)
	if !is_prop || prop.kind != .Set {
		return "", nil, false
	}
	if _, is_this := prop.object.(^Expr_This); !is_this {
		return "", nil, false
	}
	return lexeme(prop.name), prop.value, true
}

// infer_field_type is a deliberately narrow, diagnostic-free guess at an
// expression's type, used only for seeding Class_Type.fields during
// step 2 (see harvest_init_field_types's own doc comment for why this
// can't just call typecheck_expr). Only the two shapes that overwhelmingly
// dominate real constructors are handled -- a literal (`this.x = 1`), or
// a bare reference to one of __init__'s own annotated params (`this.x =
// x`, the standard constructor idiom) -- anything else (a call, a binary
// expression, a reference to some other local) synthesizes Dynamic
// rather than attempting to guess. `this.x = nil` is deliberately *not*
// inferred as Type{kind=.Nil}, even though that's what Expr_Literal.Nil
// would ordinarily synthesize elsewhere: nil-initializing a field is the
// standard "optional reference, assigned its real value later" idiom
// (a linked-list/tree node's own `next`/`left`/`right`, found via a real
// full-corpus false positive), and pinning the field's type to "always
// nil" from that alone would flag every legitimate later assignment of
// an actual value. A field genuinely meant to always be nil is
// indistinguishable from this idiom at the syntax level, so this
// deliberately stays permissive (Dynamic) rather than guessing wrong.
@(private = "file")
infer_field_type :: proc(tc: ^Type_Checker, init_decl: ^Function_Decl, rhs: Expr) -> ^Type {
	if lit, is_lit := rhs.(^Expr_Literal); is_lit {
		switch lit.kind {
		case .Int:
			return int_type()
		case .Float:
			return float_type()
		case .String:
			return string_type()
		case .Bool:
			return bool_type()
		case .Nil:
			return dynamic_type()
		}
	}
	if v, is_var := rhs.(^Expr_Variable); is_var && v.resolved.kind == .Local {
		for param in init_decl.params {
			if param.declared_slot == v.resolved.slot {
				return type_from_expr(tc, param.type_annotation) if param.type_annotation != nil else dynamic_type()
			}
		}
	}
	return dynamic_type()
}

// -----------------------------------------------------------------------
// Step 3 support: superclass linking/flattening.

// flatten_class links ct's superclass (if any) and copies every entry of
// the superclass's *already-flattened* fields/methods into ct's own maps
// -- recursing into the superclass first (memoized against re-flattening
// an already-done class, and against a self/mutual cycle, which degrades
// to "no inherited members" the same as an unresolvable superclass name
// does, rather than looping forever or erroring: do_inherit itself only
// catches "superclass must be a class" at *runtime*, and this plan adds
// no new static error class for it in v1). A name ct already has from its
// own step-2 pass (an override) is left as ct's own version, but recorded
// in ct.overrides for typecheck_stmt.odin's typecheck_class_decl to
// check compatibility against once pass 2 reaches this class for real.
@(private = "file")
flatten_class :: proc(
	tc: ^Type_Checker,
	ct: ^Class_Type,
	decl: ^Stmt_Class_Decl,
	class_decls: map[string]^Stmt_Class_Decl,
	flattened: ^map[string]bool,
	in_progress: ^map[string]bool,
) {
	if flattened[ct.name] {
		return
	}
	if in_progress[ct.name] {
		// A self/mutual cycle -- can't fully resolve, so .methods is
		// knowably incomplete for this class too (see methods_uncertain's
		// own doc comment).
		ct.methods_uncertain = true
		return
	}
	in_progress[ct.name] = true
	defer delete_key(in_progress, ct.name)

	if decl.has_superclass {
		super_name := lexeme(decl.superclass)
		super_ct, ok := tc.classes[super_name]
		if !ok {
			// Not a known class in *this* compilation unit -- either a
			// genuine typo/non-class name, or (just as likely in
			// practice, see methods_uncertain's own doc comment) a class
			// imported from another module file. Either way, .methods
			// can't be trusted as complete for this class.
			ct.methods_uncertain = true
		} else {
			if super_decl, has_decl := class_decls[super_name]; has_decl {
				flatten_class(tc, super_ct, super_decl, class_decls, flattened, in_progress)
			}
			ct.superclass = super_ct
			ct.methods_uncertain = super_ct.methods_uncertain
			for name, method_type in super_ct.methods {
				if existing, already := ct.methods[name]; already {
					ct.overrides[name] = method_type
					_ = existing
				} else {
					ct.methods[name] = method_type
				}
			}
			for name, field_type in super_ct.fields {
				if _, already := ct.fields[name]; !already {
					ct.fields[name] = field_type
				}
			}
		}
	}

	flattened[ct.name] = true
}
