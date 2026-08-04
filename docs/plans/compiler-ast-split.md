# Splitting the compiler into Parse -> AST -> Resolve -> Emit

Design record for restructuring `src/compiler/` from a clox-style single-pass Pratt parser (parses
and emits bytecode in the same pass, no AST) into three explicit phases: Parse produces an AST,
Resolve annotates it with scope/local/upvalue/global information and runs validity checks, Emit
walks the resolved AST and generates bytecode into the same `core.Chunk`/`Op_Code` target odlox
uses today. Grounded in a direct read of every file in `src/compiler/` and `src/core/chunk.odin`,
not assumed.

**Status**: design only. Nothing below is implemented.

## Why this, why now

odlox's compiler currently fuses three conceptually separate jobs into one pass: recognizing
grammar, resolving names/scopes, and generating bytecode. `rules.odin`'s Pratt table drives
`expr.odin`/`stmt.odin`, and each parse function calls `compiler_state.odin`'s `emit_*` helpers
directly, mid-parse, writing straight into a `core.Chunk`. That works today because Lox is
dynamically typed — nothing about codegen for a given construct depends on information outside
what's already been parsed left to right.

The motivation for undoing that fusion is a later project: optional static typing for odlox, with
types erased at the VM (compile-time-only checking/inference, no runtime type tags or enforcement
added to `core.Value`/the VM). A type-checker needs resolved names — to know whether an identifier
is a local, an upvalue, or a global, and what's captured by a closure — before it can check
anything, but it must run *before* bytecode exists, since nothing type-related belongs in
`core.Chunk`. A single fused pass has no seam for that checker to occupy: by the time a name is
resolved today, bytecode for it has typically already been emitted in the same function call. This
plan does not add any type syntax or checking. It produces the prerequisite: a persistent,
revisitable AST with an explicit Resolve step sitting strictly before Emit, so a future
type-checker can slot in as an ordinary whole-tree walk between the two, touching neither the
Parser nor the Emitter.

### Non-goals

- No type syntax, type annotations, or type-checking pass. This plan only creates the seam.
- No changes to `core/chunk.odin` — `Op_Code`, `Chunk`, `Property_Cache`, and their helpers
  (`chunk_write_op`, `chunk_write_byte`, `chunk_add_constant`, `chunk_add_property_cache`,
  `chunk_slot_for_name`) are the unchanged target the new Emitter writes into, exactly as
  `compiler_state.odin`'s `emit_*` do today.
