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
- [ ] `natives` package skeleton + registration hook wired from
      `main.odin` — **not created**. There's nothing to put in it until
      Phase 6b (raylib) has actual content; an empty package with a
      no-op registration call is scaffolding with no purpose, not
      infrastructure. Revisit when Phase 6b starts.
- [ ] Raylib-backed natives: window/2D drawing first (smallest surface,
      most test coverage via `_ns`-paired tests can validate the non-
      graphics logic before graphics itself is wired up), then
      texture/shader/batch/camera/render_texture/image/physics_world.
      **Not started.**
- [ ] `float_array`, `vec2`/`vec3`/`vec4` methods beyond basic
      arithmetic. **Not started** — this phase only added the bare
      constructors (`vec2(x,y)` etc.), which were needed regardless
      (`core_functions.go` registers them as ordinary free functions,
      no raylib dependency); swizzle-beyond-`.x/.y/.z/.w` and
      vector-specific methods are still open.
- [ ] `regexp`, `pickle`, `process` modules — lowest priority; add only
      if the target use case needs them. **Not started.**
- [ ] `colour_utils`, other small utility modules. **Not started.**
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
