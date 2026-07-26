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
- [ ] Decide and record the Odin build flags for debug vs. release
      (`-debug`, `-vet`, `-strict-style` for dev; `-o:speed
      -disable-assert -no-bounds-check` for a release/benchmark build) —
      mirrors glox's own fast-vs-debug build split
      (`bin/build_debug.sh`/`core.HotLoopDebugHookCompiled`).
- [ ] `git init`-equivalent housekeeping already done (repo exists); add a
      `.gitignore` for build output.
- [ ] Copy `tests/new_tests/` from glox wholesale (see
      [Testing](#testing-every-phase)) — do this early so every later
      phase has an immediate pass/fail signal, not at the end.

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
- [ ] `--print-tokens`/disassembly hooks wired for debugging the compiler
      itself. `--print-tokens` already exists (Phase 1); a real
      bytecode disassembler is Phase 5's job — deferred there rather
      than duplicated early, per the roadmap's original sequencing.
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
- [ ] Error/panic reporting: stack traces with source-line context, using
      `Chunk.lines` for line numbers. **Not built** — errors currently
      just carry a message string (`vm.error_msg`), with no call-stack
      trace attached. A real gap, deferred alongside Phase 5's debug
      tooling since a proper trace wants the disassembler infrastructure
      that phase builds anyway.
- [x] CLI flags: `--repl`, `--print-tokens` (kept from Phase 1), file
      execution as the default. `--compile-only`/`--debug`/`--info`/
      `--no-peephole` **not wired to CLI flags yet** (`DebugSkipPeephole`
      exists as a package variable, toggled directly by tests, but
      nothing exposes it on the command line) — deferred to Phase 5
      alongside the debug hooks those flags would actually control.

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

- [ ] `disassemble`/`disassemble_instruction` — one case per opcode,
      byte/jump/constant operand formatting.
- [ ] Execution trace hook (stack dump + disassembled instruction per
      step) and instrument hook (instruction counter), gated the same way
      glox gates its hot-loop hook: compiled out of the release build,
      available in a debug build. Decide upfront whether Odin's `when`
      compile-time conditionals are enough here (likely yes — no need for
      glox's shell-script-mediated uncomment/recomment dance, since Odin
      can gate the hook call behind a compile-time constant directly).

## Phase 6 — Native/builtin functions & standard library

Port `src/vm/builtin.go` (core builtins) first, then `src/builtin/*.go`
(raylib-backed, much larger) as a distinct sub-phase. See `ARCHITECTURE.md`
§ [Native/builtin functions](docs/ARCHITECTURE.md#nativebuiltin-functions).

- [ ] Core builtins: `len`, `type`, `append`, `range`, `rand`, `sys.*`,
      basic `os.*` (file open/read/write/close), string/list/dict method
      tables (package-level, shared — port the already-fixed
      shared-method-table design, not the earlier per-instance-map one).
- [ ] Exception class hierarchy via embedded-Lox-source bootstrap
      (`Exception`, `RunTimeError`, `EOFError`, ...) — compile-and-harvest
      through a disposable sub-VM, not hand-built object graphs.
- [ ] `natives` package skeleton + registration hook wired from
      `main.odin` (see `ARCHITECTURE.md`'s `VMContext` note — this is
      where the dependency-inversion decision actually gets exercised).
- [ ] Raylib-backed natives: window/2D drawing first (smallest surface,
      most test coverage via `_ns`-paired tests can validate the non-
      graphics logic before graphics itself is wired up), then
      texture/shader/batch/camera/render_texture/image/physics_world.
- [ ] `float_array`, `vec2`/`vec3`/`vec4` methods beyond basic arithmetic.
- [ ] `regexp`, `pickle`, `process` modules — lowest priority; add only if
      the target use case needs them.
- [ ] `colour_utils`, other small utility modules.

## Phase 7 — Performance pass

Only after Phases 1–6 are correct and green against the test suite. See
`ARCHITECTURE.md` § [Performance](docs/ARCHITECTURE.md#performance-what-odin-allows-that-go-didnt)
for the full reasoning behind each item; this is the checklist form.

- [ ] Port `benchmarks/lox/*.lox` (from the glox reference repo)
      unmodified; establish a baseline odlox vs. glox vs. CPython
      comparison, same shape as glox's own `bin/benchmarks.sh` table.
- [ ] Profile before optimizing — Odin equivalent of glox's
      `-cpuprofile`/`-memprofile` workflow (`core:prof`, or manual
      `time.now()` bracketing plus an allocation counter) against `trees`/
      `method_call`/`fib`/`loop`-equivalent benchmarks.
- [ ] Confirm the raw-pointer `ip`/stack-top change (Phase 4) actually
      measures as a win; it's a real clox-parity change but should still
      be verified, not assumed.
- [ ] Attempt compile-time-baked instance field slots
      (`OP_GET_FIELD_SLOT`/`OP_SET_FIELD_SLOT`) — glox's own roadmap
      concluded a runtime-only slot table (no compiler changes) is a net
      *regression* on access-heavy code; don't repeat that specific
      mistake. Either do the compile-time-baked opcodes properly or skip
      this item.
- [ ] Consider a monomorphic inline cache on `OP_GET_PROPERTY`/
      `OP_INVOKE` (class-id → slot/method), complementary to the above.
- [ ] Consider a free-list/pool allocator for high-churn small fixed-size
      objects (vec2/3/4, upvalues, bound methods) — reuse sweep-freed
      slots instead of round-tripping through the general allocator.
- [ ] Stretch: NaN-boxing `Value` down to 8 bytes (see `ARCHITECTURE.md`'s
      note on odinLox's existing Odin implementation of this) — only if
      profiling still shows `Value` width as a bottleneck after the above.
- [ ] Re-run the full benchmark suite after each change; keep a results
      table the same way glox's own `docs/performance-roadmap.md` does, so
      regressions are visible immediately rather than discovered later.

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