- No VM changes.
- No behavior change visible to `compile_test.odin`: opcode sequences and counts must match
  exactly, including existing quirks (the `finally` block compiling twice at the normal-completion
  path, the peephole optimizer's fusion patterns, REPL global-slot continuity across lines).

## Current architecture

- **`parser.odin`** — `Parser` (scanner, current/previous token, `current_compiler`,
  `current_class`, REPL global-tracking fields, recursion-depth guards). Precedence-climbing core:
  `Precedence` enum, `Parse_Fn :: #type proc(p: ^Parser, can_assign: bool)` (prefix and infix share
  one signature — infix functions take no explicit left-operand parameter; they rely on the left
  operand's bytecode already being emitted), `Parse_Rule{prefix, infix, precedence}`,
  `parse_precedence`/`expression`. `Parser_Snapshot`/`snapshot_pos`/`restore_pos` rewind into the
  fully-materialized token stream (the scanner tokenizes everything up front); their only callers
  are `stmt.odin`'s `try_except_statement` and `compile_pending_trampolines`, both discussed below.
- **`rules.odin`** — `get_rule(Token_Type) -> Parse_Rule`, a `#partial switch` table. Statement-
  leading keywords (`if`, `while`, `class`, ...) never reach this table; `stmt.odin`'s
  `declaration`/`statement` dispatch on `p.current.type` directly.
- **`expr.odin`** (482 lines) — every prefix/infix Pratt function, each calling `emit_*` directly:
  literals, `grouping` (also tuples), `unary`, `binary`, `and_`/`or_`, `conditional`,
  `variable`/`named_variable` (plain `=` and compound `+=` etc., via `resolve_variable`), `this_`/
  `super_`, `call`/`argument_list`, `dot` (property get/set/compound-set/invoke, allocating a
  monomorphic inline cache via `chunk_add_property_cache`), `subscript` (index/slice, get/set),
  `list_literal`/`dict_literal`, `lambda`.
- **`stmt.odin`** (1261 lines, the largest file) — `block`, `declaration`/`statement` dispatch,
  `var`/`const` declarations (shared `finish_declare`), `implicit_assignment_statement` (bare
  `x = expr` where `x` isn't yet a known local — resolves local -> global-declared -> upvalue
  priority, or declares new), `destructuring_assignment_statement`, `function_declaration`,
  `if`/`while`/`for`/`foreach` (jump/patch backpatching via `emit_jump`/`patch_jump`/`emit_loop`),
  `class_declaration`, `import`/`from-import`.
- **The try/finally trampoline** — the mechanism this split removes outright, and the only reason
  it exists is single-pass parsing. `break`/`continue`/`return` inside a `try` body must unwind
  registered exception handlers (`Op_End_Try`) and replay the `finally` block on the way out, but
  `finally` is parsed *last*, so at the point a `return`/`break`/`continue` compiles, whether a
  `finally` exists is unknown. `cross_tries` emits `Op_End_Try` for every crossed try unconditionally
  (not filtered by `has_finally`, since that isn't known yet) and queues a
  `Trampoline_Site{jump_offset, remaining, local_count_at_crossing, retval_slot, kind, loop}` onto
  the innermost crossed try's `Try_Finally.pending`. Once `try_except_statement` finishes parsing
  `finally` (if any), `compile_pending_trampolines` resolves each pending site: patches its jump,
  and if `has_finally`, replays the finally body via `restore_pos(finally_snapshot)` plus a second
  `block()` call — padding `Compiler.locals[]` up to `local_count_at_crossing` first, purely so the
  replay's own locals don't collide with whatever's live at that particular crossing point (e.g. a
  pending return's anchored `__retval`). This is why `test_try_except_finally_shape` asserts
  `Print` count 3, not 1 — the finally body compiles once after `Op_Finally` (for the
  always-matching in-VM handler, followed by `Op_Raise` to re-propagate) and once more at the
  shared normal-completion landing point. `return_statement` anchors its value in a synthetic
  `__retval` local before any enclosing, not-yet-parsed `finally` can steal that slot number.
- **`functions.odin`** — `compile_function`/`compile_function_body` (params including `*rest`
  variadic and `name=default` via `Op_Jump_If_Defined` prologue guards), `emit_closure` (adds the
  function as a constant, emits `Op_Closure` plus per-upvalue `is_local`/`index` bytes).
- **`compiler_state.odin`** — `Local`, `Upvalue`, `Loop`, `Try_Finally`/`Trampoline_Site`,
  `Class_Compiler`, `Compiler` (chained via `enclosing`, one per function currently being
  compiled). Locals: `add_local`/`declare_variable`/`mark_initialised`/`resolve_local`
  (innermost-first, errors on self-reference in a variable's own initializer). Upvalues:
  `resolve_upvalue` — the recursive clox climb up `Compiler.enclosing`. Globals: `global_slot`
  (first-*mention* slot assignment — order matters and must be preserved), `resolve_variable`
  (a three-tier local -> upvalue -> global dispatcher that returns `(arg, get_op, set_op)`,
  conflating "where is this" with "which opcode to use"). Bytecode emission primitives
  (`emit_byte`/`emit_op`/`emit_jump`/`patch_jump`/`emit_loop`/...), plus a compile-time peephole
  optimizer (`peephole_optimise`) that pattern-matches fixed instruction shapes on the *finished*
  `Chunk` bytes — independent of how the chunk was generated, unaffected by this refactor.
- **`compile.odin`** — `Compile(source, filename, environment)` and
  `Compile_Repl(source, repl_state)`, called from `main.odin:235` and `vm/interpret.odin:24-27`.
  `Compile_Repl` seeds `Parser.globals`/`globals_declared`/`global_count` from `Repl_State` before
  compiling and commits growth back on success, so global slots stay stable across REPL lines
  (`test_repl_second_line_reuses_first_lines_global_slot`).
- **`compile_test.odin`** (794 lines) — the regression gate this refactor relies on. It asserts
  opcode *sequence/shape*, not exact bytes and not VM behavior (there's no VM at this layer): a
  hand-rolled `decode(chunk)` walker feeds `op_sequence`/`contains_op`/`count_op`/positional
  slicing/`inner_function_chunk` (for nested function constants), plus a few exact-operand-value
  checks (REPL slot continuity). It depends only on the public `Compile`/`Compile_Repl` API and the
  resulting `Chunk`, so it is reusable unmodified as the acceptance gate here.

## Design

### AST representation

New `ast.odin`: tagged unions, one struct per distinct written form the current per-construct
Pratt/statement functions already recognize, so parse-to-AST stays a close transcription of the
current code rather than a new grammar design. Every node embeds a `Node_Base{token: Token}` for
error reporting (today's `error_at_current`/`error` calls happen mid-parse with direct token
access; the AST needs to carry that forward).

Constructs that already share handling collapse into one node type: `var`/`const` declarations
share `finish_declare` today, so `Stmt_Var_Decl{name, init, is_const}` covers both. `dot`'s four
forms (get/set/compound-set/invoke) become one `Expr_Property{object, name, kind, compound_op,
value, args}`. `subscript`'s four forms (index/slice, get/set) become one `Expr_Subscript`.
`(expr)` grouping isn't a node at all — the parser returns the inner expression directly and only
builds `Expr_Tuple` when a comma follows, matching `grouping`'s own `count > 1` check. `for`'s bare
(non-`var`) init clause reuses the exact same node type `implicit_assignment_statement` produces at
ordinary statement level, since both need identical "first mention creates a binding" resolution —
matching how `stmt.odin` already shares that helper.

Resolution results live as fields on the node structs, not a side-table keyed by node identity
(the approach jlox's TypeScript port `jslox` uses, since a TS interface has no natural place to
attach a mutable field — Odin's structs do). `Expr_Variable`/`Expr_Assign`/`Expr_This`/`Expr_Super`
get a `resolved: Var_Ref` field; declaration sites get a `declared_slot: int`. `Var_Ref{kind: enum
{Local, Upvalue, Global}, slot: int, is_const: bool}` holds only *where a variable lives*, not an
`Op_Code` — a cleanup this split enables, since today's `resolve_variable` bakes the opcode choice
into what's conceptually a resolution result. The Emitter maps `kind` to `Get_Local`/`Get_Global`/
etc. itself.

### Parser retargeting

`Parse_Fn` splits into two shapes, since infix functions must now receive the left operand
explicitly instead of relying on it already being emitted:

```
Prefix_Fn :: #type proc(p: ^Parser, can_assign: bool) -> ^Expr
Infix_Fn  :: #type proc(p: ^Parser, left: ^Expr, can_assign: bool) -> ^Expr
```

`parse_precedence` threads `left` through its loop instead of depending on emission side effects.
`rules.odin`'s table keeps its exact shape — only the referenced procs change from "emit" to
"build and return a node." Every proc in `expr.odin`/`stmt.odin` keeps its current name but returns
`^Expr`/`^Stmt`/`[]^Stmt` with zero scope or emission side effects. Everything currently touching
`p.current_compiler`/`p.current_class`/`Compiler.loop`/`Compiler.tries` — `declare_variable`,
`resolve_variable`, `begin_scope`/`end_scope`, the loop and try stacks, and the `this`/`super`-
outside-class checks in `this_`/`super_` — moves out of the Parser entirely, into the Resolver. The
`Parser` struct shrinks to pure token-stream driving and syntax-error state.
`Parser_Snapshot`/`snapshot_pos`/`restore_pos` are deleted: their only use was reparsing `finally`
by token position, which the try/finally redesign below no longer needs.

### Resolver

New `resolve.odin`: reincarnates `compiler_state.odin`'s scope/local/upvalue/global logic as an AST
walk instead of parse-time interleaving. `Local`/`Upvalue`/`Loop` carry over unchanged in shape;
`Compiler` becomes a narrower `Resolve_Scope` (drops `function`/`environment`, which are Emit-time
concerns). `add_local`/`declare_variable`/`mark_initialised`/`resolve_local` and
`add_upvalue`/`resolve_upvalue` migrate with unchanged logic, now reading a `Token` off an AST node
instead of `p.previous`. Upvalue chains fall out of AST function nesting directly — the Resolver's
own recursion into nested `Function_Decl` bodies already mirrors lexical nesting, so no separate
live-compiler-chain bookkeeping is needed the way `Compiler.enclosing` provides it today.

Global first-mention slot order is preserved because an AST walk visits each node's children in the
same left-to-right order the token stream was originally consumed in — none of the node types
reorder their own children relative to source order, so `global_slot`'s first-mention assignment
produces identical slot numbers to today's parse-time visitation. This needs verifying per
construct during implementation, particularly `function_declaration`'s local case (name declared as
local *before* the body resolves, for self-recursion) and `class_declaration` (name declared/global-
slotted before the superclass expression and methods resolve, with the synthetic `super` local
scoped only while methods resolve).

Every validity check currently scattered through `expr.odin`/`stmt.odin` moves here wholesale:
self-inheritance, const reassignment, break/continue outside a loop, return-with-a-value inside an
initializer, return at top level, duplicate name in scope, a variable referencing itself in its own
initializer, and `this`/`super` used outside a class.

Hard invariant: the Resolver never touches `core.Chunk`. `chunk_add_constant`/
`chunk_add_property_cache` stay Emit-side exclusively, since they write into a real target chunk —
the Resolver only ever assigns slot *numbers* (local index, upvalue index, global index), never
bytecode-pool indices. This is what keeps the seam clean for a future type-checker: it needs
resolved variable *kinds* to check assignments and closure captures, but has no reason to touch
`Chunk`, so it can run as a second whole-tree walk immediately after the Resolver and before the
Emitter without restructuring either side.

### try/finally: what the trampoline collapses to

With a `Stmt_Try` node carrying its full `has_finally`/`finally_body` before emission starts, the
trampoline's reason to exist — "a return/break/continue can't know yet whether a finally follows"
— is gone. `Trampoline_Site`, `Try_Finally.pending`, `compile_pending_trampolines`, and
`cross_tries`'s "emit `End_Try` unconditionally, don't know about finally yet" framing are deleted.
Replacement: when the Emitter visits a `Stmt_Return`/`Stmt_Break`/`Stmt_Continue`, it already has
the full ancestor try chain (mirroring `Compiler.tries` today, but built by walking AST nesting,
which *is* lexical nesting) and acts immediately — walks the chain innermost-first up to the target
scope depth, emits `Op_End_Try` for each crossed try (unconditional, unchanged), and if a crossed
try's `has_finally` is true (known directly from the node, not learned later), emits that try's
`finally_body` inline right there. No jump-to-a-deferred-site indirection is needed, since the
Emitter never has to defer anything the way the Parser did.

One genuine wrinkle survives: a `finally` body's own local slot numbers are replay-relative.
Different crossing sites have different numbers of locals live at that point, so the same `finally`
source text needs different slot numbers assigned to its own declarations on each replay — a single
up-front resolve-once-store-on-node pass can't represent that, since the same AST node would need
to resolve to different slots depending on which exit path is being emitted. Local-slot resolution
of a `finally_body` stays a reusable operation (the same `resolve_stmts` primitive used everywhere
else, just callable more than once against one subtree, taking a starting local count and scope
depth), invoked by the Emitter immediately before each of its own emissions of that subtree — once
for the normal-completion landing point, once per crossing site — mutating the subtree's slot
fields, immediately consumed by that emission before the next invocation overwrites them. This is a
direct re-expression of what the current code already does (reusing `Compiler.locals[]` slot
numbers across replays), just driven by re-resolving an AST subtree instead of re-parsing a token
range. `Stmt_Return`'s own `retval_slot` is resolvable once, up front, in the ordinary top-level
pass, since there's exactly one `Stmt_Return` node occupying one lexical position — only the
`finally_body` nested underneath a crossing site is replay-relative. A future type-checker is
unaffected by this: types are structural and only need checking once per `finally_body`, regardless
of how many times its slot numbers get recomputed for different exit paths.

`test_try_except_finally_shape`'s `count_op(c, .Print) == 3` (no crossing return/break/continue in
that test — 2 landing-point finally copies plus the except clause's own `print e`) is reproduced
unchanged under this design: still two resolve-and-emit passes over `finally_body`, at the same two
points `try_except_statement` emits them today. A test adding a crossing return/break/continue
inside a `has_finally` try isn't present in `compile_test.odin` today and should be added during
implementation to lock in the "one additional finally copy per crossing site" behavior explicitly.

### REPL global-slot continuity

`Compile_Repl` currently seeds `Parser.globals`/`globals_declared`/`global_count` before the single
pass runs, since global slot assignment happens during parsing. That state moves to the Resolver:
`Compile_Repl` builds a small seed struct from `Repl_State` (same copy/rebuild helpers as today) and
passes it into the Resolver's construction, which pre-populates its own global table exactly as
`Parser`'s fields are pre-populated today. On success, the Resolver's resulting global table commits
back into `Repl_State`, mirroring `Compile_Repl`'s existing commit-on-success-only logic. `Repl_State`
itself is unchanged.

### File layout

| File | Fate |
|---|---|
| `ast.odin` | New — all `Expr`/`Stmt`/`Function_Decl`/`Param` node types plus `Node_Base`. |
| `parser.odin` | Token-stream driving unchanged; `Parser` shrinks (drops scope/global/compiler fields); `Precedence`/`Parse_Rule`/`parse_precedence`/`expression` retargeted to build and return nodes. `Parser_Snapshot`/`snapshot_pos`/`restore_pos` deleted. |
| `rules.odin` | Same shape and table contents; referenced procs now build nodes. |
| `expr.odin` | Same proc names, rewritten to build-and-return `^Expr`; zero emission. `emit_property_cache` deleted (moves to Emit). |
| `stmt.odin` | Same proc names, rewritten to build-and-return `^Stmt`/`[]^Stmt`; zero scope/emission. `push_loop`/`pop_loop`/`cross_tries`/`emit_crossing_jump`/`finalize_break_or_continue`/`compile_trampolines_after_normal_path`/`compile_pending_trampolines` deleted. |
| `functions.odin` | Keeps the parsing half of `compile_function_body` (params, body as a node list); `emit_closure` moves to `emit.odin`. |
| `compiler_state.odin` | Deleted. `Local`/`Upvalue`/`Loop`/`Try_Finally`/`Class_Compiler`/`Compiler` shapes and locals/upvalues/globals resolution logic move to `resolve.odin`; `emit_*` primitives, chunk/function lifecycle, and the peephole pass move to `emit.odin`. |
| `resolve.odin` | New — the Resolver. |
| `emit.odin`, `emit_expr.odin`, `emit_stmt.odin` | New — bytecode-emission primitives and one emit proc per `Expr_*`/`Stmt_*` variant, mirroring `expr.odin`/`stmt.odin`'s dispatch shape. |
| `compile.odin` | `Compile`/`Compile_Repl` rewritten to run parse -> resolve -> emit as three explicit steps. Public signatures unchanged; no caller-site changes in `main.odin`/`vm/interpret.odin`. |
| `compile_test.odin`, `bc_cache_test.odin`, `scanner.odin`, `scanner_test.odin` | Unchanged. |

## Implementation order

Given the size of this refactor (`stmt.odin` alone is 1261 lines, and nearly every file in the
package changes), do all of it on a dedicated branch, `compiler-ast-split`, created off `master`
before phase 1 starts, rather than on `master` directly — the phase-by-phase new-files-alongside-
old-files approach below is designed to keep intermediate commits reviewable and revertible, which
only matters if they're not landing on `master` as they go. Merge back to `master` only at cutover
(phase 8), once the full existing test suite passes unmodified against the new pipeline.

Build the new pipeline in new files alongside the untouched old ones, sharing the unchanged
token-stream-driving procs from day one, and only delete/rename at a single cutover commit. Each
phase has its own gate before moving to the next:

1. **AST types** — no behavior, just type definitions. Zero risk, independently reviewable.
2. **Pratt-to-AST parser, expressions only** — rewrite `expr.odin`'s logic into node-building form
   behind a temporary entry point, not yet wired into `Compile`. New tests assert AST shape for a
   representative slice (precedence, assignment, ternary, calls, property access, subscripts,
   literals, tuples) — `compile_test.odin` can't apply yet, since it asserts opcodes and none exist
   before Emit.
3. **Statements** — same treatment for declaration/statement dispatch, all control flow, function/
   class declarations, and `try`/`except`/`finally` as a plain AST node (no trampoline logic yet).
   New tests assert full-program AST shape, including an AST-shape version of
   `test_kitchen_sink_program_compiles`'s source.
4. **Resolver, non-try/finally-crossing case first** — locals/upvalues/globals/validity checks for
   ordinary declare/reference/assign, function nesting/closures, classes/`this`/`super`, break/
   continue/return without an enclosing try. Unit-tested directly against known-good/known-bad
   programs (shadowing yields increasing slot numbers, a forward-referenced global gets a slot on
   first mention, self-reference in an own initializer errors).
5. **Emitter, everything except try/finally crossing** — driven off Resolver output. Parameterize
   `compile_test.odin`'s `compile_ok` behind an old/new pipeline switch so the existing suite
   exercises both without duplication; run it against the new path for every test not involving
   try/except/finally control-flow crossing.
6. **try/finally** — the highest-risk phase, isolated on its own. Implement the Resolver's
   per-crossing-site `finally`-subtree local-resolve trigger and the Emitter's inline crossing logic.
   Re-run every try/except/finally test in `compile_test.odin` against the new path checking exact
   opcode counts, and add new coverage for a crossing return/break/continue inside a `has_finally`
   try.
7. **REPL** — wire `Compile_Repl`'s seeding through the Resolver's top-level state; verify both REPL
   continuity regression tests against the new path.
8. **Cutover** — switch `Compile`/`Compile_Repl` to the new pipeline, delete the old
   `expr.odin`/`stmt.odin`/`compiler_state.odin`/old parsing bits, land on the final file layout
   above. Run the entire `compile_test.odin` and `bc_cache_test.odin` unmodified; confirm
   `main.odin:235` and `vm/interpret.odin:24-27` need no changes.

## Verification plan

- Each phase above gates on its own tests before the next begins: AST-shape tests for phases 2-3,
  direct Resolver unit tests for phase 4, the parameterized full `compile_test.odin` suite for
  phases 5-7.
- Final gate: `compile_test.odin` and `bc_cache_test.odin` pass unmodified, exercising the new
  pipeline exclusively through `Compile`/`Compile_Repl`, with `test_try_except_finally_shape`'s
  `count_op(c, .Print) == 3` and both REPL continuity tests passing exactly as today.
- No new test infrastructure needed for the final gate — the existing opcode-sequence/shape
  assertion style in `compile_test.odin` is the acceptance mechanism throughout.
- Beyond the unit-test gate, run a manual `--compile-only` pass over the repo's existing `.lox`
  script corpus (`lox_examples/`, `tests/new_tests/lox/`) as a smoke check, since those scripts
  exercise language-surface combinations no single hand-written test enumerates.
