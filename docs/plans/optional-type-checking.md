# Optional type annotation and gradual type checking

**Status**: design discussion only, not a commitment or a scoped implementation plan. No syntax is
finalized, no code has been written, and this wasn't reviewed against a toolchain. Captures a
conversation exploring "if odlox grew optional type annotations, how would the AST actually get
type-checked, and what would it buy us" — worth keeping as a reference point if this is picked up
later, not as a checklist to execute.

## Where it fits in the pipeline

`compile.odin`'s `Compile`/`Compile_Repl` run three stages: parse to an AST (`parser.odin`/
`rules.odin`/`expr.odin`/`stmt.odin`), resolve it in place (`resolve.odin`), then emit bytecode from
the resolved tree (`emit.odin`/`emit_expr.odin`/`emit_stmt.odin`). `resolve.odin`'s own header comment
already earmarks the seam for this: "this file never touches `core.Chunk`. It only ever assigns slot
*numbers*... which is what keeps the seam clean for a future type-checker to occupy the same position
in the pipeline (after this, before Emit)."

A type checker would be a fourth stage, inserted right between the two existing calls:

```go
globals, had_error := resolve_program(stmts[:])
if had_error { return nil, false }

// new:
type_errors := typecheck_program(stmts[:], globals)
if len(type_errors) > 0 && strict_mode { return nil, false }

return emit_program(stmts[:], filename, environment, globals, DebugSkipPeephole)
```

It's a second full walk of the same tree the Resolver just walked — not folded into `resolve.odin`
itself. Scope/slot resolution has to be unconditionally correct for the language to run at all; type
checking is optional and advisory. Keeping them separate means a bug in the checker can never corrupt
a program that doesn't use annotations.

## Type erasure is already the status quo

`core.Value` (`core/value.odin:13`) already carries a *runtime* type tag (`Value_Type`: Nil/Bool/Int/
Float/Obj/Vec2-4) that every opcode dispatches on dynamically. `emit.odin`/`emit_expr.odin`/
`emit_stmt.odin` never encode static types into bytecode — there's no `Op_Add_Int` vs `Op_Add_Float`,
just `Op_Add` with a runtime check. So "type erasure" isn't something that would need to be built —
it's the existing design. The checker's output is purely diagnostics; `Emit` never reads it, no new
opcodes, no `Chunk` format change. Annotated and unannotated programs would compile to bit-identical
bytecode.

## Surface syntax and AST additions

None of the annotation surface exists yet. It would need to land at three sites, one new field each:

