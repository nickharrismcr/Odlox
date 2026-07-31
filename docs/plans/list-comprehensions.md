# List comprehensions

**Status**: design only, not yet implemented. Written in response to a "what would this take" question,
not yet scheduled against `ROADMAP.md`'s phases.

## Context

odlox is a Lox-language bytecode interpreter (Odin, single-pass compiler, clox-style) already extended with
several Python-inspired features (lists, dicts, tuples, `foreach`, destructuring, string interpolation).
This design covers adding Python-style list comprehensions (`[x * 2 for x in items if x > 0]`). This has
never been discussed or planned before (no mention of "comprehension" anywhere in `TODO.md`/`ROADMAP.md`/
`docs/ARCHITECTURE.md`/`docs/language-reference.html` — greenfield). The goal is to collapse the common
"build an empty list, `foreach` over a source, conditionally `append`" pattern (4-5 lines) into one
expression, following this codebase's own established idiom of implementing new sugar as **compile-time
desugaring into existing opcodes**, never inventing a new opcode for a new piece of syntax (see compound
assignment, `src/compiler/expr.odin:199-249`, which desugars `+=` into `Get_* / <rhs> / Add_Numeric / Set_*`
with no dedicated opcode, pinned by `test_compound_assignment_desugars_no_dedicated_opcode` in
`compile_test.odin`).

**Grammar scope**: v1 supports exactly one `for` clause and one optional trailing `if` filter:
```
comprehension → "[" expression "for" IDENTIFIER "in" expression ( "if" expression )? "]"
```
Python's multi-`for`/multi-`if` chained form (`[x for row in matrix for x in row]`) is **out of scope for
v1** — that case is already expressible today as nested `foreach`, and works "for free" as a nested
comprehension (`[[y for y in row] for row in matrix]`) the moment single-clause support ships, since that's
just `expression()` recursing into `list_literal` again with no extra code. Multi-clause chaining is a
natural, additive follow-up if ever wanted, not a re-architecture.

## Key design correction from initial research

An initial design pass (via a Plan subagent) proposed detecting a comprehension by parsing the element
expression once for real via `expression(p)`, checking if `.For` follows, and — if so — **rolling back** by
`resize`-truncating `current_chunk(p).code`/`.lines` and using `restore_pos` to rewind the token cursor, then
parsing the `for`/`if` clause for real (declaring the loop variable as a local), then re-parsing the element
expression a second time so it now resolves correctly.

**This is unsafe and must not be implemented this way.** Verified directly
(`src/compiler/compiler_state.odin:359-368`, `378-388`): unresolved identifiers don't error at compile time
— `resolve_variable` falls back to `global_slot(p, name)`, which **permanently** reserves a global-name slot
in `p.globals`/`p.global_count`/`p.global_names_by_slot` the moment a name is first *mentioned*, specifically
so forward references to not-yet-declared globals work (see that function's own doc comment). This state
lives on the `Parser`, not the `Chunk` — truncating `chunk.code`/`chunk.lines` does **not** undo it. Since
`[x * 2 for x in items]`'s element expression (`x * 2`) is written *before* `x` is declared as a local (the
`for` clause comes after), a first real parse of it — before `x` exists as a local — would resolve `x` as a
global and **permanently pollute the global-slot table with a phantom "x" entry** for every comprehension
compiled, wasting a slot and potentially surfacing in anything that enumerates global names (`inspect`,
REPL). It would also waste an undeduplicated `Property_Cache` slot (`chunk_add_property_cache` never
deduplicates, unlike `chunk_add_constant`) if the element expression contains a method/property access, and
could double-emit a diagnostic if the element expression is malformed.

**Correct mechanism — already established in this exact codebase**: use a lightweight, **side-effect-free
lookahead skip** to *detect* whether this is a comprehension, without ever calling `expression(p)` until
locals are ready. This is precisely the idiom `looks_like_destructuring` already uses (`src/compiler/
stmt.odin:296-318`): calls only `advance(p)`/`check(p, ...)` (pure token-cursor movement, zero
codegen/resolution side effects), wrapped in `snap := snapshot_pos(p); defer restore_pos(p, snap)`. The
element expression is then parsed **exactly once**, in the correct position (after the loop variable is a
real local), via `restore_pos` back to a saved starting snapshot — never discarded/redone.

## Implementation

### 1. `src/compiler/expr.odin` — `list_literal` (currently lines 423-441)

Keep the existing empty-list and plain-list-literal code paths byte-for-byte unchanged. Add, right after the
opening `[` is consumed and before parsing any element:

- `elem_snap := snapshot_pos(p)`
- A new private helper, e.g. `is_list_comprehension :: proc(p: ^Parser) -> bool`, modeled directly on
  `looks_like_destructuring`: snapshots position, then repeatedly `advance`s while tracking bracket/paren/
  brace depth (`(`, `[`, `{` push; `)`, `]`, `}` pop), stopping and returning `true` the moment it sees
  `.For` at depth 0, or `false` the moment it sees `.Comma`, `.Right_Bracket`, or `.Eof` at depth 0. Always
  `defer restore_pos(p, snap)` — this function only ever peeks, it never leaves the cursor moved.
