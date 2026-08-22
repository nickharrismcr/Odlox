# Optional type annotations: file-by-file implementation plan

**Status**: implementation plan for review. No code written. This document builds on
`docs/plans/optional-type-checking.md` ("the design doc" below), which is explicitly not a scoped
plan. This document pins down scope, sequencing, and exact file-by-file changes so the feature can
be reviewed and then built in ordered, independently-testable steps. Where the design doc left a
question open, that question is either resolved here (and marked as such) or listed in the "Open
questions" section at the end for explicit sign-off before implementation starts.

Grounded in a direct read of `src/compiler/ast.odin`, `expr.odin`, `stmt.odin`, `functions.odin`,
`parser.odin`, `resolve.odin`, `compile.odin`, `scanner.odin`, `src/main.odin`, and
`src/vm/properties.odin`'s `do_inherit` — not assumed from the design doc's prose alone.

## Scope for v1

The design doc covers the full feature (functions, vars, classes, generics, overrides, opcode
specialization). Building all of it in one pass is a large, hard-to-review unit of work. This plan
splits it into four phases, each independently mergeable and independently testable:

- **Phase 1 — grammar surface**: `Type_Expr` parsing at the three annotation sites (params, var
  decls, return types). No checking yet; annotations parse and are silently ignored by everything
  downstream. Existing `.lox` scripts are unaffected either way.
- **Phase 2 — core checker**: the `Dynamic`-gradual type lattice, primitives, functions, and
  var/assignment checking. No class support yet — `this`/`super`/method/field checking is Phase 3.
  Diagnostics are warnings only (see "Fatal vs. warning" below); no `--strict-types` flag yet.
- **Phase 3 — class support**: `Class_Type` construction (two-pass), field-slot reuse, `this`/
  `super` typing, constructor/override checking, nominal mismatches.
- **Phase 4 — enforcement**: the `--strict-types` CLI flag and promoting type errors to hard
  compile failures under it. Deliberately last: it's the only phase that can break an existing
  script's build, so it ships only once Phases 1–3 have run against `lox_examples/`/`tests/` with
  zero unexpected findings.

**Explicitly out of scope for this plan**: generics (`List[int]`, `Dict[K,V]`) beyond recognizing
the syntax and treating the parameter types as `Dynamic`; the "Opcode specialization, once
type-checked" section of the design doc (a separate follow-on, since it touches `vm/run.odin` and
needs its own benchmarking, not a checker-only change); a `protocol`/structural-interface construct.
Each is called out below at the point it would otherwise get in the way.

## Fatal vs. warning, decided for planning purposes

The design doc leaves "is a type error fatal by default" as "a real product decision" leaning
toward warning. This plan adopts that lean explicitly: **through Phase 3, every type diagnostic is
a warning printed to the same sink as compile errors, but never sets `had_error`/fails the
compile.** Phase 4 adds `--strict-types`, which is the only thing that changes a warning into a
build failure. This is what makes Phases 1–3 safe to land incrementally against the existing
`lox_examples/`/`tests/` corpus without a flag day.

## Phase 1 — grammar surface

### `src/compiler/scanner.odin`

- Add one new two-character-operator token: `Arrow` (`->`), scanned alongside the other two-char
  operators (`scanner.odin:407`'s `Minus`/`Minus_Equal` dispatch becomes a three-way match: `-=` →
  `Minus_Equal`, `->` → `Arrow`, else `Minus`).
- No new token needed for nilable-suffix `?` — `Question` already exists (`scanner.odin:20`, used
  today for the ternary operator) and is reused postfix in `Type_Expr` parsing (Phase 1 parser
  section below); the two uses aren't ambiguous since one only ever appears where a type is
  expected and the other only where an expression is.
- `Colon` (`:`) already exists (used by dict literals and the ternary operator) — reused for `x:
  int` param/var annotations with no scanner change.
- Add `scanner_test.odin` cases for `->` tokenizing correctly, and confirm (via a test, not
  inspection) that `Colon`/`Question` scanning is unaffected — see Test plan.

### `src/compiler/ast.odin`