- **Params** (`functions.odin`, `ast.odin`'s `Param`): `func f(a: int, b: float = 1.0)` →
  `Param.type_annotation: Type_Expr` (nil = untyped).
- **Var decls** (`stmt.odin`, `ast.odin`'s `Stmt_Var_Decl`): `var x: int = 5` → same field.
- **Return type** (`functions.odin`'s `Function_Decl`): `func f() -> int { ... }` →
  `Function_Decl.return_type: Type_Expr`.

`Type_Expr` is a small new grammar, parsed but never touching `Value`: identifiers for primitives/
class names (`int`, `float`, `string`, `bool`, a class name), `Name[Name]` for generics (`List[int]`,
`Dict[string, int]`), and `Name?` for nilable. Lives in the parser layer only — never becomes a
runtime value.

## Gradual typing and the type lattice

Because annotations are optional, this has to be a **gradual type system**, not a sound
Hindley-Milner one: an unannotated binding gets a special `Dynamic` type that's bidirectionally
compatible with everything (assignable to, and from). Only annotated sites get real checking. This is
the standard approach (mypy, TypeScript's implicit `any`, pre-null-safety Dart) and it's the only
shape that makes sense for "optional" — otherwise every untouched `.lox` script in `lox_examples/`
would suddenly fail to compile.

Lattice sketch: `Dynamic` (⊤, compatible with everything) → `Int`/`Float`/`Bool`/`String`/`Nil` (from
`Literal_Kind`, `ast.odin:48`, already 1:1 with `Value_Type`'s primitive cases) → `List[T]`/
`Dict[K,V]` (structural, parameterized) → a nominal type per user class (`Stmt_Class_Decl`) →
`Func(params) -> ret`.

## Reusing the Resolver's slot numbers instead of re-deriving scope

The Resolver already assigns every binding a stable `Var_Ref{kind, slot}` (`ast.odin:126`) — on
`Expr_Variable.resolved`, `Expr_Assign.resolved`, `Stmt_Var_Decl.declared_slot`, `Param.declared_slot`,
etc. The type checker wouldn't need to reconstruct scoping at all — just a `slot -> Type` map:

- One `map[int]Type` for globals, populated once, persists for the whole program (mirrors
  `Global_Table` in `resolve.odin`).
- One fresh `map[int]Type` per function activation for locals — reset on entering each
  `Function_Decl.body`, exactly like the Emitter's own per-function `Compiler.locals` array. Upvalues
  resolve by looking up the type in the *enclosing* function's still-live local-type map.

So the traversal shape is: walk statements in order, and whenever a `Var_Ref.kind == .Local/.Global`
is seen, key into the relevant map by `.slot` — no name lookup, no rebuilding block scoping, no
shadowing logic. All of that work is already done and stored on the node.

## The inference/checking algorithm

Bottom-up synthesis for expressions, with a bidirectional check wherever an expected type is already
known from an annotation:

- `Expr_Literal` → trivial, from `Literal_Kind`.
- `Expr_Binary`/`Expr_Unary` → arithmetic ops require `Int|Float|Dynamic` operands, comparisons
  synthesize `Bool`, `+` on `String` is a separate rule.
- `Expr_Variable`/`Expr_Assign` → slot lookup as above; assignment checks RHS type against the slot's
  declared type (if annotated) or just widens/records it (if not).
- `Expr_Call` → needs the callee's function type. For a call to a name resolving to a
  `Stmt_Function_Decl`/`Expr_Lambda`, build `Func(params)->ret` from its annotations once (memoize on
  the `Function_Decl` node) and check each arg; calling a `Dynamic`-typed callee produces `Dynamic`
  with no check.
- `Expr_Property`/`Invoke`, class fields → see "User class type checking" below.
- `Expr_List`/`Expr_Dict` → unify element types across entries, or fall back to `List[Dynamic]`.
- `Expr_Subscript` → project the element type back out of `List[T]`/`Dict[K,V]`.

At the statement level: `Stmt_Var_Decl` checks/records; `Stmt_Return` checks against the enclosing
function's return-type annotation (tracked via a small enclosing-function-context stack, the same
shape as the Resolver's own function-context stack used for validating `return`/`this` placement —
just carrying a `Type` instead of a scope depth); `Stmt_Function_Decl`, methods, and class var members
follow the same pattern as params/return.

## Diagnostics

Route through the same `error`/`error_at` sink `parser.odin` already uses (`file:line: error: ...`),
so type errors read identically to syntax errors. Since it's optional typing, a real product decision
is whether a type error is fatal or a warning by default — leaning toward warning (annotations behave
as enforced documentation, not a hard gate) with a `--strict-types` flag to promote to fatal, since
that's the only choice that doesn't risk breaking every currently-passing unannotated script the
moment the feature ships.

## User class type checking

### Building each class's static signature

Two-pass, at the whole-program level: **pass 1** walks every `Stmt_Class_Decl` and builds a
`Class_Type` record (`fields: map[string]Type`, `methods: map[string]Func_Type`, `static_methods`,
`superclass: ^Class_Type`) *without* checking any bodies. **Pass 2** checks method/field-initializer
bodies with the full inter-class table already populated.

Two passes are needed for a reason that doesn't apply to plain functions: `resolve_class_decl`
resolves a superclass name via ordinary variable resolution (`resolve_variable_rs`, `resolve.odin`),
not a "must already be declared" special case, so nothing guarantees superclasses are declared before
subclasses in source order. Collecting every class's signature first, independent of order, then
checking bodies, sidesteps that entirely.

**Inheritance is copy-based at runtime, and the static side should mirror it.** `vm/properties.odin`'s
`do_inherit` implements inheritance by *flattening*: when `class Foo < Bar {}` runs, every entry in
`Bar.methods` is copied into `Foo.methods` right there, `super` is kept only for
`is_subclass_of`/`Get_Super`, and method lookup is a flat map lookup (`class.methods[name]`,
`vm/call.odin`) with no chain walk at call time. Pass 1 should do the same: when it reaches `class Foo
< Bar`, copy every entry from `Bar`'s already-built `Class_Type.methods`/`fields` into `Foo`'s, then
overlay `Foo`'s own declared members on top by name. This means every `Expr_Property` lookup in pass 2
is a flat map lookup on the object's static class type — no walking a superclass chain, same win
`do_inherit` gets at runtime.

### Field types are necessarily open, not closed

`Instance_Object.fields` (`core/obj_instance.odin:26`) is a general `map[^String_Object]Value` that
anything can write to at runtime — there's no declared field list in the language, only the
*convention* that `__init__` assigns everything. `discover_field_slots` (`resolve.odin`) already only
captures unconditional top-level `this.x = ...` assignments in `__init__`, on the documented
understanding that a field assigned any other way "simply never enters this table... and keeps
compiling through the ordinary Get_Property/Set_Property path, unchanged and always correct."

The type table has to make the same concession. Harvest field types from `__init__`'s top-level
`this.x = expr` assignments — from an explicit annotation (`this.x: int = 5`, if that syntax gets
added) or inferred from the initializer's expression type — but treat `Class_Type.fields` as **open**:
a `.name` access that misses the table degrades to `Dynamic` rather than erroring, because the runtime
genuinely allows a field nothing in `__init__` mentions. Methods can be treated as **closed** by
contrast — nothing analogous to arbitrary runtime field injection exists for methods, they're fully
enumerable from the class body — so an unknown *method* invoke is a legitimate hard error while an
unknown *field* access is not. Worth keeping that asymmetry deliberately.

### `this` / `super` typing

Both fall out of context the Resolver already tracks. `rs.current_class` (`resolve.odin`) is a stack
of `Class_Compiler` the Resolver pushes/pops around each class body — the checker would mirror it with
its own stack of `Class_Type`.
- `Expr_This` (`ast.odin`) types as the enclosing class's own `Class_Type` — no lookup needed.
- `Expr_Super` (`ast.odin`) resolves `method_name` against the *superclass's* method table
  specifically. Since inheritance is flattening, that's just `current_class.superclass.methods` — one
  indirection, no walk.

### Constructors and instantiation

`Foo(args)` where `Foo` resolves to a class: check `args` against `__init__`'s `Function_Decl` params
(`Function_Type.Initializer`, `stmt.odin`/`functions.odin`) exactly like a normal call, but the
**result type of the call expression is `Class_Type(Foo)`**, not `__init__`'s own return annotation
(which should always be ignored — `__init__` doesn't return a value). The one special case every typed
OOP checker needs for constructor calls.

### Overrides

When `Foo`'s own declared members overlay a name pass 1 already copied in from `Bar`, that's an
override — worth checking signature compatibility (arity match, param/return types compatible or
`Dynamic`) rather than enforcing strict variance rules. A scripting language's users will find
contravariant-parameter/covariant-return Liskov rules more friction than value; "compatible or
unannotated" is the pragmatic bar.

### The real cost: nominal types vs. the language's existing duck typing

Lox as it stands has no interface/protocol concept — two unrelated classes that both happen to define
`draw()` are freely interchangeable at every call site today, purely by structural luck. A nominal
`Class_Type` scheme (the only kind that's tractable given single inheritance and named classes) makes
that stop type-checking:

```
class Circle { area() -> float { ... } }
class Square { area() -> float { ... } }
func total_area(shapes: List[Circle]) -> float { ... }
total_area([Square(2)])   // error: Square is not a Circle
```

Even though `Square` has an identical `area()` and would work fine at runtime, nominal typing rejects
it. That's an inherent cost of adding nominal types to a duck-typed language, not a bug to design
around. The escape valve is the same one used everywhere else: leave the parameter unannotated and it
stays `Dynamic`, duck typing keeps working exactly as today. A `protocol`/structural-interface
construct would recover duck-typing under the checker, but that's new language surface, not just a
checker addition — a separate, larger follow-on if it ever matters.

## What it would actually catch

**Hard errors** (methods are closed/enumerable, safe to reject outright):
- Misspelled/nonexistent method calls (`c.aera()` on a `Circle` with `area()`) — the single highest-
  value catch, since today this only surfaces as a runtime `AttributeError` on whatever path happens
  to execute it.
- Wrong argument count/type to a method or constructor.
- Wrong return type from an annotated method/function body.
- Assigning the wrong type to a typed field, anywhere it's touched, not just in `__init__`.
- Incompatible method override (extra required param, incompatible return type).
- Inheriting from something that isn't a class, when the superclass name's type is already known —
  today `do_inherit` (`vm/properties.odin`) only catches this at runtime, and only if that class
  declaration actually executes.
- Nominal type mismatch across unrelated classes (see above) — by design, not a bug.

**Warnings, not errors** (softer confidence, since the type was inferred rather than declared):
- An unannotated field inferred from `__init__`, later reassigned a different type elsewhere.

**Explicitly not caught** — worth being upfront about:
- A field never mentioned in `__init__`, assigned dynamically elsewhere (`instance.extra = 5` from
  outside the class) — `Instance_Object.fields` is genuinely open at runtime, flagging this would
  break legitimate existing patterns.
- Conditionally-assigned fields, the same shape `discover_field_slots` already excludes.
- Structural/duck-typed interchangeability between unrelated classes when the receiving parameter
  isn't annotated — by design, the gradual-typing escape valve.
- Anything inside a method whose parameters/return aren't annotated.

The practical shape: a handful of narrow, high-confidence catches fire as hard errors even in scripts
that only sparingly annotate; everything softer degrades to a warning or stays silent, so a
partially-annotated real-world `.lox` file wouldn't suddenly break.

## Opcode specialization, once type-checked

odlox's VM already does opcode specialization — at runtime, adaptively, via self-modifying bytecode.
`vm/run.odin`'s `.Add_Nn` case is a monomorphic-inline-cache/quickening pattern: it runs once, checks
the actual runtime types of its operands, and on an Int/Int or Float/Float hit, overwrites its own
opcode byte in the chunk (`fl.code[op_ip] = u8(core.Op_Code.Add_Ii)`) so every later execution jumps
straight to a specialized form with zero type-check branch left in it. The question a static checker
raises isn't "could static types enable specialization" — it's where a compile-time proof would beat
the existing adaptive one, given the adaptive one is already quite good:

- **Real win**: the Sub/Mul/Div family, which — unlike Add — re-validates its operand types on
  *every* execution and can repatch back to generic on a miss (per `run.odin`'s own comment on that
  family). A checker proof removes that per-execution branch permanently instead of once per warm-up.
  Also a genuine correctness improvement, not just speed: the runtime mechanism only trusts whichever
  types show up *first*; a static proof holds for every path the checker actually covers.
- **Marginal win**: steady-state `Add_Ii`/`Add_Ff` already has no type-check left once patched — a
  static opcode choice buys little over what the adaptive mechanism converges to on its own for a
  long-running hot loop. The real win there is skipping one-time warm-up cost, which matters more for
  cold-start-heavy code (REPL lines, short scripts) than hot loops.
- **Hard, probably not worth attempting directly**: bypassing `invoke_from_class`'s (`vm/call.odin`)
  method-dispatch cache entirely needs the receiver's *exact* runtime class, not just a static
  upper-bound type — odlox has real subclassing with no sealed/final concept, so that generally needs
  whole-program closed-world analysis. A more realistic middle ground: use the checker's static class
  type to *seed* the existing inline cache immediately, cutting the first cold miss, rather than
  eliminating the cache mechanism.
- **No real addition needed**: field slots (`Get_Field_Slot`/`Set_Field_Slot`) are already backed by a
  pure compile-time proof (`discover_field_slots`) with no runtime learning involved.

The binding constraint either way: because annotations are optional, this only applies to code the
checker can prove is *fully* monomorphic end-to-end. Partially- or unannotated code — likely the
common case for existing `.lox` scripts — still needs the adaptive machinery as-is, so this would be
additive to the self-specializing bytecode that already exists, not a replacement for it.
