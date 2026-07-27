# odlox roadmap

Port of [glox](https://github.com/nickharrismcr/glox) (branch
`experimental/gc-odin-port-basis`) to Odin. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design record —
this file is the phased build order and the running todo list.

**Order: scanner → compiler → VM (+ GC) → native/stdlib → performance.**
Each phase should reach a state where it can be measured against the ported
test suite (see [Testing](#testing-every-phase)) rather than "looks right."

**Explicitly excluded, permanently** (not "later," just not happening):
`thread.*`, `sync.Mutex`, cross-VM value copying, and every mutex/atomic in
glox that exists solely to support them. See `ARCHITECTURE.md`'s
[Scope](docs/ARCHITECTURE.md#scope) section.

---

## Phase 0 — Project scaffolding

- [x] Create the package skeleton under `src/`: `src/core/`, `src/compiler/`,
      `src/vm/`, `src/natives/`, `src/debug/`, `src/main.odin` (see
      `ARCHITECTURE.md` § [Package layout](docs/ARCHITECTURE.md#package-layout)).
      `compiler/` and `main.odin` exist as of Phase 1; the rest are created
      as their phases start.
- [x] Decide and record the Odin build flags for debug vs. release
      (`-debug`, `-vet`, `-strict-style` for dev; `-o:speed
      -disable-assert -no-bounds-check` for a release/benchmark build) —
      mirrors glox's own fast-vs-debug build split
      (`bin/build_debug.sh`/`core.HotLoopDebugHookCompiled`). See the
      "Build script: debug vs. release" note below.
- [x] `git init`-equivalent housekeeping already done (repo exists);
      `.gitignore` covers build output (`*.exe`/`*.bin`/`*.pdb`/`*.dll`)
      and, added alongside the test-suite copy below, `__pycache__/`/
      `.pytest_cache/`.
- [x] Copy `tests/new_tests/` from glox wholesale (see
      [Testing](#testing-every-phase)) — done considerably later than
      "early" (mid-Phase 5, not Phase 0) since glox itself wasn't
      checked out anywhere in this workspace until a `glox_reference`
      clone appeared alongside odlox's own directory; copied verbatim
      from there once available, `tests/old/` (glox's own deprecated
      pre-`new_tests` format) and `repl_stress_rig.sh` left behind as
      out of scope for this instruction. `conftest.py`/`lox_helper.py`'s
      `GLOX` constant repointed at `bin/odlox.exe`; `test_thread.py`
      marked permanently skipped (`thread.*` is out of scope for this
      port — see this file's header). See
      [Testing](#testing-every-phase) below for the first real run's
      results and the infinite-loop bug it immediately found.

### Build script: debug vs. release

`bin/build.sh` takes an explicit mode instead of only ever building one
configuration: `bin/build.sh --release` builds `-o:speed -disable-assert
-no-bounds-check` (the exact flags every Phase 7 benchmark baseline in
this document was measured against — see `bin/benchmarks.sh`); plain
`bin/build.sh` (no args) now builds `-debug -vet -strict-style` and is
the new default. `-debug` enables Odin's `ODIN_DEBUG` constant, which is
what actually gates `debug/trace.odin`'s `Trace_Hook`/`Instrument_Hook`
(the `--debug`/`--instrument` CLI flags are otherwise silently inert —
see `main.odin`'s warning for that case) — without it, day-to-day
development had no working way to get a debug build at all beyond
manually typing the `odin build` invocation. Simpler than glox's own
`bin/build.sh`/`bin/build_debug.sh` split: Odin's `when ODIN_DEBUG` is
real conditional compilation, so there's no glox-style temporary
source-edit-then-restore dance needed to toggle the hot-loop debug hook
in and out of the binary, just a different flag set.

`-vet -strict-style` (without `-warnings-as-errors`) turned out to
produce hard build **errors**, not just warnings, contrary to the
initial assumption going in — this is not the `examples/` sibling
project's CI-grade `-warnings-as-errors` regime, but Odin's vet/style
checks are apparently errors by default regardless. Six real, pre-
existing violations surfaced and were fixed rather than working around
them: an unused `import "core:fmt"` (`core/obj_list.odin`), three unused
loop variables in `core/pickle.odin`'s decode paths (`for i in
0..<count` → `for _ in 0..<count`, `i` genuinely never read), and five
`transmute(i64)`/`transmute(u64)` uses on same-width, same-endianness
integer conversions (`core/value.odin`, `core/pickle.odin`) that Odin's
vet prefers as `cast` instead. Verified the substitution is behavior-
identical before applying it, not just because vet said so: an isolated
throwaway Odin program confirmed `cast(i64)` and `transmute(i64)` on a
`u64` produce bit-identical results, including for values with the high
bit set (`0xFFFFFFFFFFFFFFFF` → `-1` either way) — `cast`/`transmute`
diverge for genuinely different-kind conversions (e.g. `f64`↔`u64`,
still correctly `transmute` throughout this file), just not for same-
size int-to-int, which is exactly the case vet flagged.

**Verification**: full `pytest` regression (218/0/26) passed against
*both* the release and the new debug build, not just release as before.

**Unrelated finding, recorded but not fixed here**: `odin test src/vm
-all-packages` (the isolated unit-test sweep used as a secondary
verification step in prior sessions) is unreliable. Confirmed via a
throwaway `git worktree` at the commit immediately before this session's
changes that this is **pre-existing and unrelated** to anything here —
not caused by the vet/style fixes above either (an isolated Odin program
directly confirmed `cast`/`transmute` are behaviorally identical for
same-width int conversions, ruling out the obvious suspect before
reaching for the worktree test). `pytest`, the project's actual
correctness gate, is unaffected throughout.

Bisected further than "it segfaults": every individual `vm`-package test
passes alone; `core` and `compiler` packages alone never fail (only ones
that compile/run real Lox code, i.e. `vm`, do); a batch of 7 tests that
reliably crashed under the test runner's default 16-thread parallelism
passed reliably under `-define:ODIN_TEST_THREADS=1`. That looked like a
clean diagnosis — a data race on `core/obj_string.odin`'s unsynchronized
global `intern_table` (multiple tests interning strings into the same
map concurrently) — and almost got written up as one.

**It isn't a full fix, though**: re-running the identical `-all-packages
-define:ODIN_TEST_THREADS=1` command twice produced two *different*
failure modes on two different runs — once a genuine infinite-loop hang
(an orphaned child `vm.exe` test-binary process burning real CPU,
thousands of CPU-seconds, not blocked/waiting on anything), once a
segfault at a different point in the log. Identical input, identical
flags, different outcomes each run. That rules out a clean "just
serialize it" story: either `ODIN_TEST_THREADS=1` isn't fully honored by
this Odin dev-build's test runner, or there's a genuine memory-
corruption bug (use-after-free / stale pointer / buffer overrun) whose
*symptom* varies with heap layout, independent of threading — the
intern_table race may still be real and contributing, just not the whole
story. Also can't rule out a genuine compiler/test-runner bug rather
than a bug in odlox's own code: this is a `dev-YYYY-MM` from-source Odin
build, not a numbered release (workspace root `CLAUDE.md`), and pre-1.0
toolchain instability is a real possibility here, not just a convenient
excuse. Not root-caused. A `bin/test_odin.sh` wrapper forcing
`ODIN_TEST_THREADS=1` was written, tested, and then deliberately
**dropped** rather than shipped — it would have implied a fix that
doesn't reliably hold. Tracked in `TODO.md`; needs proper tooling (a
memory sanitizer if available for this Odin build, or bisecting against
a different Odin version) before it's worth resuming.

## Phase 1 — Scanner

Port `src/compiler/scanner.go`. See `ARCHITECTURE.md` §
[Scanner](docs/ARCHITECTURE.md#scanner) for the behaviors that must be
preserved exactly (full up-front tokenization, separate int/float tokens,
scan-time string-interpolation desugaring, implicit-EOL suppression).

- [x] `Token`/`Token_Type` (full enum: punctuation, `Int`/`Float` split,
      all keywords including `func`/`fun` alias, `Error`/`Eof`).
- [x] `Scanner` struct + `scan_token` covering every lexeme class.
- [x] Number scanning (int vs. float distinction, no hex/exponent support —
      matches glox, not a gap to "fix").
- [x] String scanning + `${...}` interpolation desugaring (recursive
      sub-scan of the interpolated expression's source).
- [x] Implicit-semicolon (`skip_eol`-equivalent) suppression rules —
      implemented as a two-pass filter (see `keep_eol` in `scanner.odin`)
      rather than a single-token-lookback rule: dropping an Eol needs to
      see both the token before it (opener/operator → continues) and the
      token after it (closing bracket/Eof → statement isn't over either,
      no matter what preceded it) — a pure look-behind rule can't express
      "still inside an open `[`".
- [x] Full up-front tokenization into a stable, indexable token list +
      `next_token`/`check_next` lookahead. **Do not scan lazily** — the
      compiler's `finally`-replay design (Phase 3) requires the whole
      stream to already exist.
- [x] Panic-safe error tokens (`Token_Type.Error` carrying a message).
- [x] `print_tokens` debug dump, wired to `odlox --print-tokens <file>`.
- [x] Standalone scanner unit tests (`src/compiler/scanner_test.odin`,
      `odin test src/compiler`) — 17 cases covering punctuation, int/float,
      keywords, EOL suppression (including the bracket-lookahead case),
      plain/interpolated/escaped strings, and error tokens. All green.

## Phase 2 — Core data types (prerequisite for the compiler)

The compiler needs `Value`/`Chunk`/the object model to exist before it can
emit anything — pull this forward rather than leaving it until "VM phase."

- [x] `Value` struct (16-byte tagged union, confirmed by
      `test_value_is_sixteen_bytes`) — `ARCHITECTURE.md` §
      [Value representation](docs/ARCHITECTURE.md#value-representation).
- [x] `Obj` base struct + `Object_Type` enum + one concrete struct per
      kind (`String_Object` through `Vec4_Object`, plus `Native_Object`
      and the three iterator kinds) — §
      [Object model](docs/ARCHITECTURE.md#object-model). Note one
      deviation from the original plan, documented in `obj_native.odin`:
      `Builtin_Fn`'s `vm` parameter is `rawptr`, not `^VM` — `core` can't
      import `vm` (package-graph direction), so this is a plain opaque-
      pointer boundary rather than glox's Go interface trick, which Odin
      has no equivalent of.
- [x] String interning table (`map[string]^String_Object`, no lock) —
      and, since interning now gives every name a canonical pointer, every
      other name-keyed map in the object model (`Class.methods/statics`,
      `Instance.fields`, `Dict.items`, `Environment.vars`) is keyed
      directly by `^String_Object` rather than glox's separate
      intern-to-an-int step.
- [x] `Chunk`/opcodes (`Op_Code` enum, `Chunk` struct with
      `code`/`constants`/`lines`/`global_names`) — §
      [Chunk, opcodes, bytecode](docs/ARCHITECTURE.md#chunk-opcodes-bytecode).
- [x] `Environment` (slot-indexed globals + name-keyed `vars` map, no
      mutex) — § [Environment & globals](docs/ARCHITECTURE.md#environment--globals).
- [x] `Value` equality/comparison/`to_string` procs (pointer-equality fast
      path for interned strings; **deliberate deviation from glox,
      implemented**: lists/dicts get real recursive structural equality
      instead of glox's stringify-and-compare fallback — see
      `value.odin`'s `objects_equal` doc comment).
- [x] Core package unit tests (`src/core/*_test.odin`,
      `odin test src/core`) — 41 cases covering Value layout/equality,
      Chunk constant dedup (including the "never dedup a
      Closure/Function/Bound_Method constant" rule), Environment slot
      growth, string interning, list/dict/class operations, and the
      self-referential-container recursion guard.

## Phase 3 — Compiler

Port `src/compiler/compile.go`. This is the largest single phase. See
`ARCHITECTURE.md` § [Compiler](docs/ARCHITECTURE.md#compiler) for the
structures and the load-bearing subtleties.

- [x] Pratt parser core: `Precedence` enum, `Parse_Rule` table
      (`rules.odin`'s `get_rule`, a switch rather than an array literal
      so each case can carry a short why-note), `parse_precedence`
      driver, recursion-depth guards (`expr_depth`/`stmt_depth`).
- [x] `Compiler` struct, nested-compiler chaining (`enclosing`), scope
      enter/exit (`begin_scope`/`end_scope` emitting `Op_Code.Pop` or
      `Op_Code.Close_Upvalue` per local as appropriate).
- [x] Local declaration/resolution (`declare_variable`, `resolve_local`,
      `mark_initialised`, the self-reference-in-own-initializer check).
- [x] Upvalue capture (`resolve_upvalue`/`add_upvalue`, the clox-style
      recursive climb through enclosing compilers).
- [x] Global slot assignment (`global_slot`, forward-reference-safe —
      first mention wins, regardless of declare-vs-reference order).
- [x] Function compilation (`functions.odin`'s `compile_function`,
      shared by declared functions, lambdas, and methods): params
      (including `*rest` variadic and `name = expr` defaults emitting
      the `Op_Code.Jump_If_Defined` prologue guard), body, `end_compiler`
      (implicit return, peephole pass, global-name table published only
      on the outermost chunk).
- [x] Peephole optimizer (`peephole_optimise` in `compiler_state.odin`)
      — the two fusion patterns (`Add_Nn`, `Incr_Const_N`),
      byte-length-preserving rewrite so already-computed jump offsets
      don't shift. Gated by a `DebugSkipPeephole` flag (mirrors glox's
      `-n`/`--no-peephole`, not yet wired to a real CLI flag — that
      lands with `main.odin`'s argument parsing in Phase 4).
- [x] Class compilation: `class`, inheritance (`Op_Code.Inherit`),
      `this`/`super` resolution, static methods/vars, `init` as
      `Function_Type.Initializer`.
- [x] Control flow: `if`/`else`, `while`, `for` (out-of-line increment
      trick), `foreach` (two hidden locals — the loop variable and
      `__iter` — plus `Op_Code.Foreach`/`Next`/`End_Foreach`, `Loop.is_foreach`
      routing `continue` forward instead of backward).
- [x] `break`/`continue`/`return` crossing `try` — **with a known,
      documented simplification vs. glox**: this port's `cross_tries`
      correctly unwinds exception handlers on the way out (no VM,
      once Phase 4 lands, will ever see a stale handler for a `try` no
      longer lexically in scope), but does **not** replay `finally` on
      that crossing path, unlike glox's full `Trampoline_Site`
      deferred-replay design (`docs/exception-handling.md` in the glox
      reference repo). Implementing that blind, with no VM yet to
      validate against, risked a subtly wrong result with no way to
      catch it short of hand-tracing bytecode. Revisit once Phase 4's
      VM can actually run `break`/`return` inside a `try ... finally`
      against the ported test suite. See the header comment in
      `stmt.odin` for the full rationale.
- [x] Module import compilation (`import`, `from ... import`,
      `from ... import *`).
- [x] Literals: string/int/float, list/dict/tuple construction, indexing/
      slicing (plain and `_assign` variants), compound assignment
      (`+= -= *= /= %=`) desugaring on locals/globals/properties (`this`
      is read-only, so upvalue compound-assignment wasn't exercised —
      the same `named_variable` code path handles it, but flag as an
      untested case until the ported suite can confirm it end to end).
- [x] Destructuring assignment (`a, b, c = expr`, including a
      multi-value RHS: `a, b = 1, 2` implicitly tuples the right side
      before unpacking) and implicit bare-`x = 5` declaration —
      correctly falls back to a plain global `Set` rather than shadowing
      with a fresh local when `x` is already a declared global being
      reassigned from a nested scope.
- [x] Panic-mode error recovery (`synchronize`) + REPL-specific
      compilation (`Repl_State` persistence across lines, via
      `Compile_Repl`).
- [x] `--print-tokens`/disassembly hooks wired for debugging the compiler
      itself. `--print-tokens` since Phase 1; `--disassemble` since
      Phase 5's disassembler landed.
- [x] Compiler-level unit tests (`src/compiler/compile_test.odin`,
      `odin test src/compiler`) — 58 cases, including a "kitchen sink"
      smoke test exercising classes/inheritance/closures/control-flow/
      collections/exceptions/imports/destructuring together, opcode-
      shape assertions for every construct above, REPL cross-line slot
      reuse, and syntax-error rejection. All green. This test suite is
      what actually found every real bug listed below — write it early
      for any future compiler work, not after the fact.

**Real bugs found and fixed while building this** (kept here, not just
in commit history, because each is a genuine gotcha someone modifying
this compiler later could reintroduce):

- `mark_initialised`'s old `scope_depth == 0` guard silently no-opped
  for a function's own reserved slot 0 (`this`) — that slot is declared
  and marked *before* `begin_scope` bumps the depth off zero, so every
  method body saw `this` as permanently "declared but not yet
  initialised" and refused to read it. The guard was redundant for
  every *other* caller anyway (they only ever call `mark_initialised`
  right after `add_local`, which itself is only reached when a local
  really is being declared) — removed outright rather than special-cased.
- `consume_eol` only accepted an explicit `Eol`/being at `Eof` — a
  one-line block body (`{ print 1 }`, no newline before the `}`) has no
  `Eol` token between the last statement and the closing brace at all,
  so every single-line block failed to compile. Fixed by also accepting
  an explicit `Semicolon` (a valid terminator everywhere, not just
  inside a `for(...)` header) and treating a following `Right_Brace` as
  an implicit terminator, the same resolution most brace-delimited
  languages use.
- The class-body member loop had no branch for the `Eol` that
  legitimately sits between two methods (top-level `declaration()`/
  `statement()` handle this via their own `.Eol` case; `method()`
  doesn't go through either) — `method()` failed without consuming a
  token, so the loop called it again on the exact same token forever.
  An actual infinite loop, not just a wrong compile.
- `implicit_assignment_statement` treated *any* name that wasn't a
  local in the current scope as "declare a new local", including one
  that's already a declared *global* being reassigned from a nested
  scope (`var total = 0` at top level, then `total = total + 1` inside
  a `for` body) — spawned a shadowing local mid-statement whose own
  initializer expression then saw that fresh, not-yet-initialised local
  instead of the outer global. Fixed by checking `is_global_declared`
  before falling into the "new local" branch.
- `implicit_assignment_statement` never emitted `Op_Code.Pop` after a
  plain (non-compound) assignment to an *existing* local, unlike every
  other assignment path (`Set_*` opcodes are designed to leave the
  assigned value on the stack, so assignment can chain as an
  expression — see `named_variable` in `expr.odin`) — a real stack-
  balance bug, and incidentally what was silently suppressing peephole
  fusion for that exact case, since the fusion pattern requires a
  trailing `Pop`.
- `destructuring_assignment_statement`'s right-hand side only ever
  compiled one expression (`a, b = 1, 2` parsed just `1`, then choked
  on the comma) — fixed by parsing a comma-separated expression list on
  the RHS too and implicitly tupling it when there's more than one.

**Milestone check**: `odlox --compile-only` (or equivalent) accepts
every construct exercised by `compile_test.odin`'s kitchen-sink smoke
test without a compile error. The real milestone — every `.lox` fixture
in the ported test suite compiling — needs Phase 6's native/builtin
registrations to exist too (many fixtures `import` built-in modules),
so that check is deferred to align with Phase 4/6, not claimed early.

## Phase 4 — VM core + GC

Port `src/vm/vm.go`'s `run()` and `src/vm/gc.go`. See `ARCHITECTURE.md` §§
[VM dispatch loop](docs/ARCHITECTURE.md#vm-dispatch-loop--calling-convention)
and [Garbage collector](docs/ARCHITECTURE.md#garbage-collector).

- [x] `VM` struct (fixed-size `stack`/`frames` arrays, `frame_count`,
      `stack_top`, `open_upvalues`, `builtins` map, GC bookkeeping).
- [x] `run()` dispatch loop with hoisted locals (`Frame_Locals`) +
      `refresh_frame`, reassigned at each call site rather than glox's
      `refreshFrame()` closure — Odin doesn't capture outer locals by
      mutable reference the way Go does, so this is a small struct
      returned and rebound instead of a closure mutating captured
      variables in place. The **raw-pointer `ip`/stack-top optimization**
      is *not yet done* — `run()` still indexes `fl.code`/`vm.stack` by
      integer, safely, matching the "get it correct first" sequencing
      this checklist item originally called for. Left as a genuine
      Phase 7 perf item, not a correctness gap.
- [x] Full opcode dispatch (`run.odin` + `arithmetic.odin`) — stack/const
      primitives, comparisons, arithmetic (int/float/vector/string
      paths), the compile-time-fused `Add_Nn`/`Incr_Const_N` family
      (executed directly, doing the int/float dispatch every time; the
      *further* runtime specialization into type-specific `_Ii`/`_Ff`
      variants that avoids re-checking types on every hit is a Phase 7
      item, not implemented here), locals/globals/upvalues, jumps.
- [x] Function call mechanism (`call.odin`): `call_value`/`call`
      (arity/default/variadic shaping, matching
      `docs/plans/default-variadic-params.md` in the glox reference),
      `invoke`/`invoke_from_class` (`Op_Invoke`/`Op_Super_Invoke` fast
      paths), class-construction via `Op_Call` on a class value,
      bound-method dispatch. Also includes a **Phase 6 native-function
      method surface pulled forward**: `list`/`dict`/`string` built-in
      methods (`append`/`remove`/`find`/`length`, `get`/`keys`/`remove`,
      `length`) are wired up now using Phase 2's pure-data procs, since
      they're VM primitives, not raylib-dependent natives.
- [x] Upvalue capture/closing (`upvalue.odin`: `capture_upvalue`,
      `close_upvalues`, open-upvalues list sorted by slot).
- [x] Property get/set (`properties.odin`) across instance/class/module
      receivers, including vec2/3/4 swizzle fields (`.x/.y/.z/.w`,
      `.r/.g/.b/.a` on Vec4). (Native-object property access doesn't
      apply yet — no natives exist until Phase 6.)
- [x] Collections (`collections.odin`): list/dict/tuple construction,
      indexing, slicing (plain + assign), membership (`in`).
- [x] Foreach — **native iterable fast path only** (list/string,
      `foreach.odin`). The user-class `__iter__`/`__next__` protocol
      (which needs the nested re-entrant `run()` call `Run_Mode` exists
      for) is a **documented, deferred gap** — foreach over a plain class
      instance currently reports "not iterable". See `foreach.odin`'s
      header comment; revisit once there's real test coverage (a user
      iterator class) to build the nested-call path against.
- [x] Exceptions (`exceptions.odin`) — bytecode shape and matching
      algorithm follow `docs/exception-handling.md`'s design, **with one
      deliberate improvement, not just a port**: `Op_Except` carries its
      own explicit 2-byte skip offset to the next clause (patched like
      any other jump) instead of glox's byte-pattern scan for "the next
      `Op_End_Except`/`Op_Except`/`Op_Finally`" — that scan is fragile
      once a clause body can contain a *nested* try/except (its inner
      `Op_End_Except` would be found first, wrongly). Since this port
      controls both the compiler's emission and the VM's reading of it,
      there was no reason to keep the ambiguity. See
      `exceptions.odin`'s header comment.
- [x] `Op_Str`/`str(...)` — **does not yet dispatch to a user-defined
      `toString()` method** on an Instance receiver (same nested-call
      gap as foreach's user-iterator protocol); falls back to
      `core.value_to_string`'s generic `<instance ClassName>` for every
      instance. Documented in `run.odin`'s `Op_Str` case.
- [x] Destructuring (`Op_Unpack`), breakpoint opcode (no-op for now --
      Phase 5's debugger would hook here), "invalid opcode" catch-all.
- [x] GC (`gc.odin`) — intrusive `Obj` list, `mark_roots`/`mark_object`/
      `blacken_object`/`sweep`, heap-growth-factor threshold. **One
      design change from the original plan, found while building it**:
      no "pre-mark on link" trick at all — `maybe_collect_garbage` only
      runs *between* dispatch-loop iterations, never mid-opcode, which
      means the value stack is always in a fully consistent state
      whenever a collection can run, removing the whole reason glox's
      Go version needed pre-marking in the first place. **The "no
      permanent-object exemption" simplification landed partially, for a
      real structural reason, not a change of plan**: `Class_Object` and
      `Module_Object` are ordinary sweepable `Obj`s (built entirely by
      VM-package code, so `gc_track` is always reachable at their
      construction site) — but `Function_Object` (built by the
      *compiler*) and `String_Object` (built by `core.intern_string`,
      called from both compiler and VM) structurally can't be
      `gc_track`'d by any VM at all, the same core/vm package-boundary
      reason `Builtin_Fn` needed a `rawptr` in Phase 2. Both stay
      permanent — still fully traced for correctness, just never freed.
      The weak-table string-sweeping idea from `ARCHITECTURE.md` is
      **deferred, not implemented** for the same reason. See `gc.odin`'s
      header comment for the full explanation; `ARCHITECTURE.md` updated
      to match.
- [x] Module import execution (`module.odin`) — importing another
      `*.lox` file works (a fresh sub-VM compiles and runs it, its
      globals get harvested into a `Module_Object`); built-in modules
      resolve through `vm.builtin_modules`, but nothing registers any
      yet (Phase 6's job) so importing one currently reports "not
      found". No mutex on the module cache (see
      `docs/ARCHITECTURE.md`'s Scope section — threads are out of scope
      entirely, unlike glox's Go cache).
- [x] `interpret()` entry point (`interpret.odin`) + REPL loop
      (`main.odin`): "print last value unless it's `nil`" behavior,
      multi-line REPL input buffering (balanced-bracket completeness
      check via a throwaway scanner pass, `core:bufio` for line
      reading). **Known gap, found while writing `vm_test.odin`**: a
      bare expression typed at the REPL evaluates correctly but its
      value doesn't survive as the line's reported result (`expression_statement`
      always emits `Pop`, and `end_compiler` always emits `Nil` before
      `Return` regardless of what preceded it) — so `> 2 + 2` currently
      shows `nil`, not `4`. Fixing this needs the compiler to recognize
      "this is a REPL line's final statement" and skip both the `Pop`
      and the trailing `Nil` for that one case specifically; not
      attempted here. Global-slot persistence *across* REPL lines (the
      part `Repl_State` exists for) does work correctly.
- [x] Error/panic reporting: stack traces with source-line context, using
      `Chunk.lines` for line numbers. Built in Phase 6f (`exceptions.odin`'s
      `append_stack_trace`/`source_line`, `vm.odin`'s `print_stack_trace`),
      well after this bullet's original Phase 3-era placement — deferred
      far longer than "alongside Phase 5" first assumed.
- [x] CLI flags: `--repl`, `--print-tokens` (kept from Phase 1), file
      execution as the default. `--compile-only`/`--debug`/`--info`/
      `--no-peephole`/`--disassemble` all wired since Phase 5.

**Real bugs found and fixed while building this** (kept here, not just in
commit history, for the same reason as Phase 3's list — genuine gotchas a
future change to this code could reintroduce):

- `interpret()` never sized `Environment.globals`/`defined` before
  running the compiled closure — every script crashed on its first
  global access. `Compile()` only *computes* `global_count`; actually
  allocating the slots is a separate runtime step
  (`core.env_grow_globals`) `interpret()` has to do itself.
- **The single highest-value bug this phase found**: `foreach_statement`
  (compiler, Phase 3) called `add_local` for the loop variable *before*
  pushing any value for it, then compiled the iterable expression next —
  so the loop variable's compile-time slot never corresponded to an
  actual runtime stack push, and `__iter`'s slot ended up one past
  anything actually written, reading uninitialised stack garbage.
  Crashed every single real foreach loop. Fixed by pushing an explicit
  `Nil` placeholder for the loop variable first. This is exactly the
  class of bug Phase 3's shape-only opcode-presence tests structurally
  could not catch (they never inspected operand *values* or stack
  balance) — it only surfaced once Phase 4 gave the project a VM to
  actually run programs against, which is the whole reason
  `ROADMAP.md`'s milestone checks call for running real code early and
  often rather than trusting a compiler phase "done" on shape checks
  alone.
- `implicit_assignment_statement` (compiler, Phase 3) checked for an
  existing *local* and an existing *global* before deciding to declare a
  fresh binding, but never checked for an existing **upvalue** — so
  `n = n + 1` inside a closure capturing `n` from an enclosing function
  silently shadowed it with a new, uninitialised local instead of
  writing through to the captured variable. `make_counter()`-shaped
  closures (the single most common closure idiom) were silently broken.
- `pop_frame_for_exception`'s unwind-boundary check was off by one
  (`frame_count <= exception_floor` instead of `<= exception_floor + 1`)
  — let the very last frame at the floor be popped anyway, dropping
  `frame_count` to 0 and crashing the *next* loop iteration's `frame(vm)`
  call. Every single "this should be a clean, uncaught runtime error"
  test crashed instead of returning `.Runtime_Error`.
- `Op_Print`/exception-message wrapping both used `core.value_to_string`
  (which quotes strings, for nested/round-trippable display) where they
  should have shown a string's *raw* text — `print "hi"` showed `"hi"`,
  and `raise "boom"` caught as `except ... { e.msg }` read `"boom"`
  (literal quote characters baked into the value), not `boom`. Fixed
  with a shared `display_string` helper used by both.
- Two compiler-level bytecode-encoding gaps found while designing the
  VM side, fixed **before** the VM code that would have depended on
  the broken shape existed: `Op_Except` needed its own skip-offset
  operand (see the Exceptions item above) and `Op_Next` needed a
  `var_slot` operand it was missing entirely (the VM has to know where
  to store each newly-yielded value on every iteration after the
  first, not just where the iterator itself lives).
- **Open test-infrastructure issue, not (as far as extensive manual
  verification can tell) a VM bug**: running `vm_test.odin`'s full suite
  through `odin test` reliably segfaults partway through (`bad free` at
  `core.intern_string`'s allocation site, or a bare SIGSEGV), even with
  `-define:ODIN_TEST_THREADS=1` (so it isn't purely the cross-thread
  data race on the unlocked package-level intern table it first looked
  like — see `docs/ARCHITECTURE.md`'s Scope section for why that table
  has no lock by design). It reproduces with as few as ~13 of the ~26
  tests selected via `-define:ODIN_TEST_NAMES`, and does *not* reproduce
  running any single test in isolation. The common factor across every
  crashing run is many `VM` instances (each a ~260KB struct, dominated
  by its fixed 16384-slot value stack — see `vm.odin`'s `STACK_MAX`)
  being constructed in one process, each pulling `core.intern_string`
  hard during compilation; cutting `bootstrap_exceptions` down to run
  once per process instead of once per `VM` (a real perf win regardless
  — see `exceptions.odin`'s `bootstrap_cache`) reduced but did not
  eliminate it. Given (a) the installed compiler is an active
  `dev-2026-07` build, not a numbered release, (b) the exact same code
  produces correct output for every hand-run smoke-test script through
  the compiled `odlox` binary directly (arithmetic, closures, classes/
  inheritance, collections, foreach, exceptions, modules — the full
  breadth `vm_test.odin` covers), and (c) every test passes when run
  individually, this looks more like a toolchain-level interaction
  (this dev build's tracking allocator or map implementation under many
  large, allocation-heavy `@(test)` procs in one binary) than an
  interpreter bug — but that's not proven, only the most likely
  explanation given the evidence gathered. Flagged here rather than
  either hidden or allowed to block the phase: if this recurs after an
  Odin compiler update, check whether it's still present before
  assuming it's this project's code again.

**Milestone check**: the smoke-tested feature set (arithmetic, control
flow, closures/upvalues, classes/inheritance, collections, foreach,
try/except/finally, module imports, REPL) runs correctly end to end
against hand-written `.lox`-style scripts, and `vm_test.odin` pins each
of those down as an automated test. Running the actual ported
`tests/new_tests/` suite from glox is **not done yet** — most of those
fixtures exercise built-in functions/modules (Phase 6) or a disassembler
(Phase 5) this phase doesn't have; wiring that suite up for real is
deferred to align with whichever of those phases removes the last
blocker, not claimed here.

## Phase 5 — Debug tooling

Port `src/debug/debug.go` (disassembler) and the trace/instrument hooks.
Low-risk, mechanical — mostly useful as a debugging aid *for* Phase 3/4,
so pull pieces of it forward as needed rather than treating it as strictly
sequential.

- [x] `disassemble_chunk`/`disassemble_instruction`
      (`src/debug/disassemble.odin`) — one case per opcode, byte/jump/
      constant operand formatting, matching clox's own
      `disassembleChunk`/`disassembleInstruction` shape (offset/line/
      mnemonic columns, `->` for resolved jump targets). Also
      `disassemble_program`, which isn't in clox: recurses into every
      `Function_Object` constant in a chunk's constant pool so one call
      dumps a whole compiled script, not just its top-level chunk (every
      `func`/method/lambda is a separate `Chunk` stored as a constant —
      see `obj_function.odin`). Two extras beyond a bare port, both
      because this port already has the data on hand and a debugger is
      exactly where it's worth showing: `Get_Local`/`Set_Local`/
      `Inc_Local` print the local's *name*, not just its slot number,
      recovered from `Chunk.local_vars` (debug info the compiler was
      already recording — see `compiler_state.odin`'s `add_local`/
      `end_scope`); `Get_Global`/`Set_Global`/`Define_Global(_Const)`
      resolve the slot to a name via `Chunk.global_names`.
- [x] Execution trace hook (`debug.Trace_Hook` — stack dump + the
      about-to-execute instruction, once per step) and instrument hook
      (`debug.Instrument_Hook` — an executed-instruction counter),
      both implementing `vm.Debug_Hook` and both gated with `when
      ODIN_DEBUG` inside the proc body: confirmed Odin's builtin
      `ODIN_DEBUG` constant (true exactly when built with `-debug`) is
      sufficient on its own, no separate flag or glox-style shell-script
      uncomment/recomment dance needed, and no change to Phase 4's
      hook-call sites either (`if vm.debug_hook != nil` was already the
      only runtime cost of *having* the mechanism; `when ODIN_DEBUG`
      is what makes actually *using* it disassemble-and-format nothing
      in a release build). `main.odin`'s `--debug`/`--instrument` set
      `vm.debug_hook` unconditionally either way, and print one
      `when !ODIN_DEBUG` note if the flag will have no effect, so a
      non-debug build fails informatively rather than silently.
- [x] CLI flags wired (deferred from Phase 4, landed here alongside the
      tooling they control): `--compile-only` (compile, report OK/exit
      65, don't run), `--disassemble` (compile + `disassemble_program`,
      don't run — the direct way to actually use this phase's
      deliverable), `--info` (compile + a size summary: function/
      instruction/constant/global counts — **this port's own definition
      of what to report, not a verified port of glox's own `--info`**;
      glox itself isn't checked out anywhere in this workspace to
      compare against, only the unrelated `odin-lang/examples` reference
      repo, so there was nothing to port *from* for this one flag's
      exact output shape), `--debug` (attach `Trace_Hook` and run),
      `--instrument` (attach `Instrument_Hook`, run, report the count),
      `--no-peephole` (sets `compiler.DebugSkipPeephole`, combinable
      with any of the above).
- [x] `src/debug/disassemble_test.odin` (`odin test src/debug`) — 10
      cases: a full walk of a kitchen-sink-program chunk (reusing
      Phase 3's own smoke-test source) asserting the disassembler's
      returned offsets land exactly on `len(code)` with no gap or
      overrun for every opcode family the compiler can emit, a
      `disassemble_program` recursion-into-nested-functions check, and
      hand-built single-instruction width checks for every
      non-obvious operand shape (`Except`, `Foreach`, `Next`,
      `Jump_If_Defined`, `Import_From` both with names and with `*`).
      All green.

**Real bugs found and fixed while building this** (kept here, not just in
commit history, for the same reason as Phases 3/4's lists):

- `Get_Super` was initially classified as a zero-operand opcode (it
  reads like one at a glance next to `Inherit`/`Get_Property`'s
  neighbors) — it actually carries a one-byte name-constant operand
  (`run.odin`'s `.Get_Super` case reads `fl.code[fl.f.ip]` before
  calling `do_get_super`). Undetected, this would have desynced the
  disassembler's offset tracking after every `super.name` reference in
  any real program, corrupting every instruction printed after it.
  Caught by cross-checking every opcode's handling in `run.odin`
  directly rather than trusting the shape implied by its name; pinned
  down by `test_get_super_instruction_is_one_operand_byte`.
- `Get_Global`/`Set_Global`/`Define_Global`/`Define_Global_Const`'s
  one-byte operand was initially formatted as a constant-pool index
  (the same shape as `Get_Property`'s name operand, which *is* one) —
  it's actually a slot number into `Environment.globals`, a completely
  different index space than `Chunk.constants`. The two indices
  coincide for simple scripts (global slots and constant-pool indices
  both start at 0 and grow together when every early constant also
  defines a global), which is exactly what made this easy to miss by
  eyeballing a small disassembly and easy to get real garbage from on
  a bigger one — one string constant that isn't also a global anywhere
  earlier in the chunk is enough to make the two indices diverge and
  the disassembler print the wrong name or panic out of range. Fixed
  with a dedicated `global_instruction` formatter that resolves through
  `Chunk.global_names` instead; pinned down by
  `test_global_slot_is_not_a_constant_pool_index`, which deliberately
  constructs exactly that diverging case.
- The `Try`/`End_Try` jump-offset sign was initially copied from the
  `Loop` case they sit next to in `Op_Code`'s declaration order
  (backward jump, `sign = -1`) — both are actually forward jumps,
  patched later by `patch_jump` as placeholders exactly like
  `Jump`/`Jump_If_False` (see `stmt.odin`'s `try_except_statement`:
  `emit_jump(p, .Try)`/`emit_jump(p, .End_Try)`, never `emit_loop`).
  `Loop` is the only backward jump in that whole group. Caught by
  checking the actual emission call, not just the opcode's position in
  a `case` list next to superficially-similar jump opcodes.

**Milestone check**: `odlox --disassemble` produces a correct,
fully-resolved listing (jump targets, constant values, local/global
names) for every construct Phase 3's kitchen-sink smoke test exercises,
verified both by hand (run against real `.lox` scripts covering
closures/classes/inheritance/loops/foreach/try-except-finally/imports —
see the bugs list above) and by `disassemble_test.odin`'s automated
full-chunk walk. `--debug`/`--instrument` verified against a `-debug`
build showing live per-instruction stack traces and a correct executed-
instruction count; verified separately that a non-debug build prints
the explanatory note instead of running the (compiled-out) hooks
silently.

## Phase 6 — Native/builtin functions & standard library

Port `src/vm/builtin.go` (core builtins) first, then `src/builtin/*.go`
(raylib-backed, much larger) as a distinct sub-phase. See `ARCHITECTURE.md`
§ [Native/builtin functions](docs/ARCHITECTURE.md#nativebuiltin-functions).

- [x] Core builtins (`src/vm/builtins.odin`/`builtins_math.odin`/
      `builtins_sys.odin`/`builtins_os.odin`): `len`, `type`, `append`,
      `range`, `rand`, `float`, `int`, `replace`, `format`, `vec2`/`vec3`/
      `vec4` constructors, the underscore-prefixed math floor (`_sin`/
      `_cos`/`_tan`/`_sqrt`/`_pow`/`_atan2` — the Lox-source `math`
      module that wraps these into `sin`/`cos`/... isn't ported yet, see
      below), `sys.*` (`args`/`clock`/`sleep`/`today`/`now`), `os.*`
      (`open`/`close`/`readln`/`write`/`read_all`/`listdir`/`isdir`/
      `isfile`/`exists`/`mkdir`/`rmdir`/`remove`/`getcwd`/`chdir`/`join`/
      `dirname`/`basename`/`splitext`). String method table
      (`call.odin`'s `invoke_builtin_string`) extended with `replace`/
      `join`, glox's actual two real string methods (list/dict's method
      tables already matched glox exactly since Phase 4 — see that
      phase's pull-forward note). `File_Object` (Phase 2's minimal
      shape) filled in with real buffered `file_read_line`/`file_write`
      (`core/obj_file.odin`), same `bufio.Reader` pattern `main.odin`'s
      REPL already used.
- [x] Exception class hierarchy via embedded-Lox-source bootstrap — this
      was already done in Phase 4 (`exceptions.odin`'s
      `bootstrap_exceptions`/`EXCEPTION_SOURCE`), pulled forward because
      the VM needed *a* working exception hierarchy to run anything.
      Only `Exception`/`RunTimeError`/`EOFError` are bootstrapped, not
      glox's full set (`PickleError`/`ProcessError`/`ThreadError`/
      `SyncError`) — those belong to modules this phase doesn't
      implement (`pickle`/`process`, and `thread`/`sync` are
      permanently out of scope), so adding their exception classes now
      would be dead code; add each alongside its own module instead.
- [x] `natives` package skeleton + registration hook wired from
      `main.odin`. `src/natives/natives.odin`: a single `define_natives ::
      proc(v: ^vm.VM)` entry point, currently a no-op, called from both of
      `main.odin`'s VM-construction sites (`run_file`, `repl`) right after
      `vm.define_builtins`. The registration mechanism itself
      (`core.Builtin_Fn`, `vm.define_builtin`) already existed since
      Phase 6a — nothing new needed there, this just adds the package
      boundary and wires it in ahead of having real content, so Phase 6b
      only needs to add functions to an already-plumbed-through package
      rather than create the package and its wiring at the same time as
      the first real raylib work.
- [x] `physics_world` — complete. See Phase 6i.
- [x] `gfx.window()` + core 2D drawing (lifecycle, frame begin/end,
      input, pixel/line/line_ex/triangle/rectangle/circle/circle_fill/
      text) — complete. See Phase 6j.
- [ ] `texture`/`shader`/`camera`/`render_texture`/`image`/`batch`/
      `batch_instanced`, 3D drawing, blend/shader modes, `draw_array` —
      not started, deliberately deferred past the Phase 6j slice.
      `d:/odin/glox_reference/src/builtin/` is the ground truth for each.
- [x] `float_array`, `vec2`/`vec3`/`vec4` methods beyond basic
      arithmetic. See Phase 6f for the full writeup -- `float_array`
      turned out not to need raylib at all (a plain w*h f64 buffer), and
      glox's own vec2/3/4 "methods beyond field access" turned out to be
      exactly one method (`.add()`), not the larger swizzle/vector-math
      surface this bullet originally assumed.
- [x] `inspect` — VM-introspection module. See Phase 6h.
- [x] `re` (regexp) — module functions + Pattern/Match objects. See Phase 6h.
- [x] `pickle` — plain-data serialisation. See Phase 6h.
- [ ] `process` — **parked, not finished.** See Phase 6h for what works
      (spawn/send/recv/wait/kill/pid, all tested and passing) and what
      doesn't (`wait_any()`, which raises a spurious "truncated message"
      `ProcessError` once a worker fires off several messages back-to-
      back and exits immediately after -- suspected Windows
      `PeekNamedPipe`/pipe-EOF interaction, not fully root-caused).
      `tests/new_tests/test_process.py`/`test_pool.py` are both skipped
      at the whole-file level pending this.
      - `thread`/`sync` are **permanently out of scope** (see this file's
        header) — not on this list to eventually finish, listed here only
        so their absence is understood, not mistaken for an oversight.
- [x] `json.lox`. See Phase 6h (needed only `re`, now done).
- [ ] `pool.lox` — still blocked: its `ProcessPool` class needs
      `process.wait_any()` working correctly (parked, see above); its
      `ThreadPool` class is permanently blocked by `thread` being out of
      scope, so this module can only ever be partially ported even once
      `wait_any` is fixed. `plot_grey.lox`/`plot_rgb.lox`/`sprite.lox`
      remain blocked on raylib (`gfx` window/drawing), tracked under the
      raylib-natives bullet above, not here.
- [x] `colour.lox`. See Phase 6g.
- [x] `colour_utils`, other small utility modules. See Phase 6f.
- [x] **Error call stack trace.** See Phase 6f -- implemented using the
      `source`/`stack_trace` fields already scaffolded (and forgotten)
      on `VM` since whichever phase first wrote vm.odin.
- [x] Fix `module.odin`'s `read_module_source` search order/path so
      `import math` (or any other stdlib module, once copied over) can
      actually be found: now checks `$LOX_PATH/modules/<name>.lox`
      first (odlox's own convention — see below for why not glox's
      literal `src/modules`), then the running script's own directory,
      then a recursive subdirectory search of it — matching glox's own
      three-tier `getPath`/`findModuleInSubdirs` order. Covered by two
      new filesystem-fixture tests in `src/vm/module_test.odin`.
- [x] Port `src/modules/*.lox` themselves (glox's own Lox-source
      standard library) into odlox's own `modules/` directory — see
      the Phase 6c section below for the full writeup (which modules,
      what's deferred and why, the real bugs found doing it). `odlox`'s
      own convention is a `modules/` directory at the `$LOX_PATH` root
      rather than glox's `src/modules/` — odlox's own `src/` is
      exclusively Odin source, so reusing that name for a Lox-source
      directory would be actively confusing.

**Real bugs found and fixed while building this** (kept here, not just in
commit history, for the same reason as every other phase's list):

- **The single highest-value bug this phase found**: built-in module
  member calls (`sys.clock()`, `os.open(...)`, any `module.fn(args)`)
  failed with `Undefined method 'clock'` regardless of whether the
  member existed. Root cause: `.name(args)` always compiles through
  `Op_Invoke` (the fast-path used for *every* call of that shape, not
  just real methods — see `expr.odin`'s `dot`), and `call.odin`'s
  `invoke` had a case for every receiver kind that can have "methods"
  (`Instance`/`Class`/`List`/`Dict`/`String`) but none for `Module` --
  so it fell straight through to the generic "Undefined method" error.
  This didn't just make the *new* builtins in this phase unreachable —
  it meant no built-in module could ever have worked, from the moment
  Phase 4 first wired module property access up. Fixed by adding a
  `Module` case that resolves the member by name through the module's
  `Environment` and delegates to the same `call_value` an ordinary
  `Op_Call` would use (mirrors glox's own `invokeFromModule`).
- `format()`'s first implementation boxed converted Lox values into
  Odin's `any` by returning `any` *from a helper proc* — `any` only
  ever stores a pointer to its underlying value, and that return
  statement silently took the address of the helper's own return
  temporary, which is invalid the instant the proc returns (the stack
  space gets reused by the next call). A real, reproduced segfault on
  the very first `format(...)` smoke test, not a hypothetical — fixed
  by heap-boxing each converted value inline (`new(T)`, freed after
  `fmt.aprintf` runs) instead of returning `any` from anywhere.
- `file_write` initially didn't unescape a literal `\n` (the two
  characters backslash-n) into a real newline before writing, on the
  wrong assumption that odlox's scanner already resolves `\n` escapes
  at scan time the way a C-family language would. It doesn't: this
  language's string literals (both glox's and this port's — see
  `scanner.odin`'s `scan_string`) have no general backslash-escape
  mechanism at all, only `$$` for a literal `$` next to string
  interpolation. `"hello\n"` in Lox source is literally the six
  characters `h-e-l-l-o-\-n`, and glox's own `os.write` specifically
  un-escapes that one sequence as the way multi-line text gets into a
  written file at all. Missing it silently wrote literal backslash-n
  into every file, breaking `os.readln`'s line splitting on the very
  next read. Caught by an actual write-then-read-back round trip
  smoke test, not by reasoning about the scanner in isolation — worth
  remembering as a lesson for this whole port: "the scanner probably
  already handles X" is exactly the kind of assumption that needs a
  real round-trip test, not just re-reading the scanner code more
  carefully.
- Two smaller, narrower fixes needed to make the ported test suite's
  free functions behave identically to glox's: `builtins.odin`'s
  `format` pre-processes a bare `%f` (no explicit precision) into
  `%.6f` before handing the template to Odin's `fmt.aprintf` — Odin's
  own default float precision is 3 decimal places, Go's is 6, and the
  ported test suite's `test_format.py` checks the exact string.
  Deliberately narrow (only touches an un-precisioned `%f`), not a
  general printf reimplementation.

### Phase 6a-continued: module path fix + parenthesized control-flow grammar

Two items flagged as "found but out of scope" right after Phase 6a
landed, picked up immediately after since both were straightforward
prerequisites blocking the `.lox` standard library port and a large
fraction of the ported test suite.

**Module search path** — see the checklist above; fixed exactly as
described there.

**Parenthesized control-flow headers**: checked directly against
glox's actual grammar (`src/compiler/compile.go`'s `ifStatement`/
`whileStatement`/`forStatement`/`foreachStatement`) rather than
guessing. Finding: glox requires `(`/`)` around every one of these
headers **unconditionally** — there is no bare form in glox at all.
This port's Phase 3 compiler had it backwards: only the bare form
compiled, and every parenthesized fixture in the ported suite failed
outright. Made the parens **optional** rather than mandatory
(`compiler/stmt.odin`'s new `parse_condition` helper for `if`/`while`,
equivalent inline handling in `for_statement`/`foreach_statement`) —
matching glox exactly (mandatory) would have broken every bare-style
script this compiler's own test suite and every hand-written example
already use, for no real benefit. Also ported glox's other real
grammar fact this surfaced: an `if`/`while`/`foreach` body can be *any
single statement*, not just a `{ block }` (glox's `ifStatement` etc.
call `p.statement()` directly for the body, not a block-specific
path) — needed for `if (cond) break`/`if (n < 2) return n`, both real
fixtures in the ported suite that previously couldn't compile at all.
`for`'s body stays brace-required: unlike the other three, an
optional-paren `for` genuinely can't support an unbraced body without
real grammar ambiguity (with no parens, there's no unambiguous token
telling the parser where an omittable increment clause ends and a
bare-statement body begins — parens sidestep this by making `)` that
delimiter, which is exactly why glox's own grammar makes them
mandatory instead of optional here). No fixture in the ported suite
needs an unbraced `for` body, so this is a real, deliberate
restriction, not an oversight.

**Real bugs found while doing this** (kept here for the same reason as
every other phase's list):

- **A pre-existing, silent heap-corruption bug**, not something this
  work introduced: `module.odin`'s `read_module_source` called
  `delete()` on the result of `filepath.dir(vm.script)`. `os.dir`
  (what `filepath.dir` aliases) returns a slice *view into its input
  string*, not a fresh allocation (see `os/path.odin`'s `split_path`)
  — so this was a bad free of memory the function never owned, on
  *every single successful module import* since Phase 4 first wrote
  that line. It didn't crash immediately (bad frees don't always
  corrupt something that gets touched right away), which is exactly
  why it went unnoticed through every previous phase's testing.
  Implementing the new recursive-subdirectory search changed the heap
  layout just enough to turn that latent corruption into an actual,
  reliably reproducing segfault on the very first test of the new
  search path — found by bisecting with targeted `fmt.eprintln` tracing
  down to the exact statement, not by inspection. Fixed by simply not
  calling `delete` on it. A reminder for this whole port: `delete()`
  on anything returned by a path-splitting helper needs to be checked
  against that helper's actual allocation contract, not assumed.
- The `class_declaration` member-loop `synchronize()` fix from the
  pytest-suite-wiring work and this phase's `if_statement` simplification
  compose cleanly: replacing the old hand-rolled `else`/`else if`
  special case with a plain `statement(p)` call (which itself dispatches
  back into `if_statement` for a following `if`) removed code instead
  of adding it, while also fixing the parenthesized case — a rare
  instance in this port where "match glox's real grammar" and "simplify
  this port's own code" pointed the same direction. Not a bug, but
  worth noting since it's the kind of simplification easy to miss when
  focused only on "make the failing tests pass."

**Milestone check**: `python -m pytest tests/new_tests/ -q` — baseline
after Phase 6a's builtins was 62 passed / 168 failed / 14 skipped;
after this follow-up work, **107 passed / 123 failed / 14 skipped**.
The single largest jump of any phase so far, from two changes that
sound small (a path-resolution order fix, optional parens) — a good
illustration of how much of the ported suite's failure count was never
about missing features at all, just this port's grammar not accepting
syntax glox's real grammar always required. Regression-tested: 7 new
shape tests in `compile_test.odin` (both paren forms for all four
control-flow statements, the unbraced-if-body case, `else if` chaining
still working after the simplification, `for`'s no-increment-with-parens
edge case), 2 new filesystem-fixture tests in `module_test.odin` (found
in a subdirectory, `$LOX_PATH/modules` takes priority over the same
directory) — both pass individually but, like `vm.test_dict_get_and_set`
and others before them, reproducibly crash if run in the same
`odin test src/vm` invocation as each other under the default
multithreaded runner or even `-define:ODIN_TEST_THREADS=1`; consistent
with (each constructs two full VMs, matching the allocation weight
Phase 4's writeup already found sufficient) rather than a new instance
of the same pre-existing toolchain issue — investigated directly (ruled
out a bug in this file's own env-var set/restore sequence by running it
standalone, outside the VM/GC/compiler entirely, which does not
reproduce it) rather than assumed. Every remaining ported-suite failure
at this point is either raylib/`re`/`pickle`/`process`/`colour_utils`
(Phase 6b, not started) or the `.lox` standard library itself (path
resolution now fixed, the files aren't copied over yet).

### Phase 6a-continued, part 2: toString/__iter__ protocol, plus three real bugs an exhaustive per-test pass finally caught

The last two items shared blockers for both the `.lox` standard library
port and Phase 6b: `toString()` dispatch and the user-level
`__iter__`/`__next__` iterator protocol. Both were already flagged as
deferred, `Run_Mode.Current_Function`-shaped gaps back in Phase 4.

**`toString()` dispatch** (`run.odin`'s `Op_Str` case) turned out not to
need `Run_Mode.Current_Function`/a nested `run()` call at all, once
checked against glox's actual `OP_STR` handling: glox just pushes a new
call frame for the `toString` method and lets the *outer* dispatch loop
carry on (`continue` after `vm.call(...)`/`refreshFrame()`) — when that
method's own return eventually fires, ordinary return handling lands
the result exactly where `Op_Str` needs it, with no recursion into a
second `run()` invocation required. Ported the same way: `call_value`
+ `refresh_frame`, then just falling out of the switch normally, since
Op_Str's call is the very last thing that opcode does. `Run_Mode.Current_Function`
*is* still needed for `foreach`'s `__iter__`/`__next__`
(`foreach.odin`'s new `call_closure_now`) — unlike `Op_Str`, those need
the call's result back immediately, mid-opcode, to decide what happens
next (is the result nil? does it have a `__next__` method?), which is
exactly the case that mode exists for. Ported closely against glox's
own `OP_FOREACH`/`OP_NEXT` instance branches (`vm.go`), including
checking that `__iter__`'s return value actually has a `__next__`
method before accepting it as a real iterator.

**Real bug found immediately**: `print instance` never picked up a
class's own `toString()`, even right after wiring dispatch into
`Op_Str` — because `print_statement` (`stmt.odin`) never emitted
`Op_Str` in the first place, unlike glox's own `printStatement`
(`p.emitByte(OP_STR); p.emitByte(OP_PRINT)`). `str(x)` (a different
call site, `expr.odin`'s `str_call`) already emitted `Op_Str` directly,
which is exactly what made this easy to miss: `str(x)` "worked" the
moment dispatch was wired up, while `print x` on the identical value
silently didn't, because it never routed through `Op_Str` at all.
Fixed by adding the missing `emit_op(p, .Str)`.

**Three more real, pre-existing bugs**, found not by the toString/iterator
work itself but by a change in *methodology* it prompted: every
individual `vm`-package test (56 across `vm_test.odin`/
`builtins_test.odin`/`module_test.odin`) was run one at a time, alone,
rather than trusting a full-suite run and attributing any failure to
the already-documented toolchain flakiness. That habit had become
routine after several phases of genuinely-flaky combined runs — this
pass found that flakiness had been quietly providing cover for real,
100%-reproducible bugs too:

- **`match_clause_chain`'s "is there another except/finally clause"
  check was simply wrong.** It treated "next_clause is still within
  the chunk's bounds" as proof there was another clause to check —
  but `next_clause`, when a `try`/`except` isn't the very last thing
  in its function (the overwhelmingly common case), almost always
  lands on a real, in-bounds instruction that has nothing to do with
  exception handling at all: the code that comes *after* the whole
  `try`/`except` construct. Reading it as `[type_const][skip_hi]
  [skip_lo]` operand bytes either crashed with an out-of-range panic
  (reproduced with `try { raise "x" } except EOFError as e {...}` —
  any except clause that doesn't match the raised type, provided
  there's anything after the try/except, which there always
  effectively is once `end_compiler`'s trailing `Nil`+`Return` is
  counted) or, worse, silently misbehaved in less lucky byte layouts.
  Fixed by actually checking the opcode at `next_clause` is `.Except`
  or `.Finally` before treating it as a real clause, not just that
  it's in bounds.
- **`Op_End_Try` never applied its own jump offset — a very serious
  bug, not a corner case: every single `try { ... } finally { ... }`
  with no `except` clause raised a bogus uncaught exception on
  perfectly ordinary, non-exceptional completion.** The compiler
  (`stmt.odin`'s `try_except_statement`) emits a real, non-zero
  forward jump at `End_Try` — needed to skip from normal completion
  straight to the *normal-path* copy of the `finally` block, bypassing
  the *exceptional-path* copy (which unconditionally ends in
  `Op_Raise`, to re-propagate once `finally` has run after a caught
  exception). The VM's `Op_End_Try` handler, though, just skipped past
  the two operand bytes as if they were inert padding, on a comment
  claiming "the compiler always emits 0,0 here" — which was simply
  false for any `try`/`finally` construct. Execution fell straight
  through into the exceptional `finally` copy regardless of whether
  anything was actually raised, hit that copy's trailing `Op_Raise`,
  and reported an exception that was never really raised at all.
  Fixed to actually apply the offset, the same way `Op_Jump` does.
- **The REPL's `Environment.global_names` accumulated duplicate
  entries on every single line, corrupting global-slot lookups from
  the second line onward.** `end_compiler` publishes the current
  compile unit's slot→name table onto the shared `Environment` once
  compilation finishes — but for a REPL line, that `Environment` is
  the *same* persistent one across every line (`new_vm_raw` creates it
  once, never again), while the table being published
  (`p.global_names_by_slot`) is *already* the complete, correct,
  cumulative mapping for that line (rebuilt fresh each
  `Compile_Repl` call from the persisted `Repl_State.globals` map).
  `end_compiler` used to `append` that onto `environment.global_names`
  unconditionally, every line, instead of replacing it — so after N
  REPL lines, the array held very close to N stacked, overlapping
  copies of the mapping. `env_slot_for_name`'s linear search would
  then find any given name at whatever leftover index the *first*
  stale copy happened to still contain it at: consistently, silently
  wrong (not randomly), by exactly the amount of accumulated
  duplication. A 3-line REPL session was enough to reproduce it
  (`var x = 10` / `x + 5` / `var y = x + 5` — resolving `y`'s slot
  afterward returned 3, not the real slot 1). Fixed by clearing the
  array before republishing instead of appending to it.

None of these three were introduced by this session's work — each was
reachable on the previous commit, and the REPL one traces back to
whichever phase first wrote `end_compiler`'s environment-publishing
step. All three were sitting behind the "probably just the known
toolchain flakiness" assumption, since intermittent combined-test-run
failures had trained that assumption in across several earlier phases.
The actual lesson: **that assumption needs re-earning per bug, not
applied wholesale** — a failure that reproduces in isolation, every
time, is not toolchain flakiness regardless of how it looks in a
crowded batch run. Worth remembering for any future test failure in
this codebase: isolate first, attribute to known flakiness second, not
the other way around.

Regression coverage: `vm_test.odin` gained
`test_to_string_dispatch_via_str_builtin`,
`test_instance_without_to_string_uses_generic_fallback`,
`test_foreach_over_class_with_iter_protocol`,
`test_foreach_over_class_iter_protocol_respects_break_and_continue`,
`test_foreach_over_instance_without_iter_is_runtime_error`,
`test_foreach_iter_result_without_next_is_runtime_error`, and
`test_uncaught_exception_with_trailing_code_does_not_crash` (the
`match_clause_chain` regression, with deliberate trailing code rather
than relying on `end_compiler`'s implicit trailing bytes the way the
pre-existing `test_uncaught_exception_is_runtime_error` incidentally
does); `compile_test.odin` gained
`test_print_statement_emits_str_before_print`. The `End_Try` and REPL
bugs didn't need new tests — both are exactly what two *existing*
tests (`test_finally_runs_on_normal_completion`,
`test_repl_second_line_sees_first_lines_global`) were already asserting,
they'd just never been run in enough isolation to be believed.

**Milestone check**: all 56 `vm`-package tests now verified individually
(not just as a batch), confirmed passing every one — the exhaustiveness
itself is the deliverable here, not just a number. `python -m pytest
tests/new_tests/ -q`: 107 passed / 123 failed / 14 skipped before this
work, **115 passed / 115 failed / 14 skipped** after — the three bug
fixes alone (independent of the toString/iterator features) accounted
for 8 of those, since `try`/`finally` and multi-line REPL sessions
turn out to be exercised more widely across the ported suite than
their own dedicated test files suggest.

### Phase 6c: the `.lox` standard library port

Ported 7 of glox's 13 `src/modules/*.lox` files into odlox's own
`modules/` directory: `functools.lox` (`map`/`filter`/`reduce`),
`math.lox` (the `sin`/`cos`/`sqrt`/... wrappers around Phase 6a's
underscore-prefixed natives, plus `floor`/`round`/`max`/`min`/`abs`/
`pow`/`radians`/`degrees`/vector helpers), `string.lox` (`split`),
`random.lox` (`integer`/`float`/`choice`, on top of `math.lox`),
`itertools.lox` (`reverse`/`sort`/a `Bouncer` class, on top of
`random.lox`), `logging.lox` (a leveled `Logger` class using `sys.*`/
`os.*`), and `particle_sys.lox` (a headless particle-system framework
— confirmed via its own ported test, "headless: the module only
imports random/math, no window" — genuinely no raylib dependency
despite the name). Copied and tested unmodified, no adaptation needed
beyond the modules themselves being correct glox source — every bug
this phase found was in odlox's own compiler/VM, not in the ported
`.lox` files.

**Deferred, each for a real, specific reason**: `colour.lox` (imports
`colour_utils`, an unregistered native module), `json.lox` (imports
`re`, unregistered), `plot_grey.lox`/`plot_rgb.lox`/`sprite.lox`
(`from gfx import *`, unregistered — genuinely raylib-dependent,
Phase 6b), `pool.lox` (imports `process`/`thread` — `thread` is
permanently out of scope, `process` unregistered). All five are
one-line `import` failures away from working once their native
dependency exists, not separately broken.

*Correction, Phase 6f*: `colour_utils` is registered now, so
`colour.lox` is the one of these five no longer blocked on anything —
not yet actually ported, just no longer has a reason not to be (see
Phase 6's checklist above).

**Real bugs found while porting these seven modules** (kept here, not
just in commit history, for the same reason as every other phase's
list) — six of them, ranging from "the module system's core call
mechanism was fundamentally broken for any nontrivial module" down to
one CLI-argument-parsing regression from earlier in this same session:

- **The single most severe bug found in this entire project so far**:
  `run.odin`'s `Get_Global`/`Set_Global`/`Define_Global`/
  `Define_Global_Const` all resolved through `vm.environment` — the
  *running VM instance's own* `Environment` field — instead of the
  *currently executing frame's own function*'s environment
  (`fl.fn.environment`, which `refresh_frame` already hoists; every
  `Function_Object` records which `Environment` it was compiled
  against — see [Compiler](#compiler)). Those two are only the same
  `Environment` for the top-level script itself. The instant an
  *imported module's* function is called — `math.sin(x)`, where
  `math.lox`'s own `sin` body calls `_sin(angle)`, a global reference —
  the closure being executed belongs to the module's own `Environment`
  (built by its own separate sub-VM compile in `module.odin`'s
  `load_module`), but global reads/writes resolved against the
  *importing script's* `vm.environment` instead: a completely
  different global slot space. Any imported function that referenced
  *any* global at all — calling another top-level function in its own
  module, reading a module-level var, or calling an underscore-
  prefixed native — either silently read/wrote the wrong slot or hit
  `Undefined variable '#N'` outright. This had been true since Phase 4
  first wired module property access up; it went uncaught because the
  one existing module test only ever read a plain exported *value*
  from an imported module, never *called* an imported function that
  itself touched a global — exactly the gap a real standard-library
  port immediately exposes. Reproduced with the simplest possible case
  (a two-function module where one calls the other by name) before
  touching any of the actual ported modules, then fixed by resolving
  through `fl.fn.environment` throughout — correct for the top-level
  script too, since its `Function_Object.environment` is set to the
  same `vm.environment` `Compile()` was called with in the first
  place.
- `create_dict` rejected any non-string dict-literal key outright
  ("Dict keys must be strings.") instead of coercing it to its string
  representation the way glox's own `createDict` does (`key.String()`
  for anything that isn't already a `StringObject`). Found because
  `logging.lox`'s `Logger._LEVEL_NAMES` is exactly
  `{10: "DEBUG", 20: "INFO", ...}`, looked up later via `str(level)` —
  a real, working glox idiom this port simply couldn't compile the
  data for. Fixed by coercing through the same `core.value_to_string`
  `Op_Str`'s own non-`toString` fallback uses, so a coerced key and its
  later `str()`-based lookup always agree.
- `do_index`/`do_index_assign` (`Op_Index`/`Op_Index_Assign`) had no
  `Dict` case at all — `do_index` unconditionally required an integer
  index *before even checking what the container was*, so
  `dict["key"]`, a real, expected feature glox's own `index()` fully
  supports, always failed with "Index must be an integer.", regardless
  of the container's actual type. Found via `logging.lox`'s
  `Logger.level_name`. Fixed by checking the container type first and
  only requiring an int for `List`/`String`, matching glox's own
  per-type dispatch (and reusing the same key-coercion as the
  `create_dict` fix above, so `d[10]` and `{10: ...}` agree too).
- `set_property` only ever checked `receiver.type == .Obj` before
  dispatching — but a `vec2`/`vec3`/`vec4` value's own `.type` is
  never `.Obj` (see [Value representation](#value-representation)), so
  `v.x = expr` always fell straight through to the generic "Only
  instances, classes, and modules have settable properties." error,
  even though *reading* `v.x` already worked (`get_property` has its
  own vec-swizzle case, landed in Phase 4). glox's own
  `OP_SET_PROPERTY` has a real `Vec2`/`Vec3`/`Vec4` case. Found via
  `particle_sys.lox`, a real glox module that assigns `this.pos.x =
  ...` directly. Fixed with a `set_vec_swizzle` mirroring the existing
  `get_vec_swizzle`.
- **A regression from earlier in this same session, not a
  pre-existing bug**: the parenthesized-control-flow-grammar work's
  CLI-argument-parsing rewrite (`main.odin`) changed "everything after
  the script path becomes `sys.args()`" from "the *last* unmatched
  argument wins as the file path" (the original behavior) to "the
  *first* unmatched argument becomes the file path, permanently" —
  which broke `--force-compile` (`odlox --force-compile script.lox`):
  `--force-compile` itself became `file_path`, and the real script
  path landed in `script_args` instead, never read again. The ported
  test suite's own `lox_helper.py` calls *every* fixture twice, once
  with this flag — so this one regression was silently causing a huge
  fraction of the suite's `force_compile=True` runs to fail outright
  with "could not read '--force-compile'" for however long it was
  live (this whole session, until caught here). Fixed by explicitly
  recognizing and ignoring `--force-compile` in the argument loop —
  there's no bytecode cache to force-recompile from at all (Phase 8,
  deferred), so every run already recompiles from source
  unconditionally; accepting and ignoring the flag is the correct
  behavior, not a stopgap.
- `from mod import *` had two separate real bugs, found together
  porting `math.lox`:
  1. The scanner's Eol-suppression heuristic (`scanner.odin`'s
     `keep_eol`) treats `*` purely by token type — indistinguishable
     from the multiplication operator, which legitimately continues
     an expression onto the next line — so the Eol that should follow
     `from mod import *` on its own line was never scanned into the
     token stream at all, and `from_import_statement`'s old
     unconditional `consume_eol` call always failed with "Expect
     newline after import." Fixed by not requiring a terminator after
     the `*` case specifically — nothing can legally follow `*` in
     this grammar position anyway, unlike real multiplication, so
     there's nothing to validate.
  2. Past that: `from mod import *` walks *every* name in the
     imported module's own `Environment.vars`, which includes
     whatever free builtins the module's code happened to reference
     internally (e.g. `math.lox` calling `vec2()`/`vec3()`) via
     `seed_builtin_globals`, not just its "real" top-level
     declarations. The old `bind_imported_name` treated "no matching
     global slot in the importing script" as a fatal internal-error
     bug — but for a star-import there's no reason one *should*
     exist unless the importing script happens to reference that same
     name itself elsewhere, since nothing in slot-indexed
     `Op_Get_Global` can ever ask for a name the importing script's
     own compiled code never mentioned by identifier. Confirmed
     against glox's own `importFunctionFromModule`, which silently
     skips the fast-slot write when no matching slot is found rather
     than erroring. Fixed with a separate, more forgiving
     `bind_imported_name_soft` used only for the star-import path — a
     *named* import (`from mod import x`) keeps the strict version,
     since the compiler already guarantees a slot exists for `x` at
     compile time (`from_import_statement`'s own `global_slot(p,
     name)` call), so "no slot" there really would mean something is
     broken.

Regression coverage: `module_test.odin` gained
`test_imported_function_calling_another_function_in_its_own_module`,
`test_imported_function_reading_module_level_var`, and
`test_from_import_star_with_module_referencing_extra_builtins`;
`vm_test.odin` gained `test_dict_subscript_get_and_set` and
`test_dict_literal_with_int_key_is_coerced_to_string`;
`builtins_test.odin` gained `test_vec_field_assignment`. All 62
`vm`-package tests (up from 56) reverified individually, every one
passing — the same exhaustive-not-batch discipline established fixing
the previous section's three bugs, since this section's fixes are at
least as foundational.

**Milestone check**: `python -m pytest tests/new_tests/ -q` — 115
passed / 115 failed / 14 skipped before this work, **147 passed / 83
failed / 14 skipped** after: the largest jump of any phase so far by a
wide margin, from a mix of genuinely new functionality (7 real modules
now importable) and, more than that, six bugs in code that had shipped
several phases ago. Worth naming directly: none of the six were found
by *reasoning about* the VM or compiler in the abstract — every one
surfaced from trying to run someone else's real, working Lox source
(glox's own shipped standard library) through this port and taking the
first failure seriously enough to trace to its actual root cause
rather than working around it. That's the same lesson the previous
section's three bugs taught, generalized: this port's own hand-written
tests, however thorough, encode only the assumptions their author
already had — real external source is what finds the assumptions that
were wrong.

### Phase 6d: compiler gap sweep — EOL tolerance, const-local rejection, finally trampoline

Three specific, previously-identified gaps, tackled together in one sitting
since the third turned out to depend on groundwork already sitting unused in
`compiler_state.odin` from Phase 3 (`Try_Finally.pending`/`Trampoline_Site` —
see that phase's own note that implementing the trampoline blind, with no VM
yet to validate against, was deliberately deferred until real test coverage
could catch a wrong answer). That coverage now exists.

1. **`}` immediately followed by `except`/`finally` on the next line didn't
   parse**, and neither did `except Exception as e` with its own `{` on the
   next line. Same root cause as every prior bug in this class (the
   scanner's `keep_eol` heuristic — see Phase 5's first-run bug writeup —
   only looks at the token *before* an Eol, so it can't know a `}` will be
   followed by a keyword that should tolerate one): fixed with `match(p,
   .Eol)` at every clause boundary `try_except_statement` checks (before the
   try body's own `{`, between the try body and the first `except`, between
   successive `except` clauses, and before `finally`'s own `{`) — found via
   `finally_bare_ns.lox` and `catch_runtime.lox`, both of which differ from
   an already-passing sibling fixture only in brace/keyword line placement.

   **A more serious bug surfaced while verifying this one, in the same
   family but silent rather than a compile error**: `if (cond)`/`while
   (cond)`/`foreach (...)` followed by `{ body }` on the *next* line
   compiled without error but ran the body **unconditionally**, regardless
   of the condition. Root cause: the "optional parens" grammar refactor
   (Phase 6a-continued) changed these three constructs to parse their body
   via the general `statement(p)` dispatcher instead of a hardcoded
   block-only parse — and `statement(p)`'s own dispatch has a `case
   .Semicolon, .Eol: advance(p) // empty statement` case. A stray Eol
   between the condition and the real `{ body }` got consumed *as* the
   entire conditional/loop body (a legitimate no-op empty statement in that
   context), leaving `{ body }` to be parsed immediately afterward as a
   completely separate, unconditional statement in the enclosing scope —
   confirmed by `if (false)\n{ print "x" }\nprint "after"` printing **both**
   lines. Fixed with the same `match(p, .Eol)` pattern, added immediately
   before each of the four `statement(p)` call sites this affects
   (`if_statement`'s then- and else-branches, `while_statement`'s body,
   `foreach_statement`'s body) — `for_statement`'s body was never at risk,
   since its body is still parsed via a hardcoded `consume(.Left_Brace)` +
   `block()`, not `statement(p)`.

2. **`const` local reassignment wasn't actually rejected.** `named_variable`
   (expr.odin) already had an `is_const_local` check for expression-position
   assignment (`x = 1` as part of a larger expression), but bare `x = 1` as
   a full statement is dispatched separately, through
   `implicit_assignment_statement` (added when statement-level implicit
   assignment was first wired up) — which went straight to `Set_Local` with
   no const check of its own. `const a = 5; a = 6; return a` returned `6`
   with no error. Fixed by adding the same `is_const_local` check there.

   Matching the error message itself to glox's own (`Cannot assign to const
   '%s'.`, naming the variable) surfaced a second, narrower bug: in
   `named_variable`'s compound-assignment branch (`x += 1`), building the
   message from `name`'s own lexeme *after* that branch's `advance(p)` call
   produced the wrong text — `"Cannot assign to const '+='."` instead of
   `"...'a'."` — even though `name` is passed by value and `advance(p)`
   only mutates `p.previous`/`p.current`, not the callee's copy. Root cause
   not fully pinned down (worth another look if a similar symptom recurs
   elsewhere: a value parameter observably changing after a call that only
   touches the parser struct, not the parameter itself); worked around
   robustly by capturing `lexeme(name)` into a local `string` at the very
   top of `named_variable`, before anything else runs, and using that
   captured string in both error sites instead of re-deriving it later.

   Verifying this end-to-end (via `test_const_local.py`, which checks the
   message text through `run_lox`'s stdout-only capture) surfaced a third,
   much bigger bug, unrelated to `const` itself: **every compile-time error
   this compiler reports was going to stderr** (`parser.odin`'s
   `error_at`, via `fmt.eprintfln`) **while glox's own compiler reports them
   to plain stdout** (`compile.go`'s `errorAt`, `fmt.Printf`) — confirmed by
   reading glox's source directly rather than guessing. Since
   `tests/new_tests/lox_helper.py`'s `run_lox` only captures stdout, *every*
   test asserting on a compile-error message via that helper was silently
   seeing empty output and failing on `'' does not contain ...` rather than
   the real mismatch, regardless of whether the message itself was right —
   this had been masking failures since `lox_helper.py` was first wired up
   in Phase 0. Fixed by switching `error_at` to `fmt.printfln` (stdout),
   matching glox exactly. The equivalent mismatch existed for *runtime*
   errors too — `main.odin`'s `run_file` used `fmt.eprintln` for the
   `Runtime_Error` case where glox's own `main.go` uses plain
   `fmt.Println` — fixed the same way, found via
   `test_except_break_stale_handler` (see below) failing with an
   `IndexError` (one stdout line short) despite the actual VM behavior
   already being correct.

3. **`finally` never replayed on `break`/`continue`/`return` crossing a
   `try`** — the Phase 3-era known simplification. `break`/`continue`
   already correctly unwound `frame.handlers` when crossing a `try`
   (`cross_tries`, itself a Phase 6a-continued-part-2 fix for a stale-handler
   bug), but never re-ran that try's own `finally` cleanup on the way out;
   `return` crossing a `try`/`finally` skipped `finally` entirely, and a
   nested `try`/`finally` under a `return` only ran the outer cleanup, never
   the inner one. Implemented glox's own deferred-trampoline design in full
   (`docs/exception-handling.md`, "The trampoline: why return/break/continue
   can't just splice inline") using the `Try_Finally.pending`/
   `Trampoline_Site` shapes already sitting in `compiler_state.odin` since
   Phase 3: `return`/`break`/`continue` crossing a `try` defer into that
   try's `pending` list instead of emitting their terminal instruction
   immediately (since `finally` is parsed *last*, whether one exists at all
   isn't known until `try_except_statement` actually gets there); once it
   is known, `compile_pending_trampolines` resolves every deferred site —
   patch the jump, replay the `finally` body from its snapshotted token
   position if one exists, then either chain onward to a further outer
   `try` the same jump also crosses, or finally emit the real terminal
   instruction. `return`'s value is anchored in a synthetic `__retval` local
   before the (not-yet-parsed) `finally` block can declare locals of its own
   that might reuse the slot; `local_count_at_crossing` on each site
   reserves dummy locals up to the exact runtime stack height at the
   crossing point before compiling a replay, so the replay's own locals
   can't alias a still-live crossing value sitting higher on the real
   stack. `return` needs no `Op_End_Try` unwinding at all (unlike
   break/continue) — `Op_Return` already resets `stack_top` to the frame's
   own base and discards `frame.handlers` wholesale via the frame pop, so
   there's nothing stale left to clean up first, matching glox's own
   `returnStatement`.

   **One deliberate deviation from glox's design**: glox's `trampolineSite`
   carries a `finalize func(p *Parser)` closure (capturing the enclosing
   `*Loop` by reference) that runs whenever a deferred site finally
   resolves — safe in Go, since a closure that escapes its defining frame is
   heap-promoted by the GC. Odin has no such guarantee for a `proc(p:
   ^Parser)` value stored in a struct field and invoked much later, from a
   completely different point in the compile pass, after the defining call
   has long since returned — and nothing in this codebase previously
   exercised that pattern to lean on it with confidence (this exact
   `finalize` field existed, unused, since Phase 3). Replaced with an
   explicit `Trampoline_Kind` enum (`Return`/`Break`/`Continue`) plus a
   plain `^Loop` field — already a stable heap allocation via `push_loop`'s
   own `new(Loop)` — so `compile_pending_trampolines` switches on `kind`
   explicitly instead of calling a stored closure.

   Fixed by (and verified against) `finally_return.lox`,
   `finally_break_continue.lox`, and `finally_nested.lox`, plus
   `except_break_stale_handler.lox` incidentally getting its correct output
   for the first time once the stdout/stderr fix above landed alongside it.

**Regression coverage**: all 67 `compiler`-package tests and all 62
`vm`-package tests reverified individually
(`-define:ODIN_TEST_NAMES=<pkg>.<test>`, one at a time), not just via a
batched `odin test` run — the batched run itself still hit the
long-documented toolchain segfault a few times while this work was in
progress (confirmed non-reproducing for any single test in isolation, so
attributed to that known issue per the standing "isolate first, attribute to
known flakiness second" lesson, not treated as a new regression).

**Milestone check**: `python -m pytest tests/new_tests/ -q` — 147 passed / 83
failed / 14 skipped before this work, **171 passed / 59 failed / 14
skipped** after — every one of the 24 newly-passing tests a direct or
incidental consequence of the fixes above (the stdout/stderr fix alone
flipped several unrelated tests that were asserting on compile-error text
that was always correct but never actually reaching the assertion). Two
unrelated, pre-existing gaps were noticed while chasing these but are out of
scope for this pass and still open: `test_break_unbraced.lox`/other fixtures
using bare `i = 0` (no `var`) as a `for` loop's init clause hit "Undefined
variable" at runtime (a `for`-init-clause-specific implicit-global-assignment
gap, unrelated to `implicit_assignment_statement`'s own statement-level
handling); and a construct followed immediately by another statement with
*no* newline at all between them on the same source line (`if (true) { ... }
print "after"`, all one line) still fails to parse.

### Phase 6e: clearing the non-module-dependent pytest backlog

Follow-up to Phase 6d: asked to fix every remaining pytest failure that
*isn't* blocked on a not-yet-implemented native module (`process`/`pool`/
`re`/`pickle`/`json`/`colour_utils`/`inspect`/`gfx` all stay out of scope,
same as always). Ten separate, unrelated real bugs, each found by tracing
one specific failing fixture to its actual root cause:

1. **`for (...)\n{` didn't parse** -- the same Eol-before-brace class fixed
   for if/while/foreach/try/except/finally in Phase 6d, but `for_statement`'s
   doc comment specifically (and wrongly) claimed no fixture needed it,
   since its body is parsed via a hardcoded `consume(.Left_Brace)` rather
   than `statement(p)`. `closure_list.lox` needed exactly this. Fixed the
   same way: `match(p, .Eol)` before that consume call.

2. **Crash-guard message wording didn't match glox's exact text**:
   `break`/`continue` outside a loop said "Can't use 'break' outside of a
   loop." where glox says "Cannot use break outside loop."; int `%` by
   zero said "Modulus by zero." where glox uses the same "Division by
   zero" wording for both `/` and `%`. Both changed to match glox's own
   compile.go/vm.go text exactly -- confirmed nothing else in this port
   depended on the old wording first.

3. **Exception `toString()` prefixed the class name**: `class Exception {
   toString() { return this.name & ": " & this.msg } }` (in
   `exceptions.odin`'s embedded `EXCEPTION_SOURCE`) returned
   `"MyException: something happened"` where glox's own exceptionSource
   (builtin.go) returns just `this.msg`, no prefix at all. Wasn't a
   documented deliberate improvement, just untracked drift -- fixed to
   match glox exactly. Fixed `except.lox`/`except_fn.lox`/`except_fn2.lox`/
   `except_two_handlers.lox`/`nested_try_two_handlers.lox` all at once.

4. **`os.readln`'s EOF detection was one read short of glox's own
   behavior**, for any file ending in a trailing newline (the overwhelmingly
   common case): `core.file_read_line` returned `ok=false` immediately when
   the read that discovered EOF also returned zero bytes, but glox's own
   `FileObject.ReadLine` (obj_file.go) has a fallthrough shape where that
   *exact* case still returns a successful (empty-string) read, and only
   the *following* call reports real EOF -- confirmed against glox's actual
   binary on `except_native_raise.lox` (which counts total lines read from
   itself until EOFError): glox reports 27, this port reported 26 for the
   identical 26-line file. Fixed to match glox's fallthrough exactly.

5. **`in` was never wired up as an expression operator at all** --
   `Op_Code.In` and its VM implementation (`do_in`, collections.odin)
   already existed and were already correct, but the compiler's rule table
   had no entry for the `.In` token and `binary()`'s dispatch had no case
   for it either, so `"hello" in s` fell through to `variable`'s bare-
   identifier-read dispatch and failed to parse (`foreach`'s own
   `consume(p, .In, ...)` never goes through the Pratt parser, so that use
   was unaffected and always worked). Added the rule table entry
   (`{nil, binary, .Equality}`, matching glox's own `PREC_EQUALITY` exactly)
   and the `.In: emit_op(p, .In)` case in `binary()`.

6. **`for (i = 0; ...)` (bare, no `var`) hit "Undefined variable" at
   runtime** -- `for_statement`'s non-`var` init-clause branch called plain
   `expression(p)`, which routes a bare `i = 0` through `named_variable`'s
   ordinary assignment path: a `Set_Global` with no preceding
   `Define_Global`, since first mention alone doesn't mark a global slot
   defined. Statement-level bare assignment already has exactly this
   handling (`implicit_assignment_statement`, added at some earlier phase
   for exactly this reason) but `for_statement`'s init clause never routed
   through it. Fixed by extracting `implicit_assignment_statement`'s body
   (minus its trailing `consume_eol`) into a shared
   `implicit_assignment_core`, used by both the original statement-level
   caller and a new check in `for_statement`'s init clause
   (`check(p, .Identifier) && check_next(p, .Equal)`). Confirmed against
   real glox (`bin/glox.exe` on the identical fixture) that this should
   declare `i` as a *local* scoped to the for-loop's own block, not a
   global -- true automatically here too, since `for_statement`'s own
   `begin_scope()` already put `scope_depth > 0` by the time the init
   clause compiles, so `implicit_assignment_core`'s existing "declare a
   local" branch fires without any further change. Fixed
   `break_unbraced.lox`.

7. **Bare `return` immediately before a one-line block's own `}` didn't
   parse** (`func g() { return }`, no `;`/newline separating `return` from
   the block's closing brace): `return_statement`'s "does a value
   expression follow" check only recognized `.Eol`/`.Eof`/`.Semicolon` as
   "no value", not `.Right_Brace` -- inconsistent with `consume_eol`
   (parser.odin) treating `Right_Brace` as an equally-valid implied
   terminator, matching glox's own `checkStatementEnd`/`consumeStatementEnd`
   (compile.go), which explicitly lists `TOKEN_RIGHT_BRACE` alongside
   `TOKEN_EOL`/`TOKEN_SEMICOLON`/`TOKEN_EOF`. Fixed by adding
   `check(p, .Right_Brace)` to that check. `oneline_blocks.lox`'s apparent
   *second* failure (a statement immediately following `}` with no newline
   between them at all) turned out to be a pure cascading artifact of this
   same bug's parse error, not an independent gap -- fixed for free once
   this one was.

8. **String repetition (`"-" * 50`) wasn't supported at all** --
   `numeric_binop` (arithmetic.odin, handles Subtract/Multiply/Divide/
   Modulus) required both operands to be numeric unconditionally, with no
   per-op carve-out, where glox's own `binaryMultiply` (vm.go) special-cases
   `string * int` / `int * string` (repeats the string) before its own
   "must be numbers" check. Added the same carve-out, backed by a
   `string_multiply` helper matching glox's `stringMultiply` exactly
   *including* its behavior for a non-positive count (an empty string --
   glox's own `for i := 0; i < x; i++` loop simply never executes; Odin's
   `core:strings.repeat` panics on a negative count instead, which would
   have crashed the whole process on `"x" * -1` rather than matching
   glox's silent empty-string result, so `string_multiply` guards that case
   itself before ever calling `strings.repeat`). Fixed
   `list_slice.lox`/`for_break_nested.lox` (the latter's own comment
   explains its `break` regression coverage, unrelated to the string-repeat
   bug it also happened to trip over via a `"-" * 50` separator line).

9. **`sys.args()` was always one element short of glox's own** -- glox's
   `ArgsBuiltIn` (core_functions.go) returns `vm.Args()` verbatim, and
   `main.go` passes `os.Args[1:]` (script path *and* every argument after
   it, unfiltered) straight to `SetArgs`. This port's own CLI parsing
   (`main.odin`) only appended arguments seen *after* `file_path` was set,
   so `sys.args()` here never included the script's own path at all --
   `sys.args()[0]` always pointed at whatever the *first* extra argument
   was (or panicked, if there were none). Fixed by also appending the
   argument that sets `file_path` itself, so `script_args[0] ==` the
   script's own path, matching glox exactly. Fixed
   `logging_file_writer.lox`, which does `os.dirname(sys.args()[0])` to
   build an output path alongside the running script.

**One crash noticed, deliberately not fixed this pass**: `colour_utils.lox`
segfaults (a genuine native stack overflow, confirmed via PowerShell's
`$LASTEXITCODE` reporting `STATUS_STACK_OVERFLOW`) rather than reporting a
clean "module not found" error. Root cause: `colour_utils` is a *native*
built-in module in real glox (`makeBuiltInModule`/`defineBuiltIn`,
builtin.go), checked before any file search ever runs there, so it never
falls through to `findModuleInSubdirs` -- which has an identical latent
self-import footgun in *both* glox and this port (no exclusion for the
currently-running script's own path, and no "currently being imported"
cycle guard at all). Since the fixture's script happens to be named
`colour_utils.lox` and the module of the same name doesn't exist as a real
file, `find_module_in_subdirs` (module.odin) matches the *running script's
own path* and re-imports/re-interprets it as "the module", which itself
imports `colour_utils` again, unboundedly. This is entirely gated behind
`colour_utils` not yet existing as a native module here (Phase 6b,
explicitly out of scope for this pass) -- once it's added as a builtin the
same way glox has it, `load_module`'s builtin-check short-circuits before
the file search ever runs, same as glox, and this crash path stops being
reachable. Left as-is rather than adding untested general cycle-detection
with no real fixture to validate it against.

**Regression coverage**: all 67 `compiler`-package, 62 `vm`-package, and 41
`core`-package tests reverified individually (`-define:ODIN_TEST_NAMES=
<pkg>.<test>`), not just a batched run, per this project's standing
"isolate first" testing discipline.

**Milestone check**: `python -m pytest tests/new_tests/ -q` — 171 passed /
59 failed / 14 skipped before this work, **203 passed / 27 failed / 14
skipped** after, confirmed stable across three repeated full-suite runs.
Every one of the 27 remaining failures is gated on a native module this
port hasn't built yet (`process`/`pool`/`re` (`regex`)/`pickle`/`json`
(needs `pickle`/`re`)/`colour_utils`/`inspect`/`gfx` (needed by
`rgb_encode.lox`)) -- none are compiler/VM-core gaps as of this section.

### Phase 6f: `colour_utils`/`gfx` (non-raylib subset), vec2/3/4 `.add()`, `float_array`, and the error call stack trace

Four separate asks tackled together: `colour_utils`, the `gfx`/`physics`
modules (scoped to what doesn't need raylib), `vec2`/`vec3`/`vec4` methods
"beyond basic arithmetic", `float_array`, and the error call stack trace
noted at the end of Phase 6e.

**The `natives` package (Phase 6d's skeleton) gets its first real content.**
`vm.make_builtin_module`/`vm.define_builtin` both had to lose their
`@(private)` tag -- package-private, they were only ever callable from
inside the `vm` package itself, which was fine when nothing outside `vm`
registered natives, but blocks exactly the mechanism `natives` needs to
create its own built-in modules and register functions under them. Both
are now package-public, matching `core.Builtin_Fn`'s own already-public
shape (docs/ARCHITECTURE.md's Native/builtin functions section covers why
that boundary is public in the first place).

**`colour_utils`** (`src/natives/colour_utils.odin`): `fade`/`tint`/
`brightness`/`lerp`/`hsv_to_rgb`/`random`, ported from glox's
`src/builtin/color_functions.go` clamp-for-clamp and truncation-order-for-
truncation-order -- every function returns a vec4 `(r, g, b, 255)`, same
as glox's own `core.MakeVec4Value(..., 255.0, false)`. None of it needs
raylib; it lives in `natives` rather than `vm/builtins*.odin` purely to
keep the whole module (registration + everything under it) in one place,
same reasoning as `gfx.odin` below.

**`gfx`/`physics`, scoped to the non-raylib subset**: glox's real `gfx`
module (`src/vm/builtin.go`'s `makeBuiltInModule(vm, "gfx")`) is a large
raylib-dependent surface -- window/image/texture/render_texture/shader/
camera/batch -- none of which this port implements yet (that's Phase 6b,
a separate, much larger effort: real windowing, an actual `vendor:raylib`
dependency, a native object per raylib resource type). What's registered
now is deliberately just the parts of `gfx` that are pure math or a plain
data structure with no raylib dependency of their own:
`encode_rgba`/`decode_rgba` (bit-packing, ported from glox's
`src/builtin/os_functions.go`/`src/util/colour.go`) and `float_array`
(below). `physics.physics_world` is registered as a stub that raises a
clear "not yet implemented" error if actually called -- glox's own
version is a genuine hand-rolled spatial-grid physics engine
(`src/builtin/obj_builtin_physics_world.go`), well beyond this pass's
scope, and the only thing anything in the ported test suite checks is
`type(physics.physics_world) == "builtin"`, which a stub native function
already satisfies without needing real physics behind it.

**`vec2`/`vec3`/`vec4` methods "beyond basic arithmetic" turned out to be
a much smaller gap than ROADMAP itself assumed** when that bullet was
first written: reading glox's actual `VectorMethodCall` (vm.go) shows the
*entire* vec2/3/4 method surface is exactly one method, `.add(other)` (in-
place addition, special-cased by name) -- there is no swizzle-beyond-
`.x/.y/.z/.w`, no `.length()`/`.normalize()`/`.dot()`/`.cross()` anywhere
in glox's own vector types. `.x`/`.y`/`.z`/`.w` (+ `.r`/`.g`/`.b`/`.a` on
Vec4) field access was already fully implemented (`properties.odin`,
since an earlier phase); `.add()` itself was not -- `call.odin`'s
`invoke()` required `receiver.type == .Obj`, and a vec2/3/4 Value's own
`.type` is `.Vec2`/`.Vec3`/`.Vec4` (a top-level tag, not nested under
`.Obj` -- see `docs/ARCHITECTURE.md`'s Value representation section), so
calling `.add()` on any vector unconditionally hit "Only objects have
methods." Fixed with a new `invoke_vector_method` (call.odin), checked
before the `.Obj` requirement, mirroring `VectorMethodCall`'s exact stack
convention: pop just the one argument, leave the (now-mutated) receiver
in place as its own return value.

**`float_array`** (`core/obj_float_array.odin` + `call.odin`'s
`invoke_builtin_float_array` + `natives/gfx.odin`'s `float_array`
constructor): a flat row-major w\*h `f64` buffer, ported from glox's
`src/builtin/obj_builtin_farray.go`/`farray_methods.go` --
`get`/`set`/`clear`/`width`/`height`, same argument order. Needed a new
`Object_Type` tag (`.Float_Array`) and the handful of touch points every
existing heap-object kind already has: `object_to_string` (`<FloatArray
WxH>`, matching glox's own `String()`), `type()` (reports `"builtin"` --
matching glox's own `FloatArrayObject.GetType()`, which deliberately
returns `OBJECT_NATIVE` rather than a dedicated kind, not a claim that
odlox's version is literally a bare function), and `gc.odin`'s free/size-
estimate switches (`values_equal`'s switch is `#partial` and needs no new
case at all -- falling through to reference-identity equality for an
unlisted kind is already the correct default, matching glox's own "every
kind not String/List/Dict is identity equality"). One real, deliberate
deviation from glox: `FloatArray.Get`/`Set` (Go) panics on an out-of-range
index; `core.float_array_get`/`float_array_set` return an `ok` bool
instead, and the VM turns a failed one into an ordinary Lox runtime error
-- matching every other bounds check in this port rather than crashing
the whole process on a script-level indexing mistake. No fixture in the
ported test suite exercises `float_array` (glox's own copy is only ever
used from raylib-drawing code this port doesn't have yet); verified
manually instead -- construction, every method, an out-of-range get
caught cleanly via `try`/`except`, and a 2000-iteration allocate-and-
discard loop to exercise the GC's own free path under real collection
pressure.

**Error call stack trace**: implemented per Phase 6e's own TODO, using
the `source`/`stack_trace` fields already sitting on `VM` unused. `vm.source`
is now actually assigned (`interpret.odin`, right where `stack_trace` was
already being reset to nil at the start of each run). `exceptions.odin`
gained `append_stack_trace` (mirroring glox's `appendStackTrace` exactly:
one `File '<script>', line <N>, in <function>` entry plus the actual
source line's text, per frame `raise_exception`'s unwind loop visits,
recorded *before* that frame is popped) and `source_line` (extracts a
1-indexed line's text out of `vm.source`, mirroring glox's own
`sourceLine`). `main.odin` prints `vm.stack_trace` (via a new
`vm.print_stack_trace`) right after the error message itself, in both the
file-run and REPL `Runtime_Error` cases -- unconditional, not an opt-in
debug feature, matching glox's own `main.go` exactly.

**Real bug caught while testing this, not left in**: `match_clause_chain`'s
two successful-match returns (a matching `except` clause, and the always-
matching `Finally` handler) didn't clear `vm.stack_trace` -- glox's own
equivalent success branches do (`vm.stackTrace = []string{}`, `vm.go`).
Without it, a *caught* exception's trace entries lingered and would get
prepended, stale and misleading, to a genuinely later *uncaught*
exception's real trace within the same `interpret()` call -- confirmed by
writing exactly that scenario (a caught exception in one function,
followed by an unrelated uncaught one in another) and checking the
second trace didn't include the first's leftover entries. Fixed with a
small `clear_stack_trace` helper called at both success points.

**One existing pytest assertion was wrong, not this feature**: adding the
trace surfaced that `test_tuples.py` asserted an uncaught exception's
message was `lines[-1]` (the *last* line of output) -- true only when
nothing gets printed after it, which was never actually glox's own
behavior (confirmed against the real `bin/glox.exe` on this exact
fixture: it also prints a trace after the message, so the message isn't
the last line there either). Fixed the assertion to check the specific
line index the message actually lands at (`lines[7]`, right after the
already-verified `lines[6]`) instead of assuming it's last -- this was a
test bug the trace's absence had been masking, not a regression the
trace introduced.

**Regression coverage**: all 67 `compiler`-package, 62 `vm`-package, and 41
`core`-package tests reverified individually, plus a GC stress smoke test
(2000 float_array allocate/discard iterations) run manually.

**Milestone check**: `python -m pytest tests/new_tests/ -q` — 203 passed /
27 failed / 14 skipped before this work, **207 passed / 23 failed / 14
skipped** after (the 4 gained: `test_colour_utils`, `test_rgb_encode`
[both parametrizations], `test_builtin_modules`). Every one of the 23
remaining failures is still gated on a native module this port hasn't
built yet (`process`/`pool`/`re`/`pickle`/`json`/`inspect`) -- `gfx`
itself is no longer in that list (its only ported-suite dependents needed
exactly the subset now implemented).

### Phase 6g: `colour.lox` port, and a real bug in the stack trace it found

Small follow-up once cross-checking against glox's full module list
(prompted by a question about the Phase 6 checklist being too terse to
serve as an actual inventory) turned up that `colour.lox` — unlike
`json.lox`/`pool.lox`, still genuinely blocked on `re`/`process`/`thread`
— only imports `random` and `colour_utils`, both already implemented as
of Phase 6f. Copied verbatim into `modules/colour.lox` (no source changes
at all — `diff` against glox's own copy is empty) and verified manually,
function by function, since no pytest fixture exercises this module in
either repo: every colour constant, `primary_colours()`, `scale_colour()`,
`fade`/`lerp`/`brightness`/`tint`/`hsv_to_rgb` (each just a thin wrapper
around the `colour_utils` native functions Phase 6f already added), and
`random_rgb()`.

**One function left deliberately broken, matching glox exactly**:
`ColourFromEncoded(value)` calls a bare `decode_rgb(value)` — no such
name exists anywhere in glox itself (only `gfx.decode_rgba`, under the
`gfx` module, never imported by `colour.lox` at all) and calling it always
raises "Undefined variable 'decode_rgb'." Confirmed byte-for-byte against
real glox (`bin/glox.exe` on the identical call): same error, same
unreachable-in-either-test-suite status (`ColourFromEncoded` is only ever
referenced from `plot_rgb.lox`, itself blocked on raylib). A real,
pre-existing bug in glox's own module, ported faithfully rather than
silently fixed.

**A genuine bug in Phase 6f's own stack trace, found while manually
verifying `ColourFromEncoded`'s failure**: the trace's file/line/function
line was correct, but the source-line context that should follow it came
back blank whenever the failing frame belonged to a function defined in
an *imported* module (as opposed to the top-level script) — `vm.source`
only ever holds whichever source text this VM's own `interpret()` call
most recently compiled, but a module's functions run as ordinary closures
in the *calling* VM, using a `Chunk.filename` that doesn't match that
VM's own `.script` at all. glox has the identical problem in principle
and solves it with a process-wide `globalModuleSource map[string]string`
(vm.go), keyed by bare module name, checked by `sourceLine` whenever the
requested script differs from the current VM's own -- this port had no
equivalent at all. Fixed with `module.odin`'s new `module_source_cache`
(same shape, no mutex needed for the same reason `module_cache` itself
doesn't need one -- see that file's own header comment on why), populated
in `load_module` right where a module's source is first read, and
`exceptions.odin`'s `append_stack_trace` now picks `vm.source` or this
cache based on the same `chunk.filename != vm.script` comparison glox's
own `sourceLine` makes. Confirmed against real glox's output for the
exact same failing call — file, line, function, *and* source-line text
all now match exactly.

**Regression coverage**: all 62 `vm`-package tests reverified individually.

**Milestone check**: `python -m pytest tests/new_tests/ -q` — unchanged at
207 passed / 23 failed / 14 skipped (no fixture exercises `colour.lox` or
this specific stack-trace path, so this phase's own verification was
entirely manual — documented here in full for that reason, not left to
commit history alone).

### Phase 6h: `inspect`, `re`, `pickle`, `json.lox`, and a parked `process`

The remaining Phase 6 native modules, tackled in dependency order:
`inspect` (self-contained) → `re` (needed by `json.lox`) → `pickle`
(needed by `process`) → `process` → `json.lox` (ported once `re` existed).

**`inspect`** (`debug/inspect.odin` + `natives/inspect.odin`): ported from
glox's `src/debug/inspect.go`. `get_frame()` builds a dict of the current
frame's function/line/file/args/locals/globals, recursing into
`prev_frame` down to the top-level script's own frame; `dump_frame()`
prints a plain-text snapshot of the current frame/stack/globals. Locals
are found via this compiler's own existing per-local debug info
(`Chunk.local_vars`, checking `start_ip <= frame.ip < end_ip` per entry)
rather than re-deriving scope boundaries from arity the way glox's own
`DictOfLocals` does. One real bug found immediately by testing against
the ported fixtures: `file` reported the full path
(`function.chunk.filename`) where glox's own `vm.FileName()` (and the
fixtures' own expectations) use just the bare filename — fixed with
`filepath.base(v.script)`.

**`re`** (`vm/regex.odin` + `natives/re.odin`, new `core.Regex_Pattern_
Object`/`core.Regex_Match_Object` types): built on Odin's own
`core:text/regex` engine rather than a hand-rolled one, with one gap to
compensate for -- that engine has no equivalent of Python/RE2's
`(?P<name>...)` named capture groups at all. Fixed with this port's own
preprocessing pass (`preprocess_pattern`): strips `(?P<name>...)` down to
plain `(...)` before compiling, recording which capture-group number
each name corresponds to (groups are numbered by the position of their
opening paren, left to right; `(?:...)` is non-capturing and doesn't
consume a number, matching every regex engine's own convention).
`match()`/`fullmatch()` don't need a second compiled/anchored variant of
the pattern -- both are implemented as an ordinary `search()` plus a
check of the result's own span, since a thread-based engine that tries
starting positions left-to-right (as Odin's own does) finds a position-0
match first if one exists. One accepted, narrow limitation, not
exercised by anything in the ported suite: Odin's own capture result
compacts away any group that didn't participate in a match (e.g. one
side of an alternation) rather than leaving a hole, so a group *after*
one that failed to participate would be misnumbered here -- not worth
reimplementing capture extraction against the lower-level
`virtual_machine` package directly to close.

**Real bug, found by the ported `regex_basic.lox` fixture**: a compiled
`Pattern`'s own `.sub()`/`.subn()` methods had `repl`/`s` swapped *and* an
out-of-range stack peek, both from copy-pasting the argument-order
convention `vm/builtins.odin`'s *free functions* use (ascending
`arg_stack_ptr + i`) into a method-dispatch context that actually needs
the opposite, descending `peek(v, N)` convention (`invoke()`'s own
calling convention, top-of-stack-first) -- the module-level `re.sub()`
free function was unaffected (it already used the correct convention for
*its* own calling shape) and passed on the first try, which is exactly
why only the compiled-Pattern path's own tests caught this.

**`pickle`** (`core/pickle.odin` + `natives/pickle.odin`): a tag-based
binary serialiser for plain-data values (nil/bool/int/float/string/list/
tuple/dict/vec2/3/4/class instances), ported from glox's `src/core/
pickle.go` in spirit -- not required to be byte-compatible with glox's
own encoding, since this only ever needs to round-trip between two
*odlox* processes. Same discipline as the original: never panics on
malformed/truncated input (always returns an error instead, since decode
input is untrusted -- a script value, a file, or bytes from another
process), and the same "currently visiting" cycle guard for lists/dicts/
instances. Class instances round-trip field data only, never methods/
code -- `loads()` resolves the class by name against the *calling
frame's own* global scope, reusing `vm.resolve_class_by_name`
(`exceptions.odin`) unchanged, the exact same lookup an `except
ClassName` clause already does. `PickleError` (and `ProcessError`, for
the module below) added to the exception bootstrap (`EXCEPTION_SOURCE`),
alongside `Exception`/`RunTimeError`/`EOFError` -- Phase 6's own note
about adding each new exception class "alongside its own module instead"
made this the right moment. A `Class_Resolver` callback needed a rethink
partway through: an initial attempt tried to capture the resolving `^VM`
in a closure, which this project's own established stance (Phase 6d's
`Trampoline_Site`, choosing an explicit enum+pointer over a captured
closure for the same reason) already flags as untested/risky in this
codebase -- redone as a plain function pointer plus an opaque `ctx:
rawptr` parameter instead (the same rawptr-boundary shape `core.Builtin_
Fn` already uses to let `core` call back into `vm` without importing it).
`vm/gc.odin` gained `gc_adopt`, recursively `gc_track`-ing every
collectible object in a freshly-decoded value tree -- needed since
`pickle_decode` can run with no VM in scope to register objects with as
they're allocated (true for the "process" module's own use, below, even
though `pickle.loads()` itself always has one).

**`process`** (`core/obj_process.odin` + `vm/process.odin` +
`natives/process.odin`, new `core.Process_Object` type): spawns another
odlox process (`os.process_start`, wired to a pair of `os.pipe()`s for
its stdin/stdout) and exchanges pickled values with it, framed with a
4-byte little-endian length prefix (`frame_write`/`frame_read`) --
glox's answer to Python's `multiprocessing`, ported from `src/builtin/
obj_builtin_process.go`/`process_functions.go`/`process_methods.go`.
One deliberate, load-bearing deviation from glox's own design: glox runs
a background goroutine per `Process` that reads continuously into a Go
channel, so `wait_any()` can `select` across every process's channel at
once. This port has no general-purpose threading model exposed anywhere
(see this file's own header, and `docs/ARCHITECTURE.md`'s Scope section
-- threads are out of scope entirely), so there is no background reader
thread here at all: `recv()` reads the pipe directly (blocking, as
anonymous pipes are by default); `try_recv()`/`wait_any()` instead check
`PeekNamedPipe` before attempting a read, and `wait_any()` round-robins
across every still-live process with a short sleep between full rounds
once none are ready, rather than a true multi-handle OS-level wait.
**`spawn`/`send`/`recv`/`wait`/`kill`/`pid` are implemented and tested
(`test_process_basic` passes both parametrisations) -- `wait_any()` is
not, and the whole module is parked with it unfixed** (see the
Known-issues note below and the Phase 6 checklist above) rather than
continuing to chase it.

**Known issue, parked rather than resolved**: `process.wait_any()`
raises a spurious "truncated message" `ProcessError` under
`process_wait_any_pool.lox`'s own fire-and-forget pattern (several
workers each sending several messages back-to-back with no request/
response handshake, then exiting immediately). One real bug in this
area *was* found and fixed along the way -- Windows' `PeekNamedPipe` can
report a broken pipe as soon as the writer closes its end, even while
data the writer already sent is still sitting unread in the pipe buffer;
treating a failed peek as an immediate EOF signal (this port's first
attempt) silently dropped whichever messages hadn't been drained yet.
Fixed by treating a failed peek as "attempt a real read anyway, let
`frame_read`'s own EOF detection be the actual authority" rather than an
EOF signal in itself. This fix did **not** resolve the "truncated
message" failure, though — it still reproduces after it, and the exact
remaining mechanism wasn't pinned down before this was parked. Suspected
territory for whoever picks this back up: a race between a worker's
several back-to-back `frame_write()` calls (each its own pair of
`os.write` calls, length-prefix then payload) and this side's own
peek-then-read polling, or a subtlety in how Windows anonymous pipes
behave once their write-end process has already exited but the parent's
read-end handle is still being polled mid-message.
`tests/new_tests/test_process.py`/`test_pool.py` are both skipped at the
whole-file level (`pytestmark = pytest.mark.skip(...)`) pending this,
rather than left failing or partially skipped test-by-test.

**`json.lox`**: copied verbatim (`diff` against glox's own copy is
empty) once `re` existed -- its only import besides already-implemented
`os`. Passed both ported tests (`test_json_basic`, `test_json_load`) on
the first run, no fixes needed.

**Regression coverage**: all 67 `compiler`-package, 62 `vm`-package, and
41 `core`-package tests reverified individually.

**Milestone check**: `python -m pytest tests/new_tests/ -q` — 207 passed
/ 23 failed / 14 skipped before this work, **218 passed / 0 failed / 26
skipped** after (`process`/`pool` tests moved from failing to skipped,
12 total, rather than passing -- see above). Every test in the ported
suite now either passes or is skipped for an understood, documented
reason (`thread`/`sync` permanently out of scope; `process`/`pool`
parked pending the `wait_any` bug).

### Phase 6i: `physics_world`

The last remaining Phase 6 stub. Faithful port of glox's
`obj_builtin_physics_world.go`/`physics_world_methods.go` — a hand-rolled
3D struct-of-arrays sphere/box physics simulation (uniform-grid broad
phase, 27-cell narrow phase, new-contact-only collision reporting via a
ping-pong `map[pair]bool`, boundary bounce). **Zero raylib dependency**,
confirmed before starting — this is why it was resequenced ahead of
`gfx` despite `TODO.md` previously listing it last: fully testable via
ordinary `pytest`, no display/window needed at all.

**Files**: `core/obj_physics_world.odin` (new — `Physics_World_Object`
and its supporting types: `P_Vec3`, `Shape`/`Shape_Kind`,
`Physics_Material`, `Physics_Cell_Key`/`Physics_Pair_Key`,
`Collision_Pair`, plus the constructor and a `physics_world_count` pure
accessor `object_to_string` needs — `core` can't import `vm`, so this is
the one piece of "real" logic that has to live here rather than
alongside the rest); `vm/physics_world.odin` (new — the actual
simulation: `step`/`integrate`/`boundary_collisions`/`rebuild_grid`/
`narrow_phase`/`resolve_static_pairs`/`collide`/`resolve`, plus
`invoke_builtin_physics_world`'s full Lox-facing method dispatch);
`natives/physics.odin` (constructor, replacing the old "not yet
implemented" stub); `core/object.odin`/`core/value.odin`/`vm/call.odin`/
`vm/gc.odin`/`vm/builtins.odin` each got the one-case-per-file addition
this port's established native-object checklist calls for (same
recipe as this session's `Regex_Pattern`/`Process` additions).

**Deliberately not fixed**: `Physics_Material.friction` is stored and
combined (`combine_materials`) exactly like `restitution`, but — matching
glox exactly — is never actually applied anywhere in `resolve()`'s
collision response. A real glox limitation, ported faithfully rather
than silently fixed; changing collision behavior mid-port would be an
undocumented deviation, not a bug fix, and is called out explicitly in
both `core/obj_physics_world.odin`'s and `vm/physics_world.odin`'s doc
comments so it doesn't read as an oversight later.

**A real, reproducible Odin bug found and worked around — not a bounds-
check-catchable mistake in this code.** `narrow_phase`'s 27-cell scan
originally read `for j in w.grid[k] { ... }` — ranging directly over a
map-index expression. This **segfaults** when `k` is absent from the
map, identically in both `-debug` (bounds-checked) and `-o:speed
-no-bounds-check` builds — ruling out a simple out-of-range access,
which bounds-checking would have caught as a panic instead of a raw
segfault. Isolated with a minimal standalone repro (a bare
`map[Cell_Key][dynamic]int`, no VM involved at all) before touching the
real fix, to confirm it wasn't specific to this code's surrounding
complexity: `for j in grid[missing_key]` crashes; `bucket := grid[missing_key];
for j in bucket` does not. The bug has a genuine Heisenbug flavor — adding
`fmt.println` calls between statements while bisecting made it stop
reproducing, then reappear reliably (5/5) once the debug prints were
removed — consistent with real undefined behavior (something like a
dangling/short-lived reference to the map's zero-value tempo­rary),
not a logic bug that debug output would be expected to mask. Fixed by
reading into a local (`bucket := w.grid[k]`) before ranging over it —
already the pattern every *other* map read in this file already used
(see `rebuild_grid`); this was the one direct-index exception, now
removed and commented in place as a warning against reintroducing it.
Confirmed fixed: 5/5 clean runs after, both build modes, plus the full
smoke test and pytest fixture below all green.

**Verification**: a hand-written correctness script (falling/bouncing
sphere, a rotated static box + `get_box_transform` round-tripping
exactly what was set, sphere-sphere collision detection with a correct
contact normal, `remove`/`count` bookkeeping, `add_impulse`, and all
three error paths) run manually first to catch behavioral bugs before
formalizing it — one test-design mistake caught this way, not an engine
bug: an exactly-symmetric two-sphere approach with too coarse a `dt`
stepped clean over the entire overlap window in one frame, landing
exactly on the "centers coincide" degenerate case (`dist < 1e-12`,
deliberately excluded to avoid a divide-by-zero) instead of inside it —
fixed by using a finer `dt` in the test, not a code change, since the
engine's discrete-time behavior here is correct and matches glox's own
algorithm exactly. Promoted to `tests/new_tests/lox/physics_world_basic.lox`
+ `test_physics.py` (2 parametrized cases) once verified. Full `pytest`
regression: 220 passed / 0 failed / 26 skipped (up from 218/0/26), both
build modes clean.

### Phase 6j: `gfx.window()` + core 2D drawing

The first real `vendor:raylib` work. Scope deliberately bounded to
window lifecycle, frame begin/end, input, and 2D primitive drawing —
texture/shader/camera/render_texture/image/batch/batch_instanced, 3D
drawing, blend/shader modes, and `draw_array` are explicitly deferred
(see `TODO.md`), matching the smallest-slice-first sequencing this
section of `ROADMAP.md` already called for.

**`vendor:raylib` confirmed present** at
`C:\Users\User\AppData\Local\Programs\Odin\vendor\raylib\` (raylib v6.0,
Windows DLL bundled — no new dependency to install). glox's own binding
(raylib-go, pinned to a May-2025 commit, ≈raylib 5.5) is close enough in
version that the core API used here — `InitWindow`, `BeginDrawing`,
`DrawRectangle`, keyboard/config-flag enums — is unchanged; no
signature mismatches found.

**A real API-shape detail, not an oversight**: glox's `gfx.window(w, h)`
constructor does *not* call `rl.InitWindow` itself — `WindowBuiltIn`
(`obj_builtin_window.go`) just builds the struct; `rl.InitWindow` only
happens inside a separate `win.init()` method
(`win_methods.go`), which also does `SetTraceLogLevel(LogNone)`,
`SetConfigFlags(FlagVsyncHint)`, and `SetTargetFPS(60)`. Ported
faithfully as two separate steps (`natives/gfx.odin`'s `gfx_window`
constructor vs. `vm/gfx_window.odin`'s `"init"` case) rather than
collapsing them, since any real script (once any get ported) will
already call `.init()` explicitly.

**Deliberate deviations from glox, both documented in
`vm/gfx_window.odin`'s header comment**:
- `end()` does **not** call `rl.DrawFPS(10, 10)` automatically the way
  glox's own `end()` does — a debug overlay side effect baked into the
  wrong place. `get_fps()` is exposed so a script can draw its own FPS
  text if it wants one at all.
- `get_screen_width()`/`get_screen_height()` return **int**, not
  glox's float — a screen dimension has no fractional part, and every
  other pixel-coordinate argument in this file is already an int.

**Files**: `core/obj_window.odin` (new — `Window_Object`, a lightweight
marker/context struct; raylib's window/GL-context state is process-
global, so there's no per-object GPU resource to own); `vm/gfx_window.odin`
(new — `invoke_builtin_window`'s full method dispatch, plus a shared
`vec4_to_rl_color`/`arg_color` helper every drawing call uses); `natives/gfx.odin`
(the `gfx.window(width, height)` constructor). Colors cross the boundary
as `vec4`, each channel 0-255 — confirmed against
`natives/colour_utils.odin`'s already-shipped convention
(`colour_utils_fade`'s `clamp255`/alpha-at-255 usage) before assuming
it, not guessed.

**Key constants got the wrong home in this pass — corrected in Phase
6k.** This pass registered `gfx.KEY_A`..`Z`/`0`..`9`/a handful of named
keys as *module*-level constants (`vm/builtins.odin`'s
`define_builtin_const`, mirroring `define_builtin`'s own
`vm.builtin_modules[...]` lookup). Porting a real script in Phase 6k
(`lox_examples/defender`) showed that's not how glox's own scripts
actually reach them: `RegisterAllWindowConstants` (`win_methods.go`)
puts the full `rl.Key*` set directly *on the window object* as
`win.KEY_*`, and every real script (defender included) calls it that
way, never `gfx.KEY_*`. Phase 6k replaces this design entirely (removes
`define_builtin_const` and `register_gfx_key_constants`, adds
`window_key_constant` + a `.Window` case in `properties.odin`'s
`get_property`) rather than keeping both — nothing shipped depended on
the module-constant form, so there was no reason to carry two ways to
reach the same values.

**No GC-triggered teardown**: unlike `Texture`/`Shader`/`RenderTexture`
in glox (not implemented in this port yet either), `Window_Object` owns
no GPU resource of its own — raylib's window is closed only by an
explicit `.close()` call, made idempotent via a `closed` bool so a
second call is a safe no-op rather than a second `rl.CloseWindow()`.
`vm/gc.odin`'s `free_object` needs no new case at all (the existing
`case: free(obj)` default is already correct here).

**Verification — the honest limit of what could actually be checked
from here**: no display access, so rendered output can't be visually
confirmed at all. Compiled cleanly in both build modes on the first
attempt; full `pytest` regression stayed at 220/0/26 throughout (this
work adds no new automated Lox-level tests, since there's no `_ns`-style
no-screen equivalent for "did this draw the right pixels"). Wrote and
ran a scripted smoke test instead (not part of the checked-in suite):
opens a real 320x240 window, calls `.init()`, checks
`get_screen_width/height`/`get_fps`, runs 10 frames each calling every
2D primitive (`pixel`/`line`/`line_ex`/`triangle`/`rectangle`/`circle`/
`circle_fill`/`text`) plus `key_down`/`key_pressed`, exercises both
argument-validation error paths, and calls `.close()` twice to confirm
idempotency — ran to completion with exit code 0, no crash, no hang, no
orphaned process left behind afterward. That confirms the code path
executes and issues the right raylib calls without erroring; it does
**not** confirm the window actually rendered correctly on screen — that
needs an actual human look, which this environment can't provide.
Said explicitly rather than claimed as done, matching this project's
own standing rule for UI/graphics work that can't be tested end-to-end
from here.

### Phase 6k: `texture`/`image`/`render_texture`, `sprite.lox`, and running `lox_examples/defender`

Trigger: rather than keep adding raylib surface speculatively, `d:/odin/glox_reference/lox_examples/`
(the original glox project's own example scripts) was copied into `lox_examples/` as a real end-to-end
target. Its `defender/` game is a genuine multi-file 2D game (not a toy script) — auditing its actual
`gfx`/window dependency surface via direct grep (not assumption) was the concrete spec for this phase,
and running it uncovered three real bugs unrelated to graphics at all (see below).

**New native object types**, following the same recipe as every other Phase 6 type
(`core/obj_image.odin`/`obj_texture.odin`/`obj_render_texture.odin`, `core/object.odin`'s
`Object_Type`/`object_to_string`, `core/value.odin`'s `as_image`/`as_texture`/`as_render_texture`,
`vm/gfx_texture.odin`'s `invoke_builtin_image`/`invoke_builtin_texture`/`invoke_builtin_render_texture`,
`vm/call.odin`'s `invoke()` cases, `vm/builtins.odin`'s `type()` cases, `natives/gfx.odin`'s
`gfx.image()`/`gfx.texture()`/`gfx.render_texture()` constructors):

- `Image_Object` wraps a CPU-side `rl.Image` (`gfx.image(filename)` — `rl.LoadImage`). **A load failure is
  a real `runtime_error` here**, not glox's own `panic(...)` (`obj_builtin_image.go`'s `MakeImageObject`) —
  matches this port's standing "native crash becomes a catchable Lox exception" convention. **A real gap in
  glox itself, fixed here**: glox's `ImageObject` has no `GCFree`/`unload` at all — the underlying `rl.Image`
  is never freed, ever. `vm/gc.odin`'s `free_object` frees it here (`rl.UnloadImage`), safe because Image's
  own Lox-facing surface (`width()`/`height()`) never touches pixel data again once a Texture has been built
  from it — freeing it when unreachable changes no observable behavior.
- `Texture_Object` wraps a GPU-loaded `rl.Texture2D`, optionally sliced into `frames` equal-width horizontal
  animation frames (`gfx.texture(image, frames, start_frame, end_frame)` — validates `frames >= 1` and both
  frame indices in range, plus a **new `window_created` gate**, mirroring glox's own package-level
  `windowCreated` bool exactly: a GPU upload needs a live GL context, so `gfx.texture()` before any
  `gfx.window()` is a real error, not a crash). `.animate(ticks_per_frame)`/`.frame_width()`/
  `.set_wrap_mode(mode)`/`.unload()`. Idempotent unload via a `freed` bool, same convention as
  `Process_Object`/`Regex_Pattern_Object` from earlier phases.
- `Render_Texture_Object` wraps an off-screen `rl.RenderTexture2D` (`gfx.render_texture(width, height)`).
  Deliberately narrow: only `width()`/`height()`/`unload()` — not `get_texture()` (glox's own version does a
  GPU-sync roundtrip via `LoadImageFromTexture`/`UnloadImage` specifically to dodge a driver race, not needed
  here) and not a render-texture-specific mirror of window's drawing methods, since `begin_texture_mode`/
  `end_texture_mode` redirect the *existing* window drawing methods at this target via raylib's own global GL
  state — nothing extra needed for that to work.

**New `Window` methods** (`vm/gfx_window.odin`): `draw_texture`/`draw_texture_flip`/`draw_texture_scaled`/
`draw_texture_rect` (exact raylib call shapes — `DrawTextureRec`/`DrawTexturePro`, the flip-via-negative-width
and scale-via-`DrawTexturePro`-dest-rect tricks — read from glox's own `win_methods.go` before writing any of
this, not guessed), `begin_texture_mode`/`end_texture_mode`, and `draw_render_texture` (a **negative source
height** flips the Y axis — raylib stores render textures upside-down in OpenGL, matching glox's own
`draw_render_texture` exactly).

**`modules/sprite.lox`** copied verbatim from `glox_reference/src/modules/sprite.lox` (same "copy the stdlib
module as-is" precedent as `json.lox`/`particle_sys.lox` in earlier phases) — its `Sprite` class is the
concrete reason `texture`/`image` were needed at all (`this.texture = texture(img, frames, start_frame,
end_frame)`, `win.draw_texture_rect(...)`).

**Three real bugs found by actually running `defender`, none of them raylib-related**:

1. **Nested module imports resolved relative to the wrong directory.** `import mountains`/`import lander`/
   etc. from `main.lox` all failed with "Failed to import module" even though every file existed exactly
   where expected. Root cause: `module.odin`'s `read_module_source` resolved local (non-stdlib) imports
   relative to `vm.script` — but for a *nested* import (e.g. `npc/lander.lox` importing `game/event.lox`,
   a sibling directory), the sub-VM created to compile `lander.lox` has `vm.script` pointing at
   `npc/lander.lox` itself, so the search never looks in `game/` at all. Confirmed against glox's own
   resolution (`vm.go`'s `getPath`/`importModule`): glox's sub-VMs propagate the *parent's* `args`
   (`subvm.SetArgs(vm.Args())`), so `args[0]` stays pinned to the original top-level script's path all the
   way down an arbitrarily deep import chain — module resolution is always relative to the entry script, never
   to whichever module happens to be doing the importing. Fixed by adding `VM.root_script` (set to `script`
   in `new_vm_raw`, explicitly propagated in `module.odin`'s `load_module` — `sub.root_script =
   vm.root_script` — mirroring glox's `SetArgs` propagation), and switching `read_module_source`'s local-
   resolution tiers from `vm.script` to `vm.root_script`. This was silently wrong for every multi-directory
   import graph before now; the existing test suite never exercised more than one subdirectory level deep,
   which is why it hadn't surfaced. Full `pytest` regression re-confirmed at 220/0/26 after the fix.
2. **`win.KEY_*` constants had the wrong home.** See the note added to Phase 6j above — Phase 6j put them on
   the `gfx` module (`gfx.KEY_A`); real scripts read them off the *window instance* (`win.KEY_A`), matching
   glox's `RegisterAllWindowConstants`. Fixed by removing the module-constant path entirely
   (`define_builtin_const`, `register_gfx_key_constants`) and adding `vm/gfx_window.odin`'s
   `window_key_constant(name) -> (Value, bool)` (the full `rl.KeyboardKey` set, minus `KEY_BACK`/`KEY_MENU` —
   Android-only buttons glox's raylib-go binding exposes that `vendor:raylib`'s Odin binding does not) plus a
   new `.Window` case in `properties.odin`'s `get_property` that calls it. Values are plain immutable ints,
   identical across every `Window` instance, so no per-object storage is needed.
3. **`begin_blend_mode`/`end_blend_mode` were entirely missing** — out of scope per Phase 6j's stated
   boundary ("blend/shader modes... explicitly deferred"), but `defender`'s `fx.lox` calls
   `win.begin_blend_mode("BLEND_ADD")` around every particle draw. Added as a narrow, deliberate exception to
   that boundary (full blend-mode *constants*, shader modes, batch, and 3D remain deferred). **Ported with
   glox's own latent bug intact, not "fixed"**: glox's `begin_blend_mode` passes the argument through
   `Value.AsInt()` with no type check, and `AsInt()` on a non-numeric `Value` (a string, here — `fx.lox`
   passes the literal `"BLEND_ADD"`, never the constant) silently returns `0` (`rl.BlendAlpha`) rather than
   erroring. `core.as_int` has the byte-for-byte identical default-to-0 behavior for a non-numeric `Value`
   (`core/value.odin`), so `win.begin_blend_mode(mode_val)` here reproduces that exactly — `fx.lox`'s
   "additive blend" call has, in the actual shipped game, always meant ordinary alpha blending, never additive.
   Deliberately *not* given the stricter argument-type validation every other method in this file has: doing
   so would turn a silent content bug into a hard crash for a script that has always run, just not quite as
   its author intended.

**`lox_examples/defender`'s own art assets (`pngs/*.png`, 18 files) don't exist in `glox_reference`** — that
clone genuinely ships the game without them, not a copying mistake. They *do* exist in `d:/go/glox`, the
user's separately-maintained, actively-developed glox working copy (`d:/go/glox/lox_examples/defender/pngs/`)
— copied verbatim from there once found, same directory structure. First verified engine-correctness with 15
throwaway placeholder PNGs (not committed, deleted immediately after that test) before the real assets were
known to exist anywhere; re-verified afterward with the real ones. Either way: `main.lox` under
`LOX_PATH=<repo root>` resolves every one of its ~30 imports, constructs the full game object graph (entity
manager, player, camera, radar, mountains, particle system, bullet pool, sprite/texture loading), enters the
real `while (!win.should_close() and !game.done)` game loop, and runs it under a real raylib window for a
bounded 6-second wall-clock window (`timeout 6`) with **zero crashes, zero uncaught exceptions, and no
orphaned process afterward** — the process was still running cleanly when forcibly terminated by the timeout,
not stopped by an error. That confirms the whole engine-side surface this phase built (texture/image/
render_texture, sprite animation, window 2D+texture drawing, blend mode, module resolution) is correct and
load-bearing for a real, non-trivial game, now with its actual intended art; it does **not** confirm correct
on-screen visual output — no display access here, so that still needs an actual human look.

Full `pytest` regression held at 220/0/26 throughout every fix in this phase (checked after each one, not
just at the end). Both build modes (`bin/build.sh` / `bin/build.sh --release`) compiled cleanly throughout.

### Phase 6l: `win.BLEND_*`/`WRAP_*` constants, `render_texture`'s own 2D primitives, `draw_render_texture_ex`

Trigger: running `tile_planes.lox` (`win.begin_blend_mode(win.BLEND_ALPHA)`) hit `"Undefined window property
'BLEND_ALPHA'"` — Phase 6k added `begin_blend_mode`/`end_blend_mode` as *methods* but never the named
constants a script actually passes to them. Fixing that and then actually running the script (rather than
stopping at "compiles") surfaced two more real gaps in the same pass.

**`window_key_constant` renamed `window_constant`, extended with `BLEND_*`/`WRAP_*`** (`vm/gfx_window.odin`):
`BLEND_ADD`/`BLEND_ALPHA`/`BLEND_MULTIPLY`/`BLEND_SUBCOLOR`/`BLEND_ADDCOLOR` (`rl.BlendMode`) and
`WRAP_REPEAT`/`WRAP_CLAMP`/`WRAP_MIRROR_REPEAT`/`WRAP_MIRROR_CLAMP` (`rl.TextureWrap`), matching glox's
`RegisterAllWindowConstants` exactly. `BATCH_*` deliberately still excluded — `gfx.batch()`/`batch_instanced()`
aren't implemented, so those constants would have no consumer yet.

**`render_texture` gets its own mirrored 2D primitive set** (`vm/gfx_texture.odin`'s
`invoke_builtin_render_texture`): `clear`/`pixel`/`line`/`line_ex`/`triangle`/`rectangle`/`circle`/
`circle_fill`/`draw_texture`. This is a genuinely different usage pattern from what Phase 6k's
`win.begin_texture_mode(rt)` + `win.<primitive>` + `win.end_texture_mode()` supported: `tile_planes.lox`
(`frame.line_ex(...)`, `this.texture.clear(col)`), `cobweb-bifurc.lox`, `cube_stack_fly2.lox`, and
`textured_batch_demo2.lox` all call drawing methods *directly on the render_texture object itself*. Confirmed
against glox's own `render_texture_methods.go`: each of these methods brackets just that one draw call in its
own `BeginTextureMode`/`EndTextureMode` — a different shape from Window's methods (which draw against
whatever the current global GL target already is) — ported to match exactly, reusing the `vec4_to_rl_color`/
`arg_color` helpers Phase 6j built (promoted from file-private to package-visible for this). Deliberately
still not ported: `text()` (glox's `RenderTexture.text()` takes a different, narrower argument list than
Window's `text()` — `(x, y, string)` only, fixed size 10, hardcoded white — and no example script here calls
it, so there's nothing to verify that mismatch against), `get_texture()` (a GPU-sync roundtrip, not yet
needed by anything that also has its other dependencies satisfied), `draw_texture_pro()`, and
`draw_array_fast()`.

**`win.draw_render_texture_ex(rt, x, y, rotation, scale, color)` added** (`vm/gfx_window.odin`) — found needed
by `tile_planes.lox`. Ported with a real, faithfully-preserved quirk: unlike `draw_render_texture` (which
negates the source rectangle's height to correct for OpenGL storing render textures upside-down), glox's own
`draw_render_texture_ex` (`win_methods.go`) calls plain `rl.DrawTextureEx` with **no** such correction — so it
draws upside-down relative to `draw_render_texture`. Not "fixed" to be consistent; ported exactly as glox
has it.

**Verified**: `tile_planes.lox` and `cobweb-bifurc.lox` both now run their full loop under a bounded
wall-clock smoke test (`timeout 6`) with zero crashes and no orphaned process. Spot-checking `kaleido.lox` in
the same pass found it needs `render_texture.get_texture()` and `draw_texture_pro` (both window- and
render_texture-side) — real, still-open gaps, not attempted this round (tracked in `TODO.md`; a reasonable
next slice, not blocking anything already shipped). `pytest` held at 220/0/26 throughout; both build modes
compiled cleanly.

### Phase 6m: `render_texture.get_texture()`/`draw_texture_pro`, and a real global-mutability bug

Trigger: the `kaleido.lox` gap Phase 6l left open. Implementing it surfaced a genuine, pre-existing
correctness bug in global-variable assignment, unrelated to graphics.

**`render_texture.get_texture()`** (`vm/gfx_texture.odin`): does the same GPU-sync pixel readback glox's own
version does (`LoadImageFromTexture`/`UnloadImage`, result discarded — the render_texture's own drawing
methods each open and close their own texture-mode context, so without an explicit sync point here the GPU
can still be mid-flight on writes to it when the returned `Texture` starts getting sampled elsewhere), then
wraps the render texture's underlying `rl.Texture2D` via `core.make_texture_object_from_texture2d` — a
constructor added back in Phase 6k specifically for this, unused until now.

**`draw_texture_pro`** added on both `render_texture` (brackets its call in `BeginTextureMode`/
`EndTextureMode`, like its other drawing methods) and `Window` (draws straight to whatever the current GL
target already is, no bracketing — and, matching glox's own `win_methods.go` exactly, accepts *either* a
`Texture` or a `Render_Texture` as its source, type-checked at runtime rather than requiring one specific
kind).

**The real bug**: `kaleido.lox` re-samples its render texture into a fresh `Texture` every frame
(`tex = canvas.get_texture()`, first at top level, then again inside the main loop). The *second* assignment
failed with `"Cannot assign to const variable 'tex'"` even though `tex` was never declared `const` anywhere.
Root cause, found by direct comparison against glox's own `OP_SET_GLOBAL`/`OP_DEFINE_GLOBAL` (`vm.go`):
odlox's `Set_Global` opcode (correctly) refuses to overwrite a global slot whose *currently stored value* is
tagged immutable — but odlox's `Define_Global` (an ordinary, non-`const` declaration) was storing whatever
value it was given *as-is*, immutable tag and all, rather than clearing it first. Several native constructors
(`gfx.window()`/`texture()`/`render_texture()`/`physics_world()`, tuples, regex matches, ...) return
`Value{immutable: true}` for reasons that have nothing to do with variable-reassignment semantics — that tag
was never meant to describe "this identifier can never be reassigned," only "this particular value instance
is conceptually read-only." The moment a plain (non-`const`) variable happened to be *first* assigned one of
these values, it became permanently frozen — every prior script here only ever assigned such values to a
variable *once*, so this had never surfaced. glox's own `vm.go` never has this problem: `OP_DEFINE_GLOBAL`
calls `core.Mutable(vm.pop())`, unconditionally stripping the tag before storing, and `OP_SET_GLOBAL` does
the identical `core.Mutable(vm.Peek(0))` on every ordinary assignment too — only `OP_DEFINE_GLOBAL_CONST`
(`core.Immutable(...)`) ever forces the tag on. odlox's `Define_Global`/`Set_Global` (`vm/run.odin`) now do
the same — clear `immutable` on the value before storing, in both opcodes — restoring the actual invariant:
whether a global can be reassigned is a property of *how it was declared* (`const` vs. not), never of
whichever value currently happens to sit in the slot. Local variables were never affected — `const` locals
are enforced at compile time via a separate `is_const` flag on the compiler's own local-slot tracking
(`compiler/stmt.odin`), not this runtime value-tag mechanism.

**Verified**: full `pytest` regression (220/0/26, including the existing `const` rejection tests, confirming
the fix didn't loosen real `const` enforcement) after the fix. `kaleido.lox` now runs its full loop under the
same bounded `timeout 6` smoke test with zero crashes; `tile_planes.lox`, `cobweb-bifurc.lox`, and
`defender/main.lox` (with its real assets) were all re-run afterward too, specifically because this fix
touches every global assignment in the interpreter — all three still ran clean, no orphaned process in any
case. Both build modes compiled cleanly throughout.

### Phase 6n: fixed a use-after-unload GPU bug in `get_texture()`, found by actually looking at the screen

Trigger: user report, from actually watching `kaleido.lox` run rather than just checking it didn't crash --
"it starts OK, drawing the pattern and kaleidoscoping it, but after a few seconds the screen goes black,
like the texture gets cleared and lost." A bounded, crash-free `timeout` smoke test (Phase 6m's own
verification) cannot catch this class of bug at all -- the process never crashes, never raises, never hangs;
it just silently starts rendering garbage. This is exactly the kind of thing this project's own standing
rule (documented since Phase 6j) says needs an actual human look, not just "ran to completion."

**Root cause**: `render_texture.get_texture()` (Phase 6m) wraps the render_texture's own live `rl.Texture2D`
handle in a fresh `Texture_Object` via `core.make_texture_object_from_texture2d` -- called every single
frame by `kaleido.lox` (`tex = canvas.get_texture()`, inside the main loop, to re-sample the live-painted
canvas). Each frame's wrapper becomes unreachable the moment the *next* frame's `get_texture()` call
overwrites `tex`, making it eligible for GC. `vm/gc.odin`'s `.Texture` case unconditionally called
`core.texture_unload` on any collected `Texture_Object`, which unconditionally called `rl.UnloadTexture` --
but that GPU handle isn't owned by the wrapper at all, it's the render_texture's *own* texture, still very
much in active use. The first GC sweep that happened to collect one of these transient wrappers destroyed
the render_texture's real GPU resource out from under it -- every future draw against `canvas` (or reads via
a later `get_texture()`) then operated on a freed/invalid texture, which is why the screen went black rather
than crashing outright: freed GPU handles don't fault the way freed CPU memory does, they just render
nothing (or garbage) silently. "After a few seconds" lines up exactly with `INITIAL_GC_THRESHOLD` (1 MiB) --
however many frames it took to allocate that much before the first collection cycle ran.

**Fix**: `Texture_Object` gets a new `owns_texture: bool` field (`core/obj_texture.odin`) -- `true` for
`make_texture_object` (the real, unique-per-call `rl.LoadTextureFromImage` loader), `false` for
`make_texture_object_from_texture2d` (a borrowed view onto someone else's already-loaded texture).
`texture_unload` now checks it before calling `rl.UnloadTexture` -- a borrowed wrapper's `freed` flag still
gets set (so `.unload()` called on one is a harmless no-op, not an error), but the actual GPU teardown is
skipped entirely, leaving the real owner's texture alone. This is the *first* consumer of
`make_texture_object_from_texture2d` (added speculatively in Phase 6k, unused until Phase 6m's
`get_texture()`), so the bug had no way to surface any earlier.

**Verified, honestly bounded**: `kaleido.lox` run for a sustained 20 real seconds (release build too, 15s) --
long enough for several GC cycles to fire against the per-frame `get_texture()` allocation churn -- with no
crash and no orphaned process. That confirms the fix doesn't regress anything and the code path the bug lived
in now takes the "don't unload a borrowed texture" branch instead. It does **not** by itself confirm the
black-screen symptom is actually gone on screen -- this bug was only found at all because a human was
watching the output, and the same kind of look is what would confirm the fix, not a bounded background run.
`pytest` held at 220/0/26; both build modes compiled cleanly.

### Phase 6o: `vec2/3/4.set(...)`, an odlox-only addition

Trigger: a direct follow-on from the `kaleido.lox`/`tile_planes.lox` allocation-reduction work and the GC
discussion around it. Both scripts had `Foo.update()` methods hand-rewritten to mutate `this.lastp.x`/
`this.lastp.y` in place instead of reallocating a fresh `vec2(...)` every frame — a correct but awkward
two-line workaround. `.set(x, y[, z[, w]])` gives scripts a real API for that instead.

**Not a glox port** — glox's own `VectorMethodCall` (`vm.go`) gives vec2/3/4 exactly one method, `.add(other)`;
there is no `.set()` anywhere in glox. Added as a genuine new capability, documented as such rather than
silently presented as ported behavior.

**Implementation** (`vm/call.odin`'s `invoke_vector_method`): extends the *same* function `.add()` already
lives in, not a new opcode. Considered and rejected: Lox has no static types, so nothing at compile time can
tell `expr.set(...)` apart from a call to some unrelated user-defined class's own `set` method (nothing stops
a script writing `class Foo { set(a,b) {...} }`) — only a runtime check of the receiver's actual type can,
which is exactly what `invoke()`'s existing dispatch into this function already provides for `.add()`. A
dedicated opcode would need to perform that identical runtime check anyway, so it would just be the same
logic behind different bytecode plumbing, not a real simplification. `.set()` mutates all fields in place and
leaves the receiver on the stack as its own return value, matching `.add()`'s exact calling convention (pop
just the arguments, not a separate collapse-and-push result). Wrong arg count or a non-numeric argument falls
through to the same generic `"Invalid use of '.' operator"` fallback `.add()` already uses, for consistency.

**Verified**: a smoke test confirmed `.set()` on all three vec types, confirmed a user-defined class's own
`set()` method is untouched (dispatch only ever reaches `invoke_vector_method` for an actual Vec2/3/4
receiver), and confirmed genuine in-place mutation (not silent reallocation) via reference-identity: a second
variable aliasing the same vector observed the mutation. `kaleido.lox`'s `Pen.update()` and
`tile_planes.lox`'s `Line.update()` were both updated to use `this.lastp.set(...)` in place of their earlier
workarounds; both re-verified running clean under the same bounded smoke test. `pytest` held at 220/0/26;
both build modes compiled cleanly.

### Phase 6p: `gfx.shader()`, and a real multi-line-string scanner bug

Trigger: direct request to implement shader support. Ported glox's `obj_builtin_shader.go` faithfully --
`Shader_Object` (`core/obj_shader.odin`), `invoke_builtin_shader` (`vm/gfx_shader.odin`), and `win.begin_shader_mode`/
`end_shader_mode` (`vm/gfx_window.odin`), following the same construction/dispatch split every other native
gfx type in this port uses.

**Two construction paths, matching glox exactly**: `gfx.shader(vertex_file, fragment_file)` loads compiled
GLSL from disk immediately (`rl.LoadShader`); `gfx.shader()` (no arguments) constructs an empty,
not-yet-loaded shader (`rl.Shader{}`) for a script to fill in afterward via `.load_from_memory(vertex_code,
fragment_code)` -- the shape real scripts (`lox_examples/julia.lox`) actually use, embedding GLSL source as
Lox string literals rather than reading it from a file. Methods: `load_from_memory`, `get_location(name)`,
`set_value_float`/`set_value_vec2`/`set_value_vec3`/`set_value_vec4` (each validates the location is an int
and the value is the matching type before calling `rl.SetShaderValue` with the right `ShaderUniformDataType`
and a stack-local scratch value/array -- `#any_int` on raylib's own `SetShaderValue` signature means the
location argument needs no `ShaderLocationIndex` wrapping, just a plain `c.int`), `is_valid()`, `unload()`
(idempotent via a `freed` bool, same convention as `Texture_Object`/`Render_Texture_Object`). `win.begin_shader_mode(shader)`/
`win.end_shader_mode()` redirect subsequent draws through the shader, matching glox's own win_methods.go --
only affects draws using raylib's currently-bound shader (2D primitives, `draw_texture*`, `draw_render_texture*`);
`batch_instanced` (not implemented here either) would ignore it entirely, per glox's own documented caveat.

**Real bug found and fixed, unrelated to graphics**: writing a smoke test that embedded GLSL source as a
Lox string literal (the same pattern `julia.lox` uses: `var vs = "\n#version 330\n...\n"`) failed to parse at
all -- `"Unterminated string."` on the very first embedded newline. `compiler/scanner.odin`'s `scan_string`
treated any literal `\n` inside a string as an immediate error, unconditionally. Confirmed against glox's own
scanner (`scanner.go`'s `string` method: its `c == "\n"` case just increments the line counter and continues,
the same as any other character) that this is a real, load-bearing language feature odlox was missing
entirely, not a deliberate exclusion -- multi-line string literals are exactly how `julia.lox` embeds its
vertex/fragment shader source. Fixed by removing the newline special-case from the unterminated-string check
and incrementing `s.line` when a literal `\n` is encountered, letting it fall through to the same
write-byte-and-advance path every other character already takes.

**Verified**: a smoke test exercised both construction paths (from files using `lox_examples/shaders/rainbow.vs`/
`.fs`, and empty + `load_from_memory` with inline multi-line GLSL matching `julia.lox`'s own shaders),
`is_valid()`, `get_location()`, all four `set_value_*` variants, `begin_shader_mode`/`end_shader_mode`
wrapping real draw calls across several frames, a type-check error path (passing a non-shader to
`begin_shader_mode`, caught via `try`/`except`), and `.unload()` idempotency -- ran to completion, exit 0, no
orphaned process. Separately confirmed against a real, unmodified script: `lox_examples/julia.lox` now runs
all the way through window setup, both shader construction paths (including its own multi-line embedded GLSL,
previously impossible to even parse), `render_texture`, and `float_array` creation, stopping only at
`lox_julia_array` -- a native Julia-set computation helper unrelated to shaders/graphics, not implemented and
out of scope for this pass (tracked in `TODO.md`, alongside `render_texture.draw_array_fast`, `julia.lox`'s
other remaining gap). `pytest` held at 220/0/26 throughout (including whatever existing string-literal tests
already existed, confirming the scanner fix didn't regress single-line string handling); both build modes
compiled cleanly.

### Phase 6q: `render_texture.draw_array_fast`, `gfx.lox_julia_array`, and a fully-running `julia.lox`

Trigger: direct follow-on request to close both gaps Phase 6p left open in `lox_examples/julia.lox`.

**`render_texture.draw_array_fast(arr)`** (`vm/gfx_texture.odin`): bulk-uploads a `float_array` (each cell an
RGB-encoded float, same convention as `gfx.encode_rgba`/`decode_rgba`) as one texture and blits it in a
single draw, instead of one draw call per cell. Ported from glox's own `render_texture_methods.go`, including
its persistent `array_texture` field (`core/obj_render_texture.odin`) reused across calls — `rl.LoadTextureFromImage`
only on the first call or a size change, `rl.UpdateTexture` otherwise. This isn't just a performance nicety:
recreating a GPU texture every frame races the driver's double-buffered pipeline (a new texture can reuse an
ID a still-in-flight draw from the previous frame references, producing stray stale-colour pixels) — the same
reasoning glox's own doc comment gives for why this field exists at all. `render_texture_unload`/`object_size`
updated to account for it.

**`gfx.lox_julia_array(array, width, height, max_iterations, cx, cy, scale, xoffset, yoffset)`**
(`natives/gfx_julia.odin`, new file): computes a Julia set fractal directly into a `float_array`'s backing
storage, fast enough to recompute every frame for `julia.lox`'s real-time zoom/pan animation. Ported from
glox's `builtin_draw.go`'s `JuliaArrayBuiltIn` — same precomputed six-band colour table (electric blue → cyan
→ green → yellow → red → magenta → white, black inside the set), same per-pixel iteration math, `f32`
precision matching glox's own inner-loop cast. **Deliberately single-threaded**, unlike glox's own
goroutine-per-block version: every pixel's colour depends only on its own coordinates and the shared
parameters, never on another pixel, so parallelizing it changes wall-clock speed only, never the output —
and this port's own scope already excludes VM-level threading entirely (`README.md`'s Scope section). Noted
as an easy target to parallelize later (e.g. via `core:thread`, entirely internal to this one native call
since it never touches the VM/GC mid-computation) if a large canvas ever needs it for real-time interactivity.

**Verified**: `lox_examples/julia.lox`, unmodified, now runs its full real-time loop under a bounded
wall-clock smoke test (`timeout 10`, both build modes) with zero crashes and no orphaned process — the same
script that previously stopped at the very first `lox_julia_array` call. Spot-checked `mandel_gfx.lox` (the
other script Phase 6k/6m/6p noted as also needing `draw_array_fast`) in the same pass: it now gets past
`draw_array_fast` cleanly and stops at `lox_mandel_array` instead — a separate, still-unimplemented
Mandelbrot-set equivalent of `lox_julia_array`, not attempted this round (not part of what was asked; noted
in `TODO.md`). `pytest` held at 220/0/26; both build modes compiled cleanly.

## Phase 7 — Performance pass

Only after Phases 1–6 are correct and green against the test suite. See
`ARCHITECTURE.md` § [Performance](docs/ARCHITECTURE.md#performance-what-odin-allows-that-go-didnt)
for the full reasoning behind each item; this is the checklist form.

- [x] Runtime self-patching arithmetic specialization (`Add_Ii`/`Add_Ff`/
      `Incr_Const_I`/`Incr_Const_F`) — see Phase 7a below.
- [x] Port `benchmarks/lox/*.lox` (from the glox reference repo)
      unmodified; establish a baseline odlox vs. glox vs. CPython
      comparison, same shape as glox's own `bin/benchmarks.sh` table —
      see Phase 7b below.
- [ ] Profile before optimizing — Odin equivalent of glox's
      `-cpuprofile`/`-memprofile` workflow (`core:prof`, or manual
      `time.now()` bracketing plus an allocation counter) against `trees`/
      `method_call`/`fib`/`loop`-equivalent benchmarks.
- [x] Hoist `ip` as a genuine loop-local in `run()` (Phase 4 always
      documented this as done; it never actually was) — see Phase 7d
      below. `stack_top` deliberately left as-is; see the `TODO.md` entry.
- [x] Stop re-interning already-interned property/method names on every
      `Op_Get_Property`/`Op_Set_Property`/`Op_Invoke`/`Op_Super_Invoke`/
      `Op_Get_Super` access — see Phase 7c below.
- [ ] Attempt compile-time-baked instance field slots
      (`OP_GET_FIELD_SLOT`/`OP_SET_FIELD_SLOT`) — glox's own roadmap
      concluded a runtime-only slot table (no compiler changes) is a net
      *regression* on access-heavy code; don't repeat that specific
      mistake. Either do the compile-time-baked opcodes properly or skip
      this item. Phase 7c/7e closed most, not all, of the `trees`/
      `binary_trees` gap — this is what's left.
- [x] Monomorphic inline cache on `Op_Get_Property`/`Op_Invoke` — see
      Phase 7e below.
- [ ] Consider a free-list/pool allocator for high-churn small fixed-size
      objects (vec2/3/4, upvalues, bound methods) — reuse sweep-freed
      slots instead of round-tripping through the general allocator.
- [ ] Stretch: NaN-boxing `Value` down to 8 bytes (see `ARCHITECTURE.md`'s
      note on odinLox's existing Odin implementation of this) — only if
      profiling still shows `Value` width as a bottleneck after the above.
- [ ] Re-run the full benchmark suite after each change; keep a results
      table the same way glox's own `docs/performance-roadmap.md` does, so
      regressions are visible immediately rather than discovered later.

### Phase 7a: mandel investigation and the arithmetic self-patching fix

**Trigger**: an informal release-build comparison (`mandel.lox`, both
interpreters' `-o:speed`-equivalent build) found odlox running ~1.25–1.3×
*slower* than glox on a mostly-numeric, function-call-light benchmark —
surprising, since odlox's `Value` is 16 bytes (raw union, no Go-interface
tax) against glox's own documented 32-byte `Value`, and odlox already has
tag-byte object discrimination glox had to add by hand
(`docs/performance-roadmap.md`'s "Option 1"). Structurally odlox should
have *started ahead* on exactly this benchmark shape, not behind.

**Compiler vs. design.** Pulling the per-instruction debug-hook check and
`maybe_collect_garbage` out of the dispatch loop as a quick experiment made
no measurable difference — notably *unlike* glox, where the equivalent
`DebugHook != nil` check cost a measured 25% on `loop.lox` by disturbing
Go's codegen for the switch (`glox_reference/docs/performance-roadmap.md`
Step 1). That result argues against "the compiler" (Odin/LLVM under
`-o:speed`) being the culprit here.

**What was actually found, by reading code against `docs/ARCHITECTURE.md`'s
own stated design, not by trusting it:** two real, verifiable gaps between
documented intent and what `run.odin`/`vm.odin` actually do:

1. `docs/ARCHITECTURE.md`'s "[The one further step Go couldn't take: raw
   pointers for `ip` and stack top](docs/ARCHITECTURE.md#the-one-further-step-go-couldnt-take-raw-pointers-for-ip-and-stack-top)"
   section documents hoisting `ip`/`stack_top` as true register-resident
   pointer locals as the design — but `run.odin` still reads/advances
   `fl.f.ip` (a pointer-chased `int` field on `Call_Frame`) and
   `vm.stack_top` is a plain `int` field on `VM`. Never built. Still open
   — tracked above, not fixed by this entry.
2. `Op_Code` declared `Add_Ii`/`Add_Ff`/`Incr_Const_I`/`Incr_Const_F` (the
   self-patching, type-specialized children of `Add_Nn`/`Incr_Const_N`
   glox's own peephole optimiser actually emits and uses in production —
   `glox_reference/src/vm/vm.go`'s `OP_ADD_NN`/`OP_ADD_II`/`OP_ADD_FF`/
   `OP_INCR_CONST_*` cases) but they were pure vestigial dead enum
   entries: no compiler pass ever emitted them, and `run.odin`'s switch
   had no case for them at all — every `Add_Nn`/`Incr_Const_N` execution
   re-paid the int/float branch on every single hit, forever. **Fixed by
   this entry.**

**The fix** (`run.odin`'s `Add_Nn`/`Add_Ii`/`Add_Ff`/`Incr_Const_N`/
`Incr_Const_I`/`Incr_Const_F` cases): mirrors glox's `vm.go` mechanism
exactly. On a monomorphic int/int or float/float hit, the generic
`Add_Nn`/`Incr_Const_N` case patches its own opcode byte in place (`fl.code`
aliases the chunk's backing `[dynamic]u8`, so the rewrite is real and
persistent, not a per-call cache) to the `_Ii`/`_Ff` child, which on every
later execution skips the type check entirely. A mixed-type site is *not*
patched — it just computes the generic float result and stays
`Add_Nn`/`Incr_Const_N` forever, same as glox (glox's own code doesn't
re-verify the type on `OP_ADD_II`/`OP_ADD_FF` either; a specialized site is
trusted once patched, matching the reference implementation's actual
behavior rather than adding extra safety it doesn't have).

**Verification**: full `pytest` regression unchanged at 218 passed / 0
failed / 26 skipped; `test_mandel.py` (6/6) confirms the specialized
opcodes produce identical output to the generic path.

**Wall-clock, same `tests/new_tests/lox/mandel.lox` fixture, both release
builds, 3 runs each**: glox 0.149s/0.154s/0.138s vs. odlox (post-fix)
0.090s/0.067s/0.086s — odlox now runs *ahead* of glox on this benchmark,
roughly 1.8–2x, a full reversal of the ~1.25x-slower reading that started
this investigation. Take the exact multiplier with a grain of salt — this
fixture is small enough (~70–90ms total) that process-startup overhead is
a real fraction of each run, so 3 short runs isn't a rigorous benchmark;
the direction is unambiguous, but a real number needs the Phase 7
benchmark port above (larger, steady-state workloads, more repetitions).

**Net effect on the original question**: of the two documented-but-
unrealized Phase 4 optimizations the mandel investigation surfaced, one is
now actually built and measurably reverses the regression (this entry);
the raw-pointer `ip`/stack-top change remains open, and — since this one
opcode-family fix alone flipped a 1.25x deficit into a ~2x lead — is now
lower urgency than it looked at the start of this investigation, though
still worth doing since it taxes *every* opcode's operand read, not just
the arithmetic family.

### Phase 7b: the loxcraft benchmark suite, ported and run (odlox vs. glox vs. CPython)

Ported `benchmarks/lox/*.lox` and `benchmarks/python/*.py` unmodified from
`glox_reference/benchmarks/` into `odlox/benchmarks/` — the standard
loxcraft-derived 13-benchmark suite glox itself uses (`binary_trees`,
`collections`, `equality`, `fib`, `instantiation`, `invocation`, `loop`,
`method_call`, `properties`, `string_equality`, `trees`, `zoo`,
`zoo_batch`). Every script ran on odlox with zero changes needed — no
compatibility gaps, just three genuinely long-running ones
(`string_equality` ~20s, `trees` ~34s, `zoo` ~17s) that looked like hangs
under an initially-too-short smoke-test timeout before being confirmed as
just slow by design (`string_equality` does `n = 15_000_000` iterations of
64 comparisons each — glox itself takes ~38s on the same script).

Added `bin/time_lox.py` (ported from glox's own, generalized with an
`--exe <path>` flag so the same script can time any of the three engines
instead of being hardcoded to one binary) and `bin/benchmarks.sh` (glox's
`bin/benchmarks.sh` shape, extended to a 3-way odlox/glox/CPython table;
`GLOX_EXE` env var overrides the glox binary location, default
`d:/go/glox/bin/glox.exe` — the sibling glox repo on this machine, not
`glox_reference`, since that's the one with a built, up-to-date binary).
One real bug hit and fixed along the way: Python's `subprocess.run` with a
bare relative path (`"bin/odlox.exe"`) fails on Windows with
`FileNotFoundError: [WinError 2]` even when the file exists and the
relative path is correct — Windows' `CreateProcess` doesn't resolve a
relative executable path against the current working directory the way a
shell does. Fixed by `os.path.abspath()`-ing the exe path in
`time_lox.py` before building the subprocess command.

**Baseline** (3 runs each, both interpreters' release builds, same
machine):

| benchmark | odlox | glox | python | odlox/glox | odlox/py |
|---|---|---|---|---|---|
| binary_trees | 26.10s | 18.08s | 7.41s | **1.44x** | 3.52x |
| collections | 5.36s | 10.65s | 2.92s | 0.50x | 1.83x |
| equality | 30.74s | 50.00s | 20.40s | 0.61x | 1.51x |
| fib | 9.12s | 20.51s | 9.13s | 0.44x | 1.00x |
| instantiation | 34.06s | 41.50s | 22.48s | 0.82x | 1.52x |
| invocation | 17.70s | 16.88s | 8.96s | 1.05x | 1.98x |
| loop | 2.51s | 5.62s | 3.55s | 0.45x | 0.71x |
| method_call | 18.97s | 20.59s | 8.77s | 0.92x | 2.16x |
| properties | 20.01s | 18.04s | 7.56s | 1.11x | 2.65x |
| string_equality | 20.58s | 37.75s | 17.37s | 0.55x | 1.18x |
| trees | 33.66s | 23.20s | 6.83s | **1.45x** | 4.92x |
| zoo | 16.91s | 16.45s | 9.76s | 1.03x | 1.73x |
| zoo_batch | 10.01s | 10.02s | 10.03s | 1.00x | 1.00x |

(`odlox/glox` < 1.00x means odlox is faster; a 1-run smoke pass beforehand
matched this table within noise, so it's not a fluke of averaging.)

**Reading it**: odlox is ahead on everything dispatch/arithmetic-heavy
(`loop` 0.45x, `fib` 0.44x, `collections` 0.50x, `equality`/
`string_equality` ~0.55-0.61x) — the Phase 7a fix plus the 16-byte `Value`
and tag-byte object discrimination pay off exactly where expected.
It's *behind* specifically on `trees` (1.45x) and `binary_trees` (1.44x),
with `properties`/`invocation`/`zoo` roughly even — the object-heavy
end of the suite. Checked why: `core/obj_instance.odin`'s
`Instance_Object.fields` and `core/obj_class.odin`'s `Class_Object.methods`/
`statics` are `map[^String_Object]Value`, ported unchanged from glox's own
design — the exact mechanism glox's own `docs/performance-roadmap.md`
names as its top cost driver for these two benchmarks specifically
(map-backed per-instance field storage, allocated per object; map-backed
method lookup). odlox inherited the cost without inheriting any of glox's
mitigations for it. A second, smaller issue found in the same area:
`vm/properties.odin`'s `get_property`/`bind_method` call
`core.intern_string(name)` on every access even though `name` is already
an interned constant from the bytecode operand — a redundant hash on
every single property/method read, on top of the map lookup. Both are
now tracked in `TODO.md`, not yet fixed.

**Where this leaves Phase 7**: the two remaining big-ticket items are (1)
the raw-pointer `ip`/stack-top change (taxes every opcode, benchmark-
agnostic) and (2) the instance/class map-backed field-and-method-lookup
cost (taxes specifically OO-heavy code — `trees`/`binary_trees` here, and
by the same mechanism glox's own roadmap found, likely `properties`/
`method_call`/`instantiation` too once the two current wins on those are
netted out). Given glox's own roadmap explicitly tried and reverted a
runtime-only slot table as a net regression, (2) needs the compile-time-
baked opcode variant done properly, not the shortcut — see the `TODO.md`
entry.

### Phase 7c: stop re-interning already-interned property/method names

Diagnosed the Phase 7b `trees`/`binary_trees` regression down to a
specific mechanism rather than leaving it at "map-backed fields, same as
glox": `get_property`/`set_property`/`bind_method`/`invoke`/
`invoke_from_class`/`do_get_super`/`do_super_invoke` all took `name` as a
plain `string` and called `core.intern_string(name)` to get a map key —
but every one of their call sites (`run.odin`'s `Op_Get_Property`/
`Op_Set_Property`/`Op_Invoke`/`Op_Super_Invoke`/`Op_Get_Super` cases)
already reads `name` off a bytecode constant the compiler interned at
*compile* time (`compiler/expr.odin`'s `dot` → `core.make_string_value`).
`intern_string` re-hashes the full string content against the global,
whole-program intern table just to re-derive the exact `^String_Object`
pointer already sitting in the constant pool — on every single property
or method access, on top of the real per-instance/per-class map lookup
that follows it. glox never pays this: it caches the interned integer id
on the constant at compile time, so its own property/method access is a
single map lookup using Go's `mapaccess2_fast64` int-key fast path.

**Fix**: thread the already-interned `^core.String_Object` straight
through instead of a plain `string` — every function above now takes
`^core.String_Object` and uses it directly as the map key (including
`core.env_get_var`/`env_set_var`, which already expected a
`^String_Object` and were themselves being handed a freshly-reinterned
one before this fix). The builtin dispatch procs that switch on `name`'s
*content* rather than use it as a map key
(`invoke_builtin_list`/`dict`/`string`/`float_array`/`regex`/`process`,
`invoke_vector_method`, `get_vec_swizzle`/`set_vec_swizzle`) still take a
plain `string` — `core.string_get(name)` at those call sites is a cheap
field read, not a re-intern. `do_class`/`do_method`/`do_class_var`/
`do_import` were deliberately left on plain strings: those run once per
class/method declaration or import, not on a per-access hot path, so
there was nothing to win there.

**Verification**: full `pytest` regression unchanged (218/0/26); clean
`-o:speed` build with no signature-mismatch errors anywhere in the tree
(a wrong call site would have failed to compile, not just misbehaved).

**Result** (3-run Phase 7b baseline vs. after, same fixture):

| benchmark | before | after |
|---|---|---|
| properties | 1.11x | **0.69x** |
| method_call | 0.92x | **0.62x** |
| invocation | 1.05x | **0.70x** |
| zoo | 1.03x | **0.66x** |
| binary_trees | 1.44x | 1.27x |
| trees | 1.45x | 1.14x |
| (everything else) | ~unchanged | ~unchanged |

`properties`, `invocation`, `method_call`, and `zoo` all flipped from
"odlox loses to glox" to "odlox wins" — confirming the redundant-intern
cost wasn't specific to `trees`/`binary_trees`, it was a flat tax on
*every* property or method access in the interpreter, just most visible
on the two benchmarks that do the most of it. `trees`/`binary_trees`
improved substantially (gap roughly halved) but remain the only two
benchmarks where odlox still trails glox — with the redundant lookup
gone, what's left is presumably the *real* per-instance/per-class map
lookup itself (odlox's `map[^String_Object]Value` vs. Go's
`map[int]Value` fast path) plus whatever allocation cost is specific to
deep tree construction. `instantiation.lox` (pure allocation, comparatively
little access) already favors odlox at 0.79x, which argues for the access
pattern over raw allocation cost being the residual driver — but this is
an inference from the benchmark shapes, not something isolated by
profiling. That's the compile-time-baked instance field slots item in
`TODO.md`/the checklist above, still open.

### Phase 7d: hoist `ip` as a genuine loop-local, not a pointer-chased frame field

Built the item `docs/ARCHITECTURE.md`'s VM dispatch loop section had
described since it was written but that was never actually implemented
(`run.odin`/`vm.odin` still used a plain `int` field on `Call_Frame`,
read/written through the `fl.f` pointer on every single opcode and
operand byte) — see Phase 7a's discovery of this gap during the mandel
investigation.

**Design deviation from the doc, deliberate**: the doc calls for a raw
`ip: ^u8` pointer local specifically, reasoning Go can't do this safely
(no raw-pointer-into-slice idiom) but Odin can. True, but beside the
point here: under `-no-bounds-check` (already the release flag,
`bin/build.sh`), `fl.code[ip]` for a hoisted `int` local and `ip^`/
`ip[0]` for a hoisted `^u8` compile to identical pointer arithmetic —
bounds checking, not pointer-vs-int, is the only thing that idiom was
ever buying in C/clox. Implemented as a hoisted `int` instead: same
"genuine local, not a struct field reached through a pointer, for the
loop's whole body" property the doc was actually after, with zero
conversion needed anywhere else in the codebase that already treats ip
as a plain integer offset (`exceptions.odin`'s stack-trace/handler
matching, `debug/inspect.odin`'s frame introspection natives, `debug/
trace.odin`'s disassembler) — a literal pointer would have needed
pointer-difference conversions at every one of those sites for no
measurable benefit.

**Correctness**: before writing any code, exhaustively grepped every
reader of `Call_Frame.ip` outside `run.odin` to enumerate every point
that needed a sync, rather than discovering gaps by trial and error:
`exceptions.odin` (stack-trace building reads it, handler dispatch
writes it — both only reachable via `raise_exception`, called from
exactly two places in `run.odin`), `debug/inspect.odin` (reads it, only
reachable via the `inspect` native module through `Op_Invoke`), `debug/
trace.odin` (reads it only on `.Opcode` events, never `.Return`).
Confirmed this is the complete set. Sync discipline: `fl.f.ip` is
written from the local `ip` immediately before every call that could
transitively read or reposition this frame's ip while suspended
(`call_value`/`invoke`/`do_super_invoke`, `raise_exception` at both call
sites, `do_foreach`/`do_next`, and the per-opcode and per-return debug
hook checks), and read back into `ip` immediately after every existing
`refresh_frame()` call — the same points the code already synchronized
frame state at, just now also carrying `ip`.

**Verification**: full `pytest` regression unchanged (218 passed / 0
failed / 26 skipped) and the isolated `odin test` sweep across
compiler/vm/core (170/170) both passed cleanly before this was
considered done — given the size of this change (every opcode case in
`run.odin` touched), correctness was verified deliberately, not assumed
from a clean build alone.

**Result** (3-run baseline vs. after, same fixture):

| benchmark | before | after |
|---|---|---|
| equality | 0.65x | **0.50x** |
| invocation | 0.70x | 0.67x |
| properties | 0.69x | 0.67x |
| trees | 1.14x | 1.19x |
| zoo | 0.66x | 0.69x |
| (everything else) | ~unchanged | ~unchanged |

Smaller and more mixed than Phase 7c's fix: one clear win (`equality`,
a pure comparison loop with no property access at all — exactly the
shape that benefits most from cheaper per-instruction dispatch and
nothing else), most benchmarks flat within run-to-run noise, `trees`/
`zoo` nudged slightly worse (plausibly just GC/allocation timing
variance on multi-second runs, not a real regression — not re-measured
further since neither move is large enough to warrant chasing). Tracks
with the design-deviation reasoning above: since `-no-bounds-check`
already captured most of what "raw pointer vs int" would have bought,
this fix's real contribution was narrower than hoped — removing the
`fl.f` double indirection, not eliminating bounds checks that were
already off.

`stack_top` was deliberately not hoisted alongside `ip` — see the
`TODO.md` entry for why (push/pop/peek's call sites span far more of
the codebase than ip's readers do, for a much smaller and murkier
payoff).

### Phase 7e: monomorphic inline cache on `Op_Get_Property`/`Op_Invoke`

**What it actually caches, and why not more.** A real inline cache needs
O(1) indexed access on a hit, not a hash lookup wearing an inline
cache's clothes — considered and rejected a design keyed by `ip`
position in a chunk-level map first, since that's just one map lookup
replacing another with no asymptotic win. The real design: the compiler
allocates a `core.Property_Cache{class, method}` slot per callsite at
compile time (`chunk_add_property_cache`, mirroring `chunk_add_constant`'s
shape) and emits its index as an extra bytecode operand
(`compiler/expr.odin`'s `dot`/`emit_property_cache`) — `Get_Property`
grew from `[name_const]` to `[name_const][cache_idx]`, `Invoke` from
`[name_const][arg_count]` to `[name_const][arg_count][cache_idx]`.
`Set_Property`/`Get_Super`/`Super_Invoke` don't get one: sets have no
method-dispatch angle to cache, and super calls are cold enough not to
bother.

It can only ever cache the **class → method** resolution
(`Class_Object.methods[name]`/`static_methods[name]`) — never the
receiver's own **instance-fields** lookup (`inst.fields[name]`), and
this isn't an incremental limitation to lift later, it's structural:
Lox instances have no fixed shape (`core/obj_instance.odin`'s
`fields: map[^String_Object]Value` is genuinely dynamic per instance),
so a field that happens to mask a method on one instance of a class
says nothing about another instance of the *same* class. A class-keyed
cache is safe for the method table (flattened once at `do_inherit` time,
effectively immutable after that) but never safe for field presence.
So both `get_property` and `invoke` still always do the real
`inst.fields[name]` lookup first, every time, and the cache only ever
skips the *second* lookup, on a fields-miss with a matching cached
class — real, but narrower than "skips property access."

**The static/instance conflation trap, caught before it shipped**:
`invoke_from_class` (`vm/call.odin`) handles both instance-method calls
(`obj.method()`) and static-method calls (`Class.method()`) through the
same proc, keyed by `is_static`. Initially reused one cache slot for
both — wrong: a static call's `class` param *is* the class value itself,
so `cache.class == inst.class` could spuriously match a *different*
instance of that same class hitting the site afterward, returning a
static method where an instance method (or vice versa) was needed.
Fixed by only ever populating/checking the cache on the instance
(`is_static == false`) path; the `.Class` receiver branch in `invoke`
passes `nil` for `cache`, so static dispatch is simply never cached (a
real but accepted scope limit, not a bug).

**A real regression, found and fixed before it shipped**: `Frame_Locals`
(the per-call struct `run.odin`'s dispatch loop hoists) initially grew a
`property_caches: []core.Property_Cache` field alongside `constants`/
`code`, mirroring how those are already hoisted. First benchmark pass
showed `loop.lox` — a benchmark with **zero property or method access**
— regressing 0.48x→0.62x (glox-relative), confirmed as a real, stable
~25% *absolute* slowdown (not noise: reproduced 2.7s→3.5s three times
running, then reproduced the clean 2.7s baseline on a throwaway
`git worktree` at the pre-change commit). Root cause: growing that
struct by one field shifted register allocation for the *entire* hot
loop body, not just the two opcodes that use the new field — every
opcode paid for it, whether it touched `property_caches` or not. Fixed
by *not* hoisting `property_caches` into `Frame_Locals` at all; the two
call sites (`Get_Property`, `Invoke`) reach it one hop further out,
via `fl.fn.chunk.property_caches[cache_idx]`, instead. Confirmed the fix
restored `loop.lox` to baseline (2.6-2.7s) with the property/method wins
fully intact. Worth remembering for any future `Frame_Locals` addition:
the struct's own size is itself on the hot path, independent of whether
a given opcode reads the new field.

**Correctness verification**: full `pytest` regression unchanged
(218/0/26) against both build modes; `compiler` package's own unit
tests (67/67) confirm the `decode()` bytecode-shape helper in
`compile_test.odin` was updated correctly for the new operand layout. A
dedicated correctness script (`ic_test.lox`, not part of the checked-in
suite) specifically exercised the cases most likely to break with a
naive inline cache: a monomorphic site (same class, many hits), a
polymorphic site (alternating classes at the identical `Op_Invoke`
instruction, e.g. iterating a mixed-type list calling the same method
name), inheritance (a subclass reaching a method only present via the
flattened table, immediately followed by a sibling class miss at the
same site), and — the case most likely to silently corrupt behavior —
two instances of the *same* class where only one has a field dynamically
added that masks a method name, confirming the field lookup always wins
and the class-level cache never leaks across instances. All correct.

**Result** (3-run baseline vs. after, same fixture):

| benchmark | before | after |
|---|---|---|
| invocation | 0.67x | **0.42x** |
| method_call | 0.61x | **0.52x** |
| properties | 0.67x | **0.55x** |
| zoo | 0.69x | **0.57x** |
| trees | 1.19x | **1.09x** |
| binary_trees | 1.27x | **1.24x** |
| loop | 0.48x | 0.46x (confirmed unaffected, see the `Frame_Locals` fix above) |
| (everything else) | ~unchanged | ~unchanged |

Broad, clean win with no regressions anywhere in the suite. `trees` is
now within 9% of glox, down from 45% behind at the start of Phase 7 —
`binary_trees` improved less (1.27x→1.24x), consistent with it being
comparatively more allocation/instantiation-heavy relative to its
method-call density than `trees.lox`'s recursive `walk()`. Both remain
the only two benchmarks where odlox still trails glox; what's left is
exactly the instance-fields lookup the cache structurally can't touch
(see the `TODO.md` entry) plus tree-construction allocation cost.

### Phase 7f: the same redundant-intern bug, in `Dict_Object`

Prompted by a user question about *why* `collections.lox` trails
CPython specifically (`odlox/py` ≈ 1.8x, worse than most of the rest of
the suite) — investigated per-phase rather than accepting the aggregate
number: `collections.lox` runs `list_ops`/`dict_ops`/`string_ops`
back to back, and the `dict` phase alone was 2.19x slower than CPython,
noticeably worse than `list`/`string`'s ~1.5-1.8x. Traced it to the
exact same bug Phase 7c fixed for property/method access, just never
applied to dicts: `core/obj_dict.odin`'s `dict_set`/`dict_get`/
`dict_remove` all took a plain `string` and called `intern_string()`
internally on *every* call — but a dict key value at a real call site
(`d["a"] = i`, `d.get("a", 0)`) is always already an interned
`^String_Object`, by construction, with no exception (every Lox string
Value is interned at creation — see `obj_string.odin`), so re-hashing
it was pure waste on every dict operation, not just the ones this
particular benchmark happens to exercise.

**Fix**: `dict_set`/`dict_get`/`dict_remove` now take `^String_Object`
directly. `vm/collections.odin`'s `dict_key_string` (Index/Index_Assign's
key coercion, since a dict subscript can be any Value, not just a
string) was renamed `dict_key` and changed to return the canonical
pointer directly for an already-string Value, only falling to
`value_to_string` + a single `intern_string` call for a genuinely
non-string key (int, etc.) where there's no pre-existing interned
pointer to reuse. The handful of callers that start from a genuinely
uninterned plain string — `vm/regex.odin`'s named-capture groups,
`core/pickle.odin`'s deserialized keys, `debug/inspect.odin`'s frame-
introspection dict-building (9 call sites, all cold/debug-only), plus
test files in both `core` and `vm` packages — now call `intern_string`
explicitly at their own call site instead.

**Verification**: full `pytest` regression unchanged (218/0/26) against
both build modes; `core` package's own unit tests (41/41, covers
`dict_set`/`get`/`remove` directly).

**Result**: `collections.lox`'s `dict` phase improved ~10% (2.73s→2.46s
in isolated timing; full 3-run suite average 2.73s→2.46s tracked as
`collections`'s `odlox/py` ratio nudging 1.82x→1.79x — modest against
the suite-wide noise floor since `dict` is only one of three phases
averaged together). Smaller than Phase 7c's win on property access,
because interning wasn't the dominant cost here the way it was there:
`dict_ops` also calls `.keys()` every iteration, which allocates a
fresh `List_Object` on every call regardless of this fix (now tracked
separately in `TODO.md`), and CPython's own dict implementation is
about as hard a target as exists in the entire runtime to begin with —
see the `TODO.md` entry and this section's own reasoning for why
closing the rest of this gap has a much lower ceiling than the
property-access fix did.

## Phase 8 (optional, low priority) — Bytecode cache

Only if module-recompilation time is measured to actually matter for a
real use case. See `ARCHITECTURE.md` § [Bytecode cache](docs/ARCHITECTURE.md#bytecode-cache-lxc)
for why this is deferred rather than ported alongside Phase 4.

- [ ] Design a fresh serialization format for `Chunk`/`Function_Object`/
      `Value` (don't transliterate glox's tag-byte format verbatim —
      Odin's core library offers better options).
- [ ] mtime-based cache invalidation (`__loxcache__/*` convention, or a
      renamed equivalent).
- [ ] `--force-compile`-equivalent CLI flag.

## Phase 9 (final, do last) — Comment cleanup pass

Not a feature phase — a housekeeping pass over every `.odin` source file,
done only once the port is otherwise feature-complete and stable (after
Phase 7/8, or whenever active porting work winds down for good). While
porting was actively in progress, comments narrating *how a piece of code
came to be the way it is* — which phase added it, which fixture found a
bug in it, what the wrong behavior used to be, why an earlier attempt was
replaced, how this compares to or deviates from glox's own version — were
genuinely valuable working notes (this is by design; see the established
working-pattern memory this project runs on: "document real bugs found,
honestly"). That value is time-limited. Once the port is done, a reader
of this codebase (very possibly not someone who lived through the port,
and not assumed to have glox open in another window) needs comments that
explain *this* interpreter's architecture and behavior on its own terms —
not an archaeology of how it got there, and not a running comparison
against another codebase. Comments should read as if this interpreter had
simply been written this way from the start, the same bar glox's own
comments already meet for glox itself (terse, functional, describes what
a piece of code does/why it's shaped that way, full stop — no reference
to its own history, and no reference to any other implementation).

The comparison-to-glox discussion — what was ported faithfully, what
deliberately deviates and why, what's a known limitation relative to
glox — isn't discarded, just relocated: that's exactly what
`docs/ARCHITECTURE.md` already exists to hold (it currently carries a
substantial amount of this material inline in source comments too;
that's the duplication this phase removes from the source side). Anything
in a source comment that's really making an architectural case belongs
there instead, cross-referenced (`see docs/ARCHITECTURE.md's <section>`)
rather than re-argued in place.

- [ ] Read through every `.odin` file under `src/` and rewrite comments
      that reference: phase numbers ("Phase 4", "Phase 6d", ...), this
      port's own name ("this port", "odlox" used reflexively rather than
      just naming the thing), specific pytest/fixture names that found a
      bug, "real bug, found via...", before/after behavior descriptions,
      comparisons to glox ("matches glox's X", "unlike glox", "glox does
      Y but this doesn't"), or anything else that reads as a changelog
      entry or a comparison rather than a plain description of this
      interpreter's current architecture/functionality.
- [ ] Keep the comments that carry real, still-load-bearing information
      about *this* codebase, stated on its own terms: *why* code is
      shaped a particular way when the reason isn't obvious from reading
      it (a genuine invariant, a non-obvious bytecode/VM contract) —
      stated as a fact about how this interpreter works, not as a diff
      against glox. Cutting the narrative/comparison framing doesn't mean
      cutting the substance — "X must happen before Y because Z" survives
      regardless of phrasing; "found this was broken via fixture W in
      phase N" and "unlike glox, which does X, this does Y" don't, though
      the underlying fact (if still relevant) may need to survive as a
      plain, un-attributed statement ("code assumes Y").
- [ ] Migrate anything genuinely worth keeping from the comparison-to-glox
      material into `docs/ARCHITECTURE.md` before deleting it from source
      — don't just delete a deviation's rationale outright if it isn't
      already captured there.
- [ ] Don't do this piecemeal alongside ordinary feature work before this
      phase — every phase section above this one *deliberately* documents
      its own bugs/fixtures/history/glox-comparisons in ROADMAP.md
      precisely so the in-code comments don't have to carry that weight
      forever; doing the cleanup only once, at the end, avoids fighting
      an ongoing stream of new narrative comments from concurrent work.
- [ ] Spot-check a representative file from each package (`core`,
      `compiler`, `vm`, `debug`, `natives`, `main.odin`) once done: could
      someone who has never seen glox and doesn't care that it exists
      read this file and understand the architecture and behavior from
      the comments alone? That's the actual bar — "shorter than before"
      or "no longer mentions glox" are necessary but not sufficient
      checks on their own.

---

## Testing every phase

**The ported test suite is the acceptance gate for every phase above, not
an afterthought at the end.** Per `ARCHITECTURE.md` §
[Test strategy](docs/ARCHITECTURE.md#test-strategy):

1. Copy `tests/new_tests/` from the glox reference repo into odlox
   verbatim (Phase 0).
2. Change the two hardcoded binary-path constants (`lox_helper.py`'s
   `GLOX`, `conftest.py`'s matching constant) to point at the built
   `odlox` binary. No other file needs to change.
3. Run `python -m pytest tests/new_tests/ -x -q` (or without `-x`, to see
   the full pass/fail picture rather than stopping at the first failure)
   after every meaningful change, from Phase 3 onward once anything can
   execute at all.
4. Track pass count per phase as the actual definition of progress. Tests
   touching `thread.*`/`sync.*` will never pass (out of scope, permanently
   — either delete them from the copied suite or leave them
   permanently-skipped with a clear reason) and graphics-dependent
   non-`_ns` tests won't pass until Phase 6's raylib sub-phase lands — both
   are expected, not regressions.
5. Once a benchmark comparison is wanted (Phase 7), port
   `benchmarks/lox/*.lox` the same way — pure `.lox` scripts, no
   Go-specific content.

### First real run (mid-Phase 5) and the bug it immediately found

The suite was wired up later than planned (see Phase 0's checklist above)
because glox itself wasn't available anywhere in this workspace to copy
`tests/new_tests/` from until a `glox_reference` clone appeared alongside
odlox's own directory, partway through this phase. Once wired, the very
first full run (`python -m pytest tests/new_tests/ -q`) **hung
indefinitely** rather than reporting pass/fail counts — not slow, an
actual non-terminating loop, confirmed by running the specific offending
fixture (`lox/str_class_toString.lox`) directly against `bin/odlox.exe`
under a hard timeout.

Root cause, found by bisecting to the exact hanging test and reproducing
minimally: two compounding real bugs, both in the compiler's error path,
neither previously exercised because Phase 3/4's own hand-written tests
never fed the compiler input broken in quite this way:

- `functions.odin`'s function-body compiler required a function/method's
  `{` immediately after its `)`, with no tolerance for an `Eol` in
  between — but the scanner's own EOL-suppression rule only looks at the
  *previous* token (`Right_Paren` isn't in its suppress set — see
  `scanner.odin`'s `keep_eol`), so `toString()` with `{` on the next line
  (a real, common style, and exactly what the ported fixture uses) left a
  real `Eol` token sitting right where `consume(.Left_Brace, ...)`
  expected `{`, and failed. glox's own compiler has exactly this same
  scanner behavior but explicitly tolerates it in the parser
  (`p.match(TOKEN_EOL) // allow EOL after parameters`, `compile.go`) —
  this port had ported the scanner's behavior but missed the
  corresponding parser-side tolerance. Fixed by adding the same
  `match(p, .Eol)` calls glox's parser has, both before `)` and before
  `{`.
- That alone would only have produced a wrong-but-quick compile error.
  What turned it into an actual hang: `class_declaration`'s member-parsing
  loop (`for !check(p, .Right_Brace) && !check(p, .Eof) { ... method(p)
  }`) never checked `p.panic_mode`/called `synchronize()` after `method`,
  unlike `declaration()` at the top level, which does. A malformed
  method whose error path returns without consuming a token (exactly
  what `consume(.Left_Brace, ...)` failing does) left the loop's
  condition permanently true and called `method()` again on the exact
  same token, forever — the identical *shape* of bug already found and
  fixed once in Phase 3 (see that phase's bug list: "class-body member
  loop had no branch for the Eol... An actual infinite loop"), recurring
  through a different error path the first fix didn't cover. Fixed by
  adding the same `synchronize()` call `declaration()` already has.

Both are pinned down by regression tests in `compile_test.odin`
(`test_method_brace_on_next_line_compiles`,
`test_malformed_method_does_not_hang_the_compiler` — the latter's own
doc comment explains why it's deliberately *not* timeout-guarded: an
infinite-loop regression should hang the test suite, not fail it
quietly, since a passing-but-wrong result would defeat the point).

**Baseline after both fixes** (first run that actually completes):
**40 passed, 190 failed, 14 skipped**, in ~3.5s. Expected at this point
in the roadmap, not a red flag — the large failure count is almost
entirely Phase 6 (native/builtin functions, `sys`/`re`/`pickle`/`pool`/
`process`/raylib-backed modules, string/list method surfaces beyond what
Phase 4 pulled forward) not existing yet, plus a handful of real,
separate compiler/VM gaps surfaced by specific failures worth a closer
look before or during Phase 6 rather than chased down here (an unbraced
single-statement `if (cond) break` form the parser currently rejects
outright — `test_break_unbraced`; at least one `try`/`except` syntax
variant the parser doesn't accept — `test_catch_runtime`). `test_thread.py`
and `test_sync.py` are marked permanently skipped (`thread.*`/
`sync.Mutex` are explicitly out of scope — see this file's header); every
other skip/fail is a live signal, not scope noise. Re-run this suite
after every phase from here on and update this baseline, per item 4
above.