- If `is_list_comprehension(p)` returns `false`: fall through to the existing loop, completely unmodified.
- If `true`: call a new `list_comprehension(p, elem_snap)` and return.

### 2. `src/compiler/expr.odin` — new `list_comprehension` proc

Called with the cursor sitting exactly at the start of the element expression's tokens (from `elem_snap`,
already restored by the detection helper's `defer`). Steps:

1. `emit_op_byte(p, .Create_List, 0)` — the accumulator, starts empty.
2. Register the accumulator as a local **before** `begin_scope`, so it survives the nested scope's
   `end_scope` cleanup (mirrors why `foreach_statement`'s hidden locals are declared *after* its own
   `begin_scope`, just inverted — the accumulator must outlive the loop's scope since it's the
   comprehension's result). Use a synthetic empty-name token the same way `foreach_statement` does for
   `__iter` (`synthetic_token(.Identifier, "__acc", p.previous.line)`), then `add_local` + `mark_initialised`;
   record `acc_slot`.
3. `begin_scope(p)`.
4. Skip forward past the element-expression tokens without parsing them (reuse the same depth-tracking walk
   `is_list_comprehension` did, or simply call `restore_pos` to a snapshot taken at the `for` token during
   detection — capture that as part of `is_list_comprehension`'s return, e.g. change its signature to
   return `(is_comprehension: bool, for_snap: Parser_Snapshot)` so `list_comprehension` doesn't have to
   re-scan). Land the cursor at `for`.
5. Parse the clause for real, exactly like `foreach_statement` (`stmt.odin:585-654`) does for its own loop
   variable/`__iter`/`Foreach`/body/`Next`/`End_Foreach`, reusing that shape directly:
   - `consume(p, .For, ...)`, `consume(p, .Identifier, ...)` for the loop variable name; `emit_op(p, .Nil)`
     placeholder, `add_local`, `mark_initialised`, record `var_slot` (same reasoning as `foreach_statement`'s
     own comment on why the `Nil` push is load-bearing).
   - `consume(p, .In, ...)`; `expression(p)` for the iterable; `add_local(p, synthetic_token(.Identifier,
     "__iter", ...))`, `mark_initialised`, record `iter_slot`.
   - Emit `Op_Foreach` (var_slot, iter_slot, 2-byte forward jump placeholder — `end_jump`).
   - `loop_start := len(current_chunk(p).code)`.
   - Optional `if`: `match(p, .If)`; if present, `expression(p)` for the condition, `emit_jump(p,
     .Jump_If_False)` → `skip_jump`, `emit_op(p, .Pop)`.
6. Emit the append: `emit_op_byte(p, .Get_Local, acc_slot)`, then — **the one and only real parse of the
   element expression** — `body_snap := snapshot_pos(p)` (save where clause-parsing left off),
   `restore_pos(p, elem_snap)`, `expression(p)` (now resolves the loop variable correctly as a local),
   `restore_pos(p, body_snap)` (resume after the clauses). Then emit the `Invoke` call exactly like `dot()`'s
   own call-with-args shape (`expr.odin:362-368`): `name_const := core.chunk_add_constant(current_chunk(p),
   core.make_string_value("append"))`, `emit_op_byte(p, .Invoke, name_const)`, `emit_byte(p, 1)` (arg_count),
   `emit_property_cache(p)`, then `emit_op(p, .Pop)` to discard `append`'s `nil` return.
7. If there was an `if` filter: mirror `if_statement`'s exact Jump_If_False/Pop/Jump/Pop shape
   (`stmt.odin:409-444`) — emit `Jump` to skip the false-branch `Pop`, `patch_jump(skip_jump)`, `emit_op(p,
   .Pop)` (discard the false condition value), patch the `Jump`'s target after that `Pop`. This is not
   optional/stylistic: omitting it would let the true branch fall through into the false branch's `Pop`,
   double-popping the stack.
8. Emit `Op_Next` (2-byte back-jump computed the same way `foreach_statement` does — `len(current_chunk(p).
   code) - loop_start + 4` — plus `var_slot`, `iter_slot`), then `Op_End_Foreach`, then `patch_jump(end_jump)`.
9. `end_scope(p)` — pops `var_slot`/`iter_slot` only (added after `begin_scope`); `acc_slot` (added before)
   survives, left on the stack as the list-literal's result.
10. `consume(p, .Right_Bracket, "Expect ']' after list comprehension.")`.

No `push_loop`/`pop_loop`/break/continue bookkeeping is needed — verified `.Break`/`.Continue` are only ever
dispatched from `statement()`'s keyword table (`stmt.odin:92,95,851,853`), never reachable from
`expression()`'s Pratt table, so they're syntactically unreachable inside a comprehension's clauses.
`loop_start` is just a local variable, not `push_loop`'s tracked-loop machinery.

**Resulting opcode sequence for `[x * 2 for x in items if x > 0]`** (no new opcode invented):
```
Create_List 0                      ; accumulator
Nil                                ; loop var placeholder
<code for `items`>                 ; iterable -> __iter
Foreach var_slot iter_slot -> end
loop_start:
  <code for `x > 0`>
  Jump_If_False -> skip
  Pop
  Get_Local acc_slot
  <code for `x * 2`>                ; the ONE real parse of the element expr
  Invoke "append" 1
  Pop
  Jump -> after_skip
  skip: Pop
  after_skip:
Next -> loop_start  var_slot iter_slot
End_Foreach
end:
                                    ; end_scope pops var_slot, iter_slot
                                    ; acc_slot's value remains on the stack
```

## Tests

Follow the existing `tests/new_tests/` pattern exactly (see `test_dict.py` + `dict.lox`/`dict_ns.lox`, both a
semicolon and no-semicolon fixture run by one parametrized test):

- New `tests/new_tests/lox/comprehension.lox` / `comprehension_ns.lox` covering: basic map (`[x * 2 for x in
  [1,2,3,4,5]]`); filtered (`[x for x in range(10) if x % 2 == 0]`, exercising the native `Int_Iterator`
  path); string iterable (`[c for c in "abc"]`); empty-iterable result (`[]`); a case where the element
  expression's loop variable shadows an outer variable of the same name, asserting the outer one is
  unaffected afterward (proves the loop-variable scope is properly closed and doesn't leak); a nested
  comprehension (`[[y * 2 for y in row] for row in [[1,2],[3,4]]]`, exercising bracket-in-bracket for free);
  an element expression involving a method/property call, to exercise `Invoke`'s cache-slot path inside the
  real (only) parse of the element expression.
- New `tests/new_tests/test_comprehension.py`, parametrized over both fixtures, asserting on `run_lox(...)`'s
  stdout lines — verify the exact list `print`/`str()` formatting convention (`"[ 1 , 2 , 3 ]"`-style
  spacing, per `test_dict.py`'s existing assertions) against an existing list fixture before writing new
  assertions, don't assume it.
- New compiler-level bytecode-shape tests in `src/compiler/compile_test.odin`, mirroring
  `test_compound_assignment_desugars_no_dedicated_opcode` (lines ~317-336):
  - `test_list_comprehension_desugars_no_dedicated_opcode`: compile `"var items = [1, 2, 3]\nvar r = [x * 2
    for x in items if x > 0]\n"`, assert the op sequence contains `Create_List`, `Foreach`, `Next`,
    `End_Foreach`, `Invoke`, `Jump_If_False` — i.e., the desugaring, not a dedicated opcode.
  - `test_list_comprehension_plain_list_still_works`: a regression guard that an ordinary list literal
    (`[1, 2, 3]`) is unaffected by the new `is_list_comprehension` detection — still emits exactly
    `Create_List` with no `Foreach`.

Run via `python -m pytest tests/new_tests/ -q` (the real correctness gate) after every change; `odin check
src -vet -strict-style -vet-tabs -disallow-do -warnings-as-errors` must stay clean throughout. If adding/
running the new Odin-level compiler tests directly via `odin test`, use `-define:ODIN_TEST_THREADS=1`
(required for this codebase — see `TODO.md`/`ROADMAP.md` Phase 0 for the known, unrelated, already-
documented allocator-lifetime reason).

## Documentation

- `docs/language-reference.html`: add a "List comprehensions" subsection under the existing Lists section
  (near line 666), with the grammar, 2-3 examples (map, filter, map+filter), an explicit note that it
  desugars to `foreach`+`append` at compile time (matching this doc's existing style of calling out
  performance-relevant desugaring, e.g. the `range()` tip at line 414), that bracket-in-bracket nesting
  already works, and that Python's chained multi-`for` form is not yet supported (say what to write
  instead).
- `README.md`: extend the feature-summary list (near the `foreach`/`break`/`continue` bullet or the
  Dictionaries bullet) with a short "List comprehensions" mention.

## Risks / open questions

1. The lookahead-skip helper (`is_list_comprehension`) must track `(`/`)`, `[`/`]`, and `{`/`}` depth
   correctly and stop cleanly on `.Eof` (malformed/truncated input) so the fallback plain-list path's own
   existing error handling (`consume(p, .Right_Bracket, ...)`) reports the error normally, rather than the
   skip helper looping past the end of input.
2. 256-local ceiling (`compiler_state.odin:237-239`): each live comprehension holds 3 slots (accumulator,
   loop var, `__iter`) for its dynamic extent; deeply nested comprehensions-within-comprehensions stack
   these 3× per level — same cost class as any other nested block/loop, not a new risk, just worth a mental
   note.
3. `Create_List`'s existing 255-element `u8` operand cap applies only to *literal* lists (`list_literal`'s
   `count > 255` check) — a comprehension emits `Create_List 0` and grows at runtime via `append`, so no
   equivalent cap applies or is needed; don't let a future reader "fix" this as if it were an oversight.
4. Verify the exact list `print`/`toString` formatting string before writing test assertions (mentioned
   under Tests above) — the most likely source of a spurious first-draft test failure is a mismatched
   literal string, not a real bug.
