# Peephole-fuse and self-specialize `++` (vector add)

**Status**: design only, not yet implemented. Written in response to a "can vec ops be peephole
optimised?" question; the authoring session had no Odin toolchain available (no `odin` binary, no
prebuilt `bin/odlox`, and this repo's GitHub access is scoped away from `odin-lang/Odin`), so nothing
here has been built, run, or benchmarked yet — see "First step for whoever picks this up" below.

## Context

`ROADMAP.md`'s Phase 7a ("mandel investigation and the arithmetic self-patching fix") added the
`Add_Nn`/`Incr_Const_N` peephole family: `compiler/emit.odin`'s `peephole_optimise` rewrites the
fixed 8-byte shape `Get_Local a; Get_Local/Constant b; Add_Numeric; Set_Local a; Pop` into a fused
`Add_Nn`/`Incr_Const_N` instruction (3 live bytes + 5 `Noop` padding, so already-computed jump
offsets elsewhere in the chunk never shift). At runtime (`vm/run.odin:175-234`), `Add_Nn`/
`Incr_Const_N` self-specialize by patching their own opcode byte in place on first execution: an
Int/Int hit becomes `Add_Ii` forever, a Float/Float hit becomes `Add_Ff` forever, and a mixed hit
just computes the generic float result and never patches (`docs/ARCHITECTURE.md`'s own description:
"don't patch if types don't match, just compute generically — keeps the generic form available for a
call site that later sees a different type combination").

`docs/plans/inline-vec-value.md` (shipped) inlined `Vec2`/`Vec3`/`Vec4` directly into `Value`'s
`#raw_union` payload (`core/value.odin:34-38`) — a vector `Value` is a true, GC-invisible, ~40-byte
copy, exactly like an Int or Float `Value`. `++` (`Op_Code.Add_Vector`, `compiler/rules.odin:30-36`,
`emit_expr.odin:102-103`) is the vector-only counterpart to `+`/`Add_Numeric`, added specifically
because the compiler can't know an operand's runtime type — `expr.odin`'s binary-operator dispatch
picks the opcode, the opcode itself does the type check at runtime (`vm/arithmetic.odin:52-74`).

Because a vector `Value` is exactly as cheap to shuffle between stack slots as a scalar one, `v3 = v1
++ v2` with all-local operands compiles to the *identical* 8-byte skeleton the numeric fusion already
pattern-matches on — just `Add_Vector` in place of `Add_Numeric` as the 5th byte:

```
Get_Local slot_a   (2 bytes)
Get_Local slot_b   (2 bytes)
Add_Vector         (1 byte, no operand -- same shape as Add_Numeric)
Set_Local slot_a   (2 bytes)
Pop                (1 byte)
```

This is directly reachable in the kind of real-time script `CLAUDE.md` already flags for allocation
discipline (60fps-class graphics/physics loops) — a per-frame `pos = pos ++ vel`-shaped update is
exactly this shape, and currently pays a full `Get_Local`×2 / `Add_Vector` / `Set_Local` / `Pop` stack
round-trip every frame with no fusion at all.

## Scope

- **Only the two-local shape exists for vectors.** Unlike `Add_Nn`'s `Constant`-second-operand sibling
  (`Incr_Const_N`), no vector `Constant`-operand case is reachable: `Expr_Literal.kind` has no vector
  variant (`compiler/emit_expr.odin:75-89` only handles `.Int/.Float/.String/.Bool/.Nil`) — a vector is
  *always* produced by a `vec2()/vec3()/vec4()` call (`Op_Call`, not `Op_Constant`) or by another
  `Add_Vector`/property read, never by the compile-time constant pool. So this plan needs no
  `Incr_Const_V` analog — just one fused opcode, `Add_Vv`, mirroring `Add_Nn` alone.
- **No compound `++=` exists.** `scanner.odin:25` lists `Plus, Plus_Equal, Plus_Plus` — there is no
  `Plus_Plus_Equal` token, and `emit.odin`'s `compound_op_code` (`:359-373`) has no vector case. Nothing
  to add here; if compound vector assignment is ever added as a separate feature, it would get its own
  fusion opportunity later, out of scope now.
- Non-local operands (globals, upvalues, one side a call result, etc.) are unaffected, same as today's
  numeric fusion — the peephole matcher only ever fires on the exact local-slot byte shape above.

## Design decision: don't blindly trust the patch, unlike `Add_Ii`/`Add_Ff`

This is the one place this plan deliberately diverges from the `Add_Nn` precedent, and the reasoning
matters enough to spell out.

`Add_Ii`/`Add_Ff` (`vm/run.odin:191-204`), once patched, never re-check operand types — they call
`core.as_int`/`core.as_float` unconditionally. This is safe *for that family specifically* because
`as_int`/`as_float` (`core/value.odin:134-152`) both already handle Int-or-Float gracefully (an
Int-patched site fed a Float still produces *a* number, just via truncating conversion) — there is no
operand-type combination that family can be handed which produces anything worse than a numerically
different-than-ideal-but-still-a-number result. That's what makes "patch once on the first hit, trust
it forever" an acceptable tradeoff there.

Vector arity has no equivalent safe universal fallback. `add_vector` (`vm/arithmetic.odin:52-74`)
raises a real runtime error on a type mismatch (`"Vector operands must be the same type."`) or a
non-vector operand (`"Operands must be vectors."`) — confirmed in conversation with the user that a
mismatched-arity `++` (`vec2(...) ++ vec3(...)`) is always a genuine bug in the Lox script, never
intentional, so keeping that as a hard error in the fused/specialized path is correct and doesn't need
a graceful fallback value the way int/float does.

The risk this plan does need to design around is different: **a call site being polymorphic across
separate calls**, which is not a coding error. Lox is dynamically typed — a function like
`func add(a, b) { return a ++ b }` can legally be called once with two `Vec2`s and later, elsewhere in
the same run, with two `Vec3`s. `Add_Nn`'s unconditional-trust-after-first-patch design is only sound
because every post-patch input still produces *some* correct-shaped number; blindly porting the same
"patch once, never recheck" strategy to vectors would mean a call site patched to `Add_V2` on its first
(all-`Vec2`) call would, on a later all-`Vec3` call, run `Add_V2`'s 2-lane logic against `Vec3` operands
with **no error at all** — silently computing a wrong `Vec2`-shaped result (or reading past the
meaningful lanes) instead of raising `"Vector operands must be the same type"`-style feedback. That's a
correctness regression relative to today's unfused `add_vector`, not just a missed optimization.

**Decision**: `Add_V2`/`Add_V3`/`Add_V4` keep a cheap type-tag guard on every execution (a single
`Value.type` enum compare each operand already has loaded) rather than trusting the patch
unconditionally. A guard hit takes the fast inline-lane-add path with no re-patching needed; a guard
miss falls through to the same type-check-and-possibly-error logic `Add_Vv`'s own first-hit path uses
(re-derive from current operand types, patch to a *different* specialized opcode if this new
combination is itself monomorphic-and-valid, or raise the same `add_vector` error otherwise). This
keeps the primary win intact — the fast, common, monomorphic-call-site case still skips the
push/pop/peek stack traffic the peephole targets — without introducing a silent-corruption path that
`Add_Ii`/`Add_Ff` gets to skip only because int/float coercion has no failure mode to guard against.

## Implementation

### 1. `src/core/chunk.odin` — new opcodes

Add `Add_Vv`, `Add_V2`, `Add_V3`, `Add_V4` to the `Op_Code` enum, in the existing "self-specializing
arithmetic family" block (`:124-130`, right after `Incr_Const_F`). Extend the file's header doc comment
(`:7-14`) to mention this second family alongside `Add_Nn`/`Incr_Const_N`, explicitly noting the
type-guard deviation from the numeric family's "patch once, trust forever" behavior (a future reader
skimming both families side by side should not assume they work identically).

