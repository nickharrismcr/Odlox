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

- [ ] `Value` struct (16-byte tagged union) — `ARCHITECTURE.md` §
      [Value representation](docs/ARCHITECTURE.md#value-representation).
- [ ] `Obj` base struct + `Object_Type` enum + one concrete struct per
      kind (`String_Object` through `Vec4_Object`) — §
      [Object model](docs/ARCHITECTURE.md#object-model).
- [ ] String interning table (`map[string]^String_Object`, no lock).
- [ ] `Chunk`/opcodes (`Op_Code` enum, `Chunk` struct with
      `code`/`constants`/`lines`/`global_names`) — §
      [Chunk, opcodes, bytecode](docs/ARCHITECTURE.md#chunk-opcodes-bytecode).
- [ ] `Environment` (slot-indexed globals + name-keyed `vars` map, no
      mutex) — § [Environment & globals](docs/ARCHITECTURE.md#environment--globals).
- [ ] `Value` equality/comparison/`to_string` procs (pointer-equality fast
      path for interned strings; **note the deliberate deviation**: give
      lists/dicts real structural equality instead of porting glox's
      stringify-and-compare fallback — flag this explicitly in the PR/
      commit description since it's a behavior change, not just a port).

## Phase 3 — Compiler

Port `src/compiler/compile.go`. This is the largest single phase. See
`ARCHITECTURE.md` § [Compiler](docs/ARCHITECTURE.md#compiler) for the
structures and the load-bearing subtleties.

- [ ] Pratt parser core: `Precedence` enum, `Parse_Rule` table,
      `parse_precedence` driver, recursion-depth guards
      (`expr_depth`/`stmt_depth`) mirroring glox's overflow protection.
- [ ] `Compiler` struct, nested-compiler chaining (`enclosing`), scope
      enter/exit (`begin_scope`/`end_scope` emitting `OP_POP` or
      `OP_CLOSE_UPVALUE` per local as appropriate).
- [ ] Local declaration/resolution (`declare_variable`, `resolve_local`,
      `mark_initialised`, the self-reference-in-own-initializer check).
- [ ] Upvalue capture (`resolve_upvalue`/`add_upvalue`, the clox-style
      recursive climb through enclosing compilers).
- [ ] Global slot assignment (`global_slot`, forward-reference-safe —
      first mention wins, regardless of declare-vs-reference order).
- [ ] Function compilation: `function()` — params (including `*rest`
      variadic and `name = expr` defaults emitting the
      `OP_JUMP_IF_DEFINED` prologue guard), body, `end_compiler`
      (implicit return, peephole pass, `GlobalNames` only on the outermost
      chunk).
- [ ] Peephole optimizer (`peep_hole_optimise`) — the two fusion patterns
      (`ADD_NN`, `INCR_CONST_N`), byte-length-preserving rewrite so
      already-computed jump offsets don't shift.
- [ ] Class compilation: `class`, inheritance (`OP_INHERIT`), `this`/
      `super` resolution, static methods/vars, `init` as
      `Type.Initializer`.
- [ ] Control flow: `if`/`else`, `while`, `for` (out-of-line increment
      trick), `foreach` (3-slot allocation, `OP_FOREACH`/`OP_NEXT`/
      `OP_END_FOREACH`, `Loop.foreach` flag routing `continue` forward
      instead of backward).
- [ ] `break`/`continue`/`return` crossing `try`/`finally` — port the
      `Try_Finally`/`trampoline_site` trampoline design **directly from
      `docs/exception-handling.md`** (in the glox reference repo), not
      re-derived from first principles. This is the single most
      easy-to-get-subtly-wrong part of the whole compiler.
- [ ] Module import compilation (`import`, `from ... import`,
      `from ... import *`).
- [ ] Literals: string/int/float, list/dict/tuple construction, indexing/
      slicing (plain and `_assign` variants), compound assignment
      (`+= -= *= /= %=`) desugaring on locals/globals/upvalues/properties.
- [ ] Destructuring assignment (`a, b, c = expr`) and implicit bare-`x =
      5` declaration.
- [ ] Panic-mode error recovery (`synchronize`) + REPL-specific
      compilation (`Repl_State` persistence across lines).
- [ ] `--print-tokens`/disassembly hooks wired for debugging the compiler
      itself before the VM exists to run anything.

**Milestone check**: at the end of this phase, `odlox --compile-only` (or
equivalent) should accept every `.lox` fixture in the ported test suite
without a compile error, even though nothing can execute yet.

## Phase 4 — VM core + GC

Port `src/vm/vm.go`'s `run()` and `src/vm/gc.go`. See `ARCHITECTURE.md` §§
[VM dispatch loop](docs/ARCHITECTURE.md#vm-dispatch-loop--calling-convention)
and [Garbage collector](docs/ARCHITECTURE.md#garbage-collector).

- [ ] `VM` struct (fixed-size `stack`/`frames` arrays, `frame_count`,
      `stack_top`, `open_upvalues`, `builtins` map, GC bookkeeping).
- [ ] `run()` dispatch loop with hoisted locals + `refresh_frame` —
      **and** the raw-pointer `ip`/stack-top optimization glox's own
      roadmap wanted but couldn't have in Go (§ VM dispatch loop). Get it
      correct with safe indexing first if that's faster to a working
      state; switch to raw pointers once green, since it's meant to be a
      drop-in perf change, not a correctness-affecting one.
- [ ] Full opcode dispatch, opcode-by-opcode — stack/const primitives,
      comparisons, arithmetic (int/float/vector/string paths), the
      self-specializing `ADD_NN→ADD_II/FF` / `INCR_CONST_N→_I/_F` runtime
      opcode-patching family, locals/globals/upvalues, jumps.
- [ ] Function call mechanism: `call_value`/`call` (arity/default/
      variadic shaping — cross-check against
      `docs/plans/default-variadic-params.md` in the glox reference),
      `invoke`/`invoke_from_class`/`invoke_from_builtin`
      (`OP_INVOKE`/`OP_SUPER_INVOKE` fast paths), class-construction via
      `OP_CALL` on a class value, bound-method dispatch.
- [ ] Upvalue capture/closing (`capture_upvalue`, `close_upvalues`,
      open-upvalues list sorted by slot).
- [ ] Property get/set (`OP_GET_PROPERTY`/`OP_SET_PROPERTY`) across
      instance/class/native/module receivers, including vec2/3/4 swizzle
      fields (`.x/.y/.z/.w`, `.r/.g/.b/.a`).
- [ ] Collections: list/dict/tuple construction, indexing, slicing
      (plain + assign), membership (`in`).
- [ ] Foreach/iterator protocol at the VM level: native fast path
      (`Get_Iterator`/`next` with no Lox-call overhead) **and** the
      user-class path (nested re-entrant `run()` call for `__iter__`/
      `__next__`, with the exception-floor-raising detail preserved).
- [ ] Exceptions: `OP_TRY`/`OP_END_TRY`/`OP_EXCEPT`/`OP_END_EXCEPT`/
      `OP_FINALLY`/`OP_RAISE`, `raise_exception`/`next_handler` — **follow
      `docs/exception-handling.md` directly**, including the two documented
      bytecode-adjacency invariants.
- [ ] `OP_STR`/`toString` dispatch (loop-continue re-entry rather than a
      nested call, per glox's actual mechanism).
- [ ] Destructuring (`OP_UNPACK`), breakpoint opcode, "invalid opcode"
      catch-all.
- [ ] GC: `Obj`/intrusive list, `gc_track` (pre-marked-on-link, to survive
      the very cycle that discovers the allocator threshold was crossed),
      `mark_roots`/`mark_object`/`blacken_object`/`sweep`,
      heap-growth-factor threshold (`next_gc = bytes_allocated × 2`).
      **Apply both simplifications from `ARCHITECTURE.md`**: no permanent-
      object sweep exemption (classes/modules/functions are ordinary
      sweepable `Obj`s — no `LiveClasses`/`LiveModules` side-registry), and
      strings as weak-table sweepable objects (a `remove_white`-equivalent
      pass on the intern table between trace and sweep).
- [ ] Module import execution (`import_module`, process-wide cache, no
      mutex) + a fresh nested-VM helper for compiling an imported module.
- [ ] `Interpret` entry point + REPL loop (`main.odin`): "print last value
      unless it's `nil`" behavior, multi-line REPL input buffering
      (balanced-bracket completeness check via a throwaway scanner pass).
- [ ] Error/panic reporting: stack traces with source-line context, using
      `Chunk.lines` for line numbers.
- [ ] CLI flags matching glox's surface where they make sense for this
      port: `--repl`, `--compile-only`, `--debug`/`--info` (trace
      execution), `--no-peephole`. Skip `--force-compile`/cache-related
      flags until/unless Phase 7 happens.

**Milestone check**: the ported test suite (minus thread/graphics-dependent
tests) should be running, with a climbing pass count as opcodes/features
land — not a single "big bang" at the end of this phase. Land VM work
incrementally (e.g. arithmetic + control flow first, classes/exceptions/
foreach after) and re-run the suite after each slice.

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