New small type-expression AST, parsed but never touching `core.Value` (per the design doc's "Type
erasure is already the status quo" section):

```odin
Type_Expr_Kind :: enum {
	Named,       // `int`, `float`, `string`, `bool`, or a class name
	Generic,     // `Name[Name, ...]` -- args recorded, never checked in v1 (see Scope)
	Nilable,     // `Name?`
}

Type_Expr :: struct {
	using base: Node_Base,
	kind:       Type_Expr_Kind,
	name:       Token,        // meaningful for .Named and .Generic (the outer name) and .Nilable (delegates to inner)
	args:       []^Type_Expr, // meaningful only for .Generic
	inner:      ^Type_Expr,   // meaningful only for .Nilable
}
```

Three new fields, one per annotation site named in the design doc:

- `Param.type_annotation: ^Type_Expr` (nil = untyped) — added next to `Param.default` in the
  existing struct (`ast.odin:251-256`).
- `Stmt_Var_Decl.type_annotation: ^Type_Expr` (nil = untyped) — added next to `Stmt_Var_Decl.init`
  (`ast.odin:314-321`).
- `Function_Decl.return_type: ^Type_Expr` (nil = untyped) — added next to `Function_Decl.fn_type`
  (`ast.odin:258-265`).

Deliberately *not* touched in Phase 1: `Stmt_Class_Decl`/`Class_Var_Member`/`Method` (no
`this.x: int` field-annotation syntax yet — the design doc marks that syntax itself as "if this
syntax gets added", not committed; Phase 3 revisits whether it's needed or whether inference from
`__init__` alone is sufficient for v1's catches).

### `src/compiler/parser.odin`

No changes — `Type_Expr` parsing doesn't need new parser-core plumbing (`advance`/`check`/`match`/
`consume` already cover it).

### `src/compiler/functions.odin`

`parse_function_decl` (the single shared params+body parser used by declared functions, lambdas,
and methods — `functions.odin:12-52`) gets two additions:

- After `consume(p, .Identifier, "Expect parameter name.")` (`functions.odin:25`), optionally
  parse `: Type_Expr` before checking for a default value — order matters: `a: int = 5` must parse
  the annotation before the default expression, matching every language with this syntax.
- After the closing `)` and before `{` (`functions.odin:42-48`), optionally parse `-> Type_Expr`
  for `Function_Decl.return_type`.

New file: `src/compiler/type_expr.odin` — a `parse_type_expr :: proc(p: ^Parser) -> ^Type_Expr`
function, called from both sites above. Kept in its own file rather than inlined into
`functions.odin`/`stmt.odin` since it's reused a third place (var decls) and is a self-contained
recursive-descent grammar (not a Pratt rule — no precedence table entry needed, it's called
directly wherever a type is expected, the same way `parse_var_decl` is called directly rather than
going through `rules.odin`):

```
type_expr    → IDENTIFIER ( "[" type_expr ( "," type_expr )* "]" )? "?"?
```

### `src/compiler/stmt.odin`

`parse_var_decl` (shared by `var_declaration`/`const_declaration`/`for_statement`'s `var`-led init
clause — `stmt.odin:163-174`) gets one addition: after `consume(p, .Identifier, "Expect variable
name.")` (`stmt.odin:164`), optionally parse `: Type_Expr` before the `=`/initializer branch.

No change needed to `implicit_assignment_core`, `destructuring_assignment_statement`, or
`for_statement`'s bare/expression init-clause forms — none of those existing forms take an
annotation in any language with this feature (`x = 5` implicit-declares, it doesn't declare-with-
type; `for (x = 0; ...)` is the same). This matches the design doc's three named sites exactly.

### `src/compiler/rules.odin`

No changes — `Type_Expr` parsing never goes through the Pratt table; it's driven directly by
`parse_type_expr` called from the three sites above, the same way `parse_var_decl` is driven
directly rather than through `rules.odin`.

### `src/compiler/ast_print.odin`

Add `Type_Expr` printing (mirrors however existing nodes are printed today) and extend the
`Param`/`Stmt_Var_Decl`/`Function_Decl` print cases to show `type_annotation`/`return_type` when
present. Exercised by `--print-ast` and by `ast_print_test.odin` — needed so a human (or a test)
can see that annotations parsed into the right place before Phase 2 does anything with them.

### Phase 1 test plan

- `scanner_test.odin`: `->` tokenizes as `Arrow`; a lone `-` still tokenizes as `Minus`; `-=` still
  tokenizes as `Minus_Equal`.
- New `type_expr_test.odin`: direct parser-level tests for `parse_type_expr` — `int`, `List[int]`,
  `Dict[string, int]`, `int?`, and the parse-error cases (unclosed `[`, missing identifier).
- `ast_expr_test.odin`/`ast_stmt_test.odin`: extend existing `Param`/`Stmt_Var_Decl`/
  `Function_Decl` construction tests (or add new ones alongside them) asserting
  `type_annotation`/`return_type` is nil when omitted and populated correctly when present, for
  each of the three sites.
- Full-corpus regression: run `bin/run_tests.sh` and lint every `.lox` file (per this repo's
  `CLAUDE.md`) — must be unaffected, since no unannotated script's parse changes.
- New fixtures under `tests/new_tests/lox/` exercising each annotation site in isolation, parsed
  successfully with `--compile-only` and `--print-ast`.

## Phase 2 — core checker (no classes)

### New file: `src/compiler/types.odin`

The type lattice itself, kept separate from the checker's tree-walking logic so `types.odin` can
be unit-tested in isolation (compatibility/lattice rules are pure data, no AST needed):

```odin
Type_Kind :: enum {
	Dynamic, // top: bidirectionally compatible with everything (design doc's "Gradual typing" section)
	Nil,
	Bool,
	Int,
	Float,
	String,
	List,   // element type in `.list_elem`; Dynamic in v1 (generics not checked, see Scope)
	Dict,   // key/value types in `.dict_key`/`.dict_value`; Dynamic in v1
	Func,   // `.func_params`/`.func_return`
	Class,  // `.class_type` -- Phase 3 only; a `^Class_Type` forward-declared here, defined in typecheck_class.odin
}

Type :: struct {
	kind:        Type_Kind,
	nilable:     bool,
	list_elem:   ^Type,
	dict_key:    ^Type,
	dict_value:  ^Type,
	func_params: []^Type,
	func_return: ^Type,
	class_type:  ^Class_Type,
}
```

Plus the compatibility predicate `types_compatible :: proc(expected, actual: ^Type) -> bool` (the
core of gradual typing: `true` whenever either side is `.Dynamic`, structural equality for
primitives, and pointwise compatibility for `List`/`Dict`/`Func`) and a helper to resolve a parsed
`Type_Expr` into a `^Type` (`type_from_expr`, primitives table-driven off `Literal_Kind`'s existing
1:1 mapping with `Value_Type` per the design doc; a class name resolved via the class-type table
Phase 3 introduces, `Dynamic` for anything unrecognized in Phase 2 since no class table exists yet).

### New file: `src/compiler/typecheck.odin`

Entry point and per-scope bookkeeping, mirroring `resolve.odin`'s own structure closely (the
design doc's "Reusing the Resolver's slot numbers" section is the load-bearing idea here):

```odin
Type_Checker :: struct {
	globals:      map[int]^Type,        // one map for the whole program, keyed by Var_Ref.slot
	locals:       ^Local_Type_Scope,     // one fresh map per function activation, chained via .enclosing for upvalue lookups
	fn_return:    ^Type,                 // current enclosing function's declared return type, nil if untyped or at top level
	diagnostics:  [dynamic]Type_Diagnostic,
}

Local_Type_Scope :: struct {
	enclosing: ^Local_Type_Scope,
	slots:     map[int]^Type,
}

typecheck_program :: proc(stmts: []Stmt, globals: Global_Table) -> []Type_Diagnostic
```

Called from `compile.odin` (see Phase 2's `compile.odin` section below) after `resolve_program`
succeeds, exactly at the seam the design doc's "Where it fits in the pipeline" section identifies.
Walks statements in declaration order; whenever an `Expr_Variable`/`Expr_Assign`/`Stmt_Var_Decl`/
`Param` is visited, keys into `globals` or the current `Local_Type_Scope` by `.resolved.slot`/
`.declared_slot` — no name lookup, matching the design doc's point that all scope work is already
done by the Resolver. An upvalue reference (`Var_Ref.kind == .Upvalue`) is looked up by walking
`Local_Type_Scope.enclosing` — this requires `typecheck_function_decl` to *chain* each function's
`Local_Type_Scope` onto its enclosing one when entering a nested `Function_Decl`/`Expr_Lambda`,
mirroring `resolve.odin:556-566`'s `begin_function_resolve` structurally (a fresh scope with
`.enclosing` set), not resetting to an empty root each time.

`Type_Diagnostic :: struct { token: Token, message: string }` — collected rather than printed
immediately, so `compile.odin` (and, in Phase 4, the `--strict-types` gate) decides how to surface
them; `typecheck.odin` itself never calls `fmt.printfln` directly, unlike `resolve_error`. A
`print_type_diagnostics` helper in the same file formats them through the same `[line %d] ...`
shape `parser.odin:129-146`/`resolve.odin:284-293` already use, for visual consistency.

### New file: `src/compiler/typecheck_expr.odin`

Bottom-up synthesis, one case per `Expr` variant (mirrors `resolve_expr`'s switch shape at
`resolve.odin:1114-1197` file-for-file, since it's the same traversal):

- `Expr_Literal` → `Type` from `Literal_Kind` directly (table lookup, `types.odin`).
- `Expr_Str_Call` → always `String`, inner expression checked but its type discarded (matches
  runtime: `str()` accepts anything).
- `Expr_Tuple` → out of scope for Phase 2 checking depth; synthesizes `Dynamic` (tuples don't have
  a named type site to annotate against in the design doc's three sites, so nothing to check them
  against yet — revisit only if a real gap shows up in practice).
- `Expr_Unary` → `-` requires `Int|Float|Dynamic`, synthesizes the operand's type; `!` synthesizes
  `Bool` unconditionally (matches runtime truthiness coercion).
- `Expr_Binary`/`Expr_Logical` → arithmetic family requires `Int|Float|Dynamic` both sides
  (`+` also allows `String`+`String`, per the design doc); comparisons synthesize `Bool`;
  `Expr_Logical`'s `and`/`or` synthesize the *union* of both branches' types, degrading to
  `Dynamic` when they differ (matches runtime: either branch's value can flow out).
- `Expr_Conditional` → same union rule as `Expr_Logical` across `then_branch`/`else_branch`.
- `Expr_Variable` → `Local_Type_Scope`/`globals` lookup by `.resolved.slot`; a slot with no entry
  yet (referenced before its declaring `Stmt_Var_Decl`/`Param` was type-checked — possible for a
  forward-referenced global, matching `resolve.odin`'s own forward-reference tolerance) synthesizes
  `Dynamic` rather than erroring.
- `Expr_Assign` → checks the RHS against the target slot's recorded type if the slot was declared
  with an annotation; records/widens the slot's type otherwise (design doc's "assignment checks RHS
  type... or just widens/records it" line). Compound assignment (`+=` etc.) checks the same way an
  ordinary `Expr_Binary` would, using `compound_op`.
- `Expr_Call` → deferred to `typecheck_call` (below); non-class calls only in Phase 2 (a callee
  resolving to a class is Phase 3 — see "Constructors and instantiation" in the design doc).
- `Expr_This`/`Expr_Super`/`Expr_Property` (`.Get`/`.Set`/`.Compound_Set`/`.Invoke`) → **Phase 3
  only**. In Phase 2, all four synthesize `Dynamic` unconditionally (no class-type table exists
  yet to check against) — this is a deliberate, temporary "always compatible" stand-in, not a
  hole that quietly stays open past Phase 3.
- `Expr_Subscript` → projects `List[T]`/`Dict[K,V]`'s element type back out when the object's type
  is known and not `Dynamic`; `Dynamic` otherwise. Slicing always synthesizes the same collection
  type as the object (a slice of a `List[T]` is a `List[T]`).
- `Expr_List`/`Expr_Dict` → unify element/key/value types pairwise across entries (all-same wins,
  any mismatch or empty falls back to `List[Dynamic]`/`Dict[Dynamic,Dynamic]`), per the design doc.
- `Expr_Lambda` → delegates to the same function-checking logic as `Stmt_Function_Decl` (see
  `typecheck_stmt.odin` below) via `typecheck_function_decl`, synthesizing a `Func` type built from
  its own params/return annotations.

`typecheck_call :: proc(tc: ^Type_Checker, call: ^Expr_Call) -> ^Type` — resolves the callee's
static `Func` type when possible (a direct `Expr_Variable` naming a `Stmt_Function_Decl`/
`Expr_Lambda`, built once and memoized on the `Function_Decl` node itself via a new
`Function_Decl.cached_func_type: ^Type` field in `ast.odin`, per the design doc's "memoize on the
Function_Decl node" line — avoids rebuilding the same `Func` type on every call site), checks each
arg against the corresponding param type, and synthesizes `func_return`. A callee whose type isn't
staticaly known (e.g. itself `Dynamic`, or an indirect call through a variable never annotated)
synthesizes `Dynamic` with no per-arg checking, per the design doc.

### New file: `src/compiler/typecheck_stmt.odin`

One case per `Stmt` variant, mirroring `resolve_stmt`'s switch shape (`resolve.odin:607-676`):

- `Stmt_Var_Decl` → checks `init`'s synthesized type against `type_annotation` if present (records
  a diagnostic on mismatch, per Phase 2's "warning only" rule); records the slot's type in
  `globals`/the current `Local_Type_Scope` either way (the annotation's type if present, else the
  initializer's synthesized type, else `Dynamic` for `var x` with no initializer at all — note:
  checked against actual grammar, `stmt.odin:170` allows `var x` with no `=` for a plain `var`,
  unlike `const`).
- `Stmt_Implicit_Assign`/`Stmt_Destructure` → treated as untyped-widening sites only in Phase 2 (no
  annotation surface exists for either — matches the design doc's three named sites, neither of
  which is a bare `x = expr` or a destructuring target); records whatever type the RHS synthesizes.
- `Stmt_Block`/`Stmt_If`/`Stmt_While`/`Stmt_For`/`Stmt_Foreach`/`Stmt_Break`/`Stmt_Continue` →
  straightforward recursive walk, no new checking logic beyond visiting child expressions/
  statements (conditions must synthesize something `Bool`-compatible in principle, but Lox already
  truthiness-coerces everything at runtime — **decision for this plan**: do not flag a non-`Bool`
  condition even when statically known, since that would contradict the language's own existing
  truthy/falsy semantics rather than catch a real bug; only `Expr_Unary`'s `!` gets a hard `Bool`
  result type, per above, everything else stays permissive here).
- `Stmt_Return` → checks `value`'s synthesized type (or `Nil` for a bare `return`) against
  `tc.fn_return` if set. `tc.fn_return` is pushed/popped around each `Function_Decl` body via
  `typecheck_function_decl`, mirroring `Resolve_Scope.fn_type`'s stack-via-enclosing-scope shape
  rather than a separate explicit stack (the design doc's "small enclosing-function-context stack"
  suggestion — implemented here as just a field on the (already-chained) `Local_Type_Scope`/a
  parallel field on `Type_Checker`, saved/restored around the call, since only one is ever live at
  a time in a strictly-nested tree walk).
- `Stmt_Function_Decl` → delegates to `typecheck_function_decl(tc, v.decl)`.
- `Stmt_Class_Decl`, `Expr_This`, `Expr_Super`, `Expr_Property` bodies → **Phase 3 only**; Phase 2's
  `typecheck_stmt`/`typecheck_expr` walk *into* a class body's method statements (so nested
  functions/expressions inside methods still get ordinary Phase 2 checking) but perform no
  class-specific checking — see `typecheck_class.odin` below for what Phase 3 adds on top.
- `Stmt_Try`/`Except_Clause`/`Stmt_Raise` → recursive walk only; no new typed surface (Lox
  exceptions aren't typed by this plan).
- `Stmt_Import`/`Stmt_From_Import` → recorded as `Dynamic` for every imported slot (no cross-module
  type information exists — checking an imported module's own exported types is out of scope for
  this plan entirely, not just deferred to a later phase, since it would need a second checked
  compilation unit's output to consume, a materially bigger project).

`typecheck_function_decl :: proc(tc: ^Type_Checker, decl: ^Function_Decl) -> ^Type` — pushes a
fresh `Local_Type_Scope` chained onto the current one, records each `Param`'s type (from
`type_annotation` if present, else `Dynamic`) by `Param.declared_slot`, sets `tc.fn_return` from
`decl.return_type` (nil = untyped, no return-type checking for this function), walks `decl.body`,
pops back, and returns/caches the synthesized `Func` type. Used by both `Stmt_Function_Decl` and
`Expr_Lambda`, matching how `resolve_function_decl` (`resolve.odin:580-596`) is already shared by
both call sites in the Resolver.

### `src/compiler/compile.odin`

`Compile`/`Compile_Repl` each get the one new call the design doc's "Where it fits in the pipeline"
section shows, inserted between the existing `resolve_program` and `emit_program` calls
(`compile.odin:38-43` and `compile.odin:92-97`) — but the two are no longer identical, per open
question 3's resolution: `Compile_Repl` suppresses printing by default.

```odin
// Compile:
diagnostics := typecheck_program(stmts[:], globals)
print_type_diagnostics(diagnostics) // Phase 2: always warnings, never affects `ok`
// Phase 4 adds: if StrictTypes && len(diagnostics) > 0 { return nil, false }

// Compile_Repl: same typecheck_program call, but the print is gated:
diagnostics := typecheck_program(stmts[:], globals)
if StrictTypes {
	print_type_diagnostics(diagnostics)
}
// Phase 4 adds the same `if StrictTypes && len(diagnostics) > 0 { return nil, false }` gate here too
```

No signature change to `Compile`/`Compile_Repl` in Phase 2 (diagnostics print as a side effect, the
same way `resolve_error`/`error_at` already print as a side effect rather than being returned to
the caller) — Phase 4 is what actually changes control flow based on the result. Phase 2 lands the
`typecheck_program` call in both, but `Compile_Repl`'s print stays gated behind `StrictTypes` from
the start (that gate is cheap to add in Phase 2 even before `StrictTypes` has any other effect, so
Phase 2 and Phase 4 don't need to touch this call site twice).

### `src/compiler/emit.odin`/`emit_expr.odin`/`emit_stmt.odin`

No changes. Confirms the design doc's "type erasure is already the status quo" claim directly:
`Emit` never reads `Type_Checker`'s output, `Function_Decl.cached_func_type`, or any
`type_annotation`/`return_type` field — annotated and unannotated programs compile to bit-identical
bytecode through Phase 3. (Phase 4's `--strict-types` changes whether `Compile` returns `ok`, not
what `Emit` does.)

### Phase 2 test plan

New `typecheck_test.odin`, structured like `resolve_test.odin` (`parse_and_resolve` helper pattern,
`resolve_test.odin:12-28`) but adding the `typecheck_program` call — a `parse_resolve_typecheck`
helper returning `(stmts, globals, diagnostics)`. Cases per the design doc's own "what it would
actually catch" list, restricted to the non-class subset:

- Wrong argument type to an annotated function → one diagnostic, right token/line.
- Wrong return type from an annotated function body → one diagnostic.
- Assigning an incompatible type to an annotated `var` → one diagnostic; assigning to an
  unannotated `var` never diagnoses regardless of type (gradual typing's escape valve).
- A call through an unannotated (`Dynamic`) parameter never diagnoses, even when the actual runtime
  value would mismatch — this is the gradual-typing contract, worth a test precisely because it's
  the easiest thing to accidentally over-tighten later.
- Nested/lambda functions type-check independently; an inner function's param type doesn't leak
  into the outer scope's variable of the same slot number in a different function (upvalue-chain
  test, exercising `Local_Type_Scope.enclosing`).
- Zero diagnostics on a representative unannotated sample (a `.lox` fixture with no annotations at
  all) — the gradual-typing "must not break every untouched script" invariant, made concrete as a
  test rather than left as an assertion in prose.
- `List`/`Dict` literal unification: uniform-element list synthesizes `List[T]`; mixed-element list
  falls back to `List[Dynamic]` with no diagnostic (unification failure degrades, it doesn't error).

Full-corpus regression, same as Phase 1: `bin/run_tests.sh`, plus a new one-off script (not a
permanent test) run against every file under `lox_examples/`/`tests/new_tests/lox/` printing any
Phase-2 diagnostic — expected output is *zero* diagnostics fired on any existing fixture, since none
of them use annotations yet. Any non-zero result here means a Phase 2 bug (a `Dynamic` fallback
missing somewhere), not a real finding, and blocks moving on to Phase 3.

## Phase 3 — class support

### New file: `src/compiler/typecheck_class.odin`

`Class_Type :: struct { name: string, fields: map[string]^Type, methods: map[string]^Type,
static_methods: map[string]^Type, superclass: ^Class_Type }` (referenced from `types.odin`'s
`Type.class_type`, defined here since building it needs `Stmt_Class_Decl`/`Method`, which
`types.odin` deliberately doesn't depend on).

Two-pass, at the whole-program level, exactly as the design doc specifies:

- `typecheck_collect_class_signatures(tc, stmts) :: proc` — pass 1. Walks every top-level (and,
  since Lox allows local class declarations per `resolve.odin:1035` handling both branches, every
  nested) `Stmt_Class_Decl`, building each `Class_Type` *without* checking method bodies. On `class
  Foo < Bar`, copies every entry of `Bar`'s already-built `Class_Type.fields`/`.methods` into
  `Foo`'s own maps first (flattening, mirroring `do_inherit`'s copy loop at
  `vm/properties.odin:351-353` exactly), then overlays `Foo`'s own declared members by name.
  Superclass-before-subclass ordering independence is handled by doing this as a **name-indexed
  fixpoint pass over `Stmt_Class_Decl`s in program order with a pending-retry list**, not by
  requiring topological order in source — reads a class's `superclass` name, and if that name's
  `Class_Type` isn't built yet, defers this class and retries after a full sweep (bounded by class
  count, so no risk of infinite loop; a genuine unresolvable superclass — pointing at a non-class,
  or a self/mutual cycle — degrades that class's `Class_Type` to have no inherited members rather
  than erroring, since `do_inherit` itself only catches "superclass must be a class" at *runtime*
  per the design doc, and this plan doesn't add a new static error class for it in v1).
- `typecheck_class_bodies(tc, stmts) :: proc` — pass 2. Walks every `Stmt_Class_Decl` again, this
  time checking each method body (via `typecheck_function_decl`, reused unchanged) with
  `tc.current_class` pushed to that class's already-complete `Class_Type`, and harvesting field
  types from `__init__`'s top-level `this.x = expr` assignments — reusing the *existing*
  `discover_field_slots`/`top_level_field_assign_name` logic in `resolve.odin` (`resolve.odin:92-
  199`) is deliberately **not** attempted: that logic is `@(private = "file")` and tuned for a
  different purpose (compile-time field-slot indices, not types), so `typecheck_class.odin` gets
  its own small walk over `__init__`'s body doing the same *shape* of scan (top-level `this.x = `,
  plus the same if/else-both-branches-assign special case) but recording a `^Type` per name instead
  of a slot index. Consciously accepting this small duplication over exporting `resolve.odin`'s
  private helpers, since the two scans have different jobs (one is a hard compile-time optimization
  gate, the other is an advisory, all-open-on-miss diagnostic source) and coupling them would make a
  future change to either one riskier.

`Class_Type.fields` stays **open** per the design doc: `typecheck_expr.odin`'s `Expr_Property`
`.Get`/`.Set`/`.Compound_Set` handling (Phase 2 left these as unconditional `Dynamic`, replaced now)
looks up the field name in the receiver's `Class_Type.fields`; a miss synthesizes `Dynamic` with
*no* diagnostic, since `Instance_Object.fields` genuinely accepts arbitrary runtime writes.
`Class_Type.methods` stays **closed**: `.Invoke` (and a plain `.Get` that turns out to name a
method, which Lox permits — reading a method as a value) checks against `.methods`, and a miss *is*
a diagnostic — the design doc's single highest-value catch. `this`/`super`
(`Expr_This`/`Expr_Super`) synthesize `tc.current_class`'s own `Class_Type` (`this`) or
`tc.current_class.superclass`'s (`super`, method lookup against `superclass.methods` specifically,
per the design doc — one indirection since inheritance is already flattened, no walk needed).

`typecheck_call`'s Phase 2 body (in `typecheck_expr.odin`) gets one addition here: a callee that's
an `Expr_Variable` resolving to a class name (checked by whether that global/local slot's recorded
type is `.Class`, not by re-deriving name resolution) is a constructor call — checked against
`__init__`'s params exactly like an ordinary call, but the *call expression's own* synthesized type
is `Class_Type(Foo)`, `__init__`'s own `return_type` annotation (if someone writes one, which
nothing stops syntactically) is ignored outright, per the design doc's "one special case every
typed OOP checker needs."

Overrides: in pass 1, when `Foo`'s own declared member overlays a name already copied in from
`Bar`, pass 1 additionally records that this name is an override (a `map[string]bool` on
`Class_Type`, or a same-shape side table) — pass 2, once both signatures are known, checks arity
match and pointwise param/return compatibility via the same `types_compatible` gradual predicate
`types.odin` already provides (an unannotated override param is automatically compatible, matching
the design doc's "compatible or unannotated" bar — no extra logic needed beyond calling the same
function `Expr_Call` argument-checking already uses).

### `src/compiler/typecheck.odin` / `typecheck_stmt.odin`

- `Type_Checker.current_class: ^Class_Type` field added, pushed/popped around
  `Stmt_Class_Decl` member resolution the same way `Resolver.current_class` already brackets
  `resolve_class_decl` (`resolve.odin:1046-1080`) — `typecheck_stmt.odin`'s `Stmt_Class_Decl` case,
  a no-op stub through Phase 2, now calls into `typecheck_class.odin`'s pass-2 walk for this node.
- `typecheck_program`'s top level changes from "one walk" to "collect every class's signature
  first (pass 1, program-wide), then walk statements in order (pass 2)" — collection has to see the
  *whole* program before any method body checks, per the design doc's ordering-independence
  argument, so this is a structural change to `typecheck_program` itself, not just an addition to
  the `Stmt_Class_Decl` case.

### Phase 3 test plan

New cases appended to `typecheck_test.odin`, per the design doc's "What it would actually catch"
list, class subset:

- Misspelled method call (`c.aera()` on a class declaring `area()`) → one diagnostic, since methods
  are closed.
- Wrong arg count/type to a method or constructor call → one diagnostic each.
- Wrong return type from an annotated method body → one diagnostic.
- Field assigned an incompatible type anywhere it's touched (not just in `__init__`) once that
  field's type is known from `__init__` → one diagnostic; a field *never* mentioned in `__init__`,
  assigned dynamically from outside the class → zero diagnostics (open-field escape valve,
  explicitly tested to prevent regression toward over-tightening).
- Incompatible override (extra required param, incompatible return) → one diagnostic; a compatible
  override, and an override where the subclass leaves its own param/return unannotated → zero.
- `class Foo < Bar` where `Bar` is declared *after* `Foo` in source order → both classes' signatures
  still build correctly (exercises the fixpoint pass's ordering independence directly — this is the
  scenario `resolve_class_decl`'s own doc comment (`resolve.odin:1050-1054`) calls out as legal
  today via ordinary variable resolution).
- Nominal mismatch across two unrelated classes with identical method shapes, passed into an
  annotated parameter → one diagnostic (the design doc's "cost of nominal types" example, verified
  as intentional-by-design rather than accidentally over-strict).
- `this`/`super` typing inside a method resolves to the right `Class_Type`, including a method
  inherited (flattened) into a subclass and invoked via `super.method()`.

Full-corpus regression repeated, same zero-unexpected-diagnostics bar as Phase 2, now against every
class-using fixture in `lox_examples/`/`tests/`.

## Phase 4 — enforcement

### `src/compiler/compile.odin`

Add `StrictTypes: bool` as a package-level var (declared wherever `DebugSkipPeephole` already lives
— confirmed as a plain `compiler.DebugSkipPeephole = true` package var set from `main.odin`, so this
follows the identical pattern). `Compile`/`Compile_Repl`'s new call site becomes:

```odin
diagnostics := typecheck_program(stmts[:], globals)
print_type_diagnostics(diagnostics)
if StrictTypes && len(diagnostics) > 0 {
	return nil, false
}
```

### `src/main.odin`

One new flag case alongside `--no-peephole` (`main.odin:71-72`):

```odin
case "--strict-types":
	compiler.StrictTypes = true
```

Plus the corresponding `usage()` line (near `main.odin:423`'s `--compile-only` entry).

### Phase 4 test plan

- `compile_test.odin`-style test: the same "wrong argument type" fixture from Phase 2 compiles
  successfully (with a printed warning) under default settings, and fails to compile (`ok == false`)
  under `StrictTypes = true`.
- CLI-level check (via whatever harness `bin/run_tests.sh`'s pytest suite already uses for
  `--compile-only`-style flag tests) that `--strict-types` on a real annotated-and-broken fixture
  exits non-zero, and that it's a no-op (exit 0) on every existing unannotated fixture in
  `lox_examples/`/`tests/` — the flag-day safety property this whole phase exists to prove.

## Sequencing and dependencies

Strict linear order — each phase's tests must pass against the full corpus before the next phase
starts, since each phase's "zero unexpected diagnostics on existing scripts" check is only
meaningful once the previous phase is settled:

1. Phase 1 (grammar) — no behavior change, pure additive parsing. Lowest risk, good first PR.
2. Phase 2 (core checker, no classes) — first phase that can produce a diagnostic. Warnings only,
   so still no behavior change for any script that compiles today.
3. Phase 3 (classes) — largest single phase; depends on Phase 2's `Type`/`Local_Type_Scope`
   machinery being in place and stable.
4. Phase 4 (`--strict-types`) — smallest phase, but the only one with real teeth; deliberately
   gated behind Phases 1–3 passing the full-corpus zero-diagnostics bar, not just their own unit
   tests, since a false-positive diagnostic only *matters* once something can act on it by failing
   the build.

Each phase is a plausible standalone PR/review unit; Phases 1 and 2 could also be reviewed together
if that's a better-sized chunk in practice, but Phase 3 should stay separate given its size, and
Phase 4 should never be combined with anything else given its blast radius (it's the only phase
that changes `Compile`'s return value based on new logic).

## Open questions — resolved

1. **`this.x: int` field-annotation syntax: decided against for v1.** Phase 3 relies solely on
   inference from `__init__`'s initializer expressions — no fourth annotation site. Simpler, ships
   Phase 3 sooner, and stays fully compatible with adding explicit syntax later (annotations are
   purely additive, per the design doc's type-erasure guarantee, so this is never a breaking
   decision to revisit). Revisit only if practice shows inference alone leaves a real, common gap.
2. **Local (non-top-level) class declarations in Phase 3's two-pass signature collection: confirmed
   correct as planned.** A `Class_Type` built from a `Stmt_Class_Decl` node's own members (methods
   table, `__init__` field harvest) is a purely static property of that AST node — it doesn't depend
   on whether, or how many times, the enclosing function executes; every runtime instantiation of a
   locally-declared class produced by the same node has an identical structure. So collecting every
   class signature program-wide up front, including ones nested inside function bodies, is correct
   with no special-casing needed beyond what the fixpoint pass already does.
3. **Diagnostic sink for the REPL: decided — suppress by default, surface under `--strict-types`.**
   `Compile` prints Phase 2/3 warnings normally (unaffected). `Compile_Repl` suppresses them unless
   `StrictTypes` is set, so quick interactive snippets stay quiet by default while scripts behave as
   before; `--strict-types` behaves identically in both paths once it's live in Phase 4. This is a
   small asymmetry between `Compile`/`Compile_Repl` to implement in Phase 2's `print_type_diagnostics`
   call site — gate it on `(!repl_mode || StrictTypes)`, threading a `repl_mode: bool` (or reusing
   `Compile_Repl`'s existing `"__repl__"` filename sentinel already used elsewhere in `compile.odin`,
   whichever reads cleaner at implementation time) through to the print call.
4. **`--print-ast` output format for `Type_Expr`: mirror surface syntax.** `: int`, `-> int`,
   `List[int]`, `int?` — the least surprising choice for anyone reading `--print-ast` output, and
   requires no new formatting convention beyond what `ast_print.odin` already does for other nodes.