### 2. `src/compiler/emit.odin` — `peephole_optimise`

Add a third pattern branch alongside the existing `Add_Nn`/`Incr_Const_N` checks (`:399-418`): same
`is_get_local`/`code[i+2] == Get_Local` shape, but keyed on `code[i + 4] == u8(core.Op_Code.Add_Vector)`
instead of `Add_Numeric`. Fuse via the existing `fuse(code, i, .Add_Vv, code[i+1], code[i+3])` helper —
no changes needed to `fuse` itself, since the byte width (3 live + 5 `Noop`) is identical. No
`Constant`-operand branch is needed here (see Scope above).

### 3. `src/vm/run.odin` — dispatch cases

Add four new `case` arms near the existing `Add_Nn`/`Add_Ii`/`Add_Ff` block (`:175-204`):

- **`Add_Vv`**: read both operand slots directly off `vm.stack` (no push), same as `Add_Nn`. If
  `a.type == b.type` and that type is `.Vec2`/`.Vec3`/`.Vec4`, patch `fl.code[op_ip]` to the matching
  `Add_V2`/`Add_V3`/`Add_V4` and compute the lane-wise sum inline (mirror `arithmetic.odin:60-68`'s
  three `#partial switch` cases exactly — same per-lane math, just writing the result back into
  `slot_a` instead of pushing). Otherwise call `runtime_error` with the exact same message
  `add_vector` uses for that case (`"Vector operands must be the same type."` for a type mismatch,
  `"Operands must be vectors."` for a same-type-but-non-vector pair) — **do not patch** on this path,
  matching `Add_Nn`'s own "stay generic on a non-matching hit" behavior.
- **`Add_V2`/`Add_V3`/`Add_V4`**: guard first (`a.type == .Vec2` etc., per the Design decision above).
  On a guard hit, inline lane-add and store back, no error path needed. On a guard miss, fall through
  to exactly the same type-check-or-error logic as `Add_Vv`'s own non-matching path (re-derive and
  possibly re-patch to a *different* specialized opcode, or raise the same two `add_vector` messages) —
  this is the one new piece of logic without a direct `Add_Ii`/`Add_Ff` precedent to copy byte-for-byte,
  since that family never needs a post-patch fallback at all.

### 4. `src/debug/disassemble.odin`

Add `Add_Vv`/`Add_V2`/`Add_V3`/`Add_V4` next to the existing `Add_Nn, Add_Ii, Add_Ff` group (`:192`) —
same operand-count/formatting treatment (two raw slot-index bytes, no constant-pool lookup).

### 5. `src/compiler/emit_test.odin` — `decode()`

Add `.Add_Vv` to the `n = 2` operand-count case list (`:38-40`, alongside `.Add_Nn`/`.Incr_Const_N`) so
compile-time chunk-decoding tests can see past a fused vector-add instruction correctly. `Add_V2`/
`Add_V3`/`Add_V4` don't need entries here — like `Add_Ii`/`Add_Ff`, they only ever appear via runtime
self-modification, never emitted directly by `Emit`, so no compile-time test ever decodes one.

## Benchmark

New `benchmarks/lox/vec_ops.lox`, modeled directly on the existing `benchmarks/lox/loop.lox` (the
benchmark written for the *numeric* version of this exact optimization) — a tight loop that exercises
all three vector arities' `++` on function-local variables, timed with `sys.clock()`:

```
import sys

// Tight loop benchmark targeting the vec-add peephole/self-specialization
// (docs/plans/vec-op-peephole.md). All operands are function-locals so the
// compiler emits Add_Vv, self-specializing per call site to Add_V2/Add_V3/
// Add_V4 once implemented -- Add_Vector (unfused) today.

func tight(n) {
  var a2 = vec2(1, 1)
  var b2 = vec2(2, 2)
  var a3 = vec3(1, 1, 1)
  var b3 = vec3(2, 2, 2)
  var a4 = vec4(1, 1, 1, 1)
  var b4 = vec4(2, 2, 2, 2)
  var i = 0
  while (i < n) {
    a2 = a2 ++ b2
    a3 = a3 ++ b3
    a4 = a4 ++ b4
    i = i + 1
  }
  return a2.x + a3.x + a4.x
}

var start = sys.clock()
print tight(5000000)
print sys.clock() - start
```

Also add `benchmarks/lox/vec_ops.py`, a plain-Python equivalent (tuple or three-float-field arithmetic
in the same loop shape), matching every other `benchmarks/lox/*.lox` having a `benchmarks/python/*.py`
sibling — needed for `bin/benchmarks.sh` to pick this benchmark up in its comparison table without
erroring on a missing file.

Loop iteration count (`5000000`, vs. `loop.lox`'s `50000000`) is a starting guess, not measured — three
vector arities per iteration is roughly 3x the per-iteration work of `loop.lox`'s two scalar ops, so
this errs lower; adjust once a real run shows the actual wall-clock range (should land in the same few-
seconds ballpark `loop.lox` targets, per that file's own tuning).

### Running it

```
bin/build.sh --release
python bin/time_lox.py benchmarks/lox/vec_ops.lox --runs 10
# or, for the full comparison table (needs GLOX_EXE or accepts the "n/a" glox column):
bin/benchmarks.sh
```

### First step for whoever picks this up

Run the benchmark *before* touching any implementation code, on `Add_Vector` as it stands today
(unfused), and record the `Average: N.NNNN seconds` line here as the baseline — this doc currently has
no numbers because the authoring session had no Odin toolchain available to build `bin/odlox` at all.
Re-run the identical command after implementation and record both numbers side by side, the same way
`docs/plans/inline-vec-value.md`'s own "Verification" section points at `ROADMAP.md`'s entry for its
before/after counts.

## Tests

**Existing coverage gap worth closing regardless of this change**: a repo-wide search turned up *zero*
existing tests anywhere (`tests/new_tests/`, `src/vm/*_test.odin`, `src/compiler/*_test.odin`) that
exercise `++`/`Add_Vector` at all — not even a basic `vec2(1,2) ++ vec2(3,4)` correctness check. Add
that baseline coverage first, then the fusion/specialization-specific tests below on top of it.

- **`src/vm/builtins_test.odin`** (where the existing `vec2(...)`/swizzle tests already live, `:99-199`):
  - `test_vec2_add_operator`/`test_vec3_add_operator`/`test_vec4_add_operator`: basic `++` correctness
    for each arity, component-wise.
  - `test_vec_add_type_mismatch_errors`/`test_vec_add_non_vector_errors`: `expect_runtime_error` (same
    helper used at `vm_test.odin:212`) for `vec2(1,2) ++ vec3(1,2,3)` and `1 ++ 2`, asserting the fused/
    specialized path (both operands as locals, so this hits `Add_Vv`/the specialized opcodes, not the
    generic unfused `add_vector`) preserves the exact same two error messages `arithmetic.odin` already
    raises.
  - **`test_vec_add_polymorphic_call_site`**: the test that actually validates this plan's central design
    decision. A function whose body does a local-local `++` (so its call site gets peephole-fused, then
    self-specializes), called first with two `Vec2` arguments (patches to `Add_V2`), then called again
    — same function, same bytecode site — with two `Vec3` arguments. Assert the *second* call still
    returns the correct `Vec3` sum, not a `Vec2`-shaped or corrupted result. This is the regression guard
    against the exact silent-corruption failure mode the Design decision section above exists to prevent
    — without it, a future "simplify this to match `Add_Ii`/`Add_Ff` exactly" refactor could reintroduce
    that bug with nothing to catch it.
- **`src/compiler/emit_test.odin`** (alongside `test_emit_peephole_fuses_local_increment`, `:582-587`):
  - `test_emit_peephole_fuses_local_vector_add`: compile `"func f() {\nvar a = vec2(1, 1)\nvar b =
    vec2(2, 2)\na = a ++ b\nreturn a\n}\n"`, assert `contains_op(fn_chunk, .Add_Vv)` and
    `!contains_op(fn_chunk, .Add_Vector)` — direct mirror of the existing numeric test.
  - `test_emit_peephole_leaves_non_local_vector_add_unfused`: a global- or upvalue-operand `++` still
    emits plain `Add_Vector`, unaffected by the new pattern branch (the numeric fusion has no equivalent
    negative test today; add one for the new code since it's easy and cheap while writing the matcher).

Run via `python -m pytest tests/new_tests/ -q` and `odin test src -define:ODIN_TEST_THREADS=1` (per
`TODO.md`/`ROADMAP.md` Phase 0's allocator-lifetime note) after every change; `odin check src -vet
-strict-style -vet-tabs -disallow-do -warnings-as-errors` must stay clean throughout.

## Documentation

- `docs/ARCHITECTURE.md`: extend the existing "self-specializing arithmetic family" description
  (`:719-727`, `:864-870`, `:985-996`) to cover the new vector family, explicitly calling out the
  type-guard divergence from `Add_Ii`/`Add_Ff` and why (same reasoning as the Design decision section
  above — don't just say "same mechanism, different opcodes").
- `ROADMAP.md`: add a Phase 7 sub-entry once shipped, cross-referencing Phase 7a (the original numeric
  version of this optimization) the way `docs/plans/done/*.md` entries already do for their own
  ROADMAP.md phases.

## Risks / open questions

1. **Guard cost on the fast path.** The type-tag guard on `Add_V2`/`Add_V3`/`Add_V4` is a single enum
   compare per operand — cheap, but it does mean this family is not a byte-for-byte translation of
   `Add_Ii`/`Add_Ff`'s "zero-check" fast path. Worth confirming with a real benchmark number (see
   above) that the guard doesn't erase enough of the win to make the whole feature not worth it; the
   expectation is it won't (a couple of enum compares vs. a full `Get_Local`×2/`Set_Local`/`Pop` stack
   round-trip avoided), but this plan doesn't have a number yet to back that up.
2. **Four-way specialization vs. two-way.** `Add_Nn` only ever needed two children (`Ii`/`Ff`); `Add_Vv`
   needs three (`V2`/`V3`/`V4`), and a guard-miss on a specialized opcode needs to decide whether to
   re-patch to a *different* specialized opcode (if the new combination is itself monomorphic-valid) or
   fall all the way back to generic dispatch. Get this transition logic right in one place (ideally a
   shared inline proc both `Add_Vv`'s and each `Add_VN`'s guard-miss path call, rather than duplicated
   inline three times) rather than copy-pasted three times with room for one copy to drift.
3. **Whether to ever de-specialize back to `Add_Vv`** on repeated guard misses at the same site (a
   genuinely polymorphic hot call site would otherwise pay the guard-miss/re-patch cost every time it
   alternates) is explicitly out of scope for v1 — no evidence yet that this pattern is common enough in
   real scripts to justify the extra bookkeeping (a per-site miss counter, a threshold). Revisit only if
   a real profiled script shows it matters.
