# TODO

Outstanding work only, generated from `ROADMAP.md`'s checklists. This file tracks *what's left*, not
history — completed items are removed here (not checked off), with the full record staying in
`ROADMAP.md` (each phase's own section, including root causes and bugs found, lives there permanently).
When an item below is finished, delete it from this file and (if relevant) check it off in `ROADMAP.md`.

Regenerate/re-sync this list against `ROADMAP.md` if the two drift — `ROADMAP.md` is the source of truth.

## Phase 0 — Project scaffolding

- [ ] `odin test src -all-packages` is still not fully reliable, even with `-define:ODIN_TEST_THREADS=1` (now
      the required invocation for this codebase — see below). Root cause (see `ROADMAP.md`'s Phase 0 section
      for the full writeup): `vm/module.odin`'s `module_cache` holds GC-managed `^core.Module_Object` values
      allocated via the ambient `context.allocator`, which under `odin test` is a short-lived per-task
      allocator recycled between test tasks — the same allocator-lifetime bug already fixed for
      `core/obj_string.odin`'s `intern_table` and `module_source_cache` this session. Fixing `module_cache`
      the same way needs `gc.odin`'s free path reconciled too (its values are freed by GC sweep, unlike
      permanent interned strings), which risks changing production GC behavior for a test-harness-only
      payoff — deliberately left unfixed pending a safer approach. `python -m pytest tests/new_tests/` (the
      project's actual correctness gate) is unaffected throughout.

      **Workaround, now the required way to run this suite**: `bin/test_odin.sh [timeout_seconds]` runs
      `core`/`compiler`/`debug` as batched `odin test <pkg>` invocations, but `vm` one test at a time, each
      its own process (`-define:ODIN_TEST_NAMES=vm.<name>`, names extracted from `src/vm/*_test.odin` at run
      time, not hardcoded) — `natives` has no `@(test)` procs of its own, see `src/natives/README.md`'s
      Testing section. Disabling a single suspect test was tried first and did **not** fix the hang (confirmed
      directly); the root cause is cumulative VM/allocation weight across however many `vm`-package tests
      happen to share one process, not particular tests — see `ROADMAP.md`'s Phase 4 writeup (`vm.test_dict_get_and_set`
      and others were separately found to trigger the identical pattern). One-process-per-test sidesteps the
      accumulation entirely: full run is ~60s, zero hangs, zero timeouts.

      Isolating each `vm` test also surfaced the same root cause's other symptom, silent wrong-value
      corruption instead of a hang, in four tests that each construct 2+ VM instances importing the same
      module within one test function (the process-wide `module_cache` leaking state between them):
      `test_bc_cache_write_then_reimport_hits_cache`, `test_bc_cache_mtime_invalidation_on_source_edit`,
      `test_bc_cache_force_compile_bypasses_read_but_refreshes_write`,
      `test_bc_cache_corrupted_lxc_falls_back_and_self_heals` (all in `src/vm/bc_cache_test.odin`). `@(test)`
      removed from all four, with a comment on each explaining why and how to re-run manually
      (`-define:ODIN_TEST_NAMES=vm.<name>`). Two have real `pytest` equivalents (roundtrip, force-compile);
      **two do not** — mtime invalidation and corrupted-`.lxc` self-heal have no current `tests/new_tests/`
      fixture, a real (if narrow) coverage gap until/unless someone ports them.
- [ ] Always invoke `odin test` for this project with `-define:ODIN_TEST_THREADS=1`. Not a workaround for
      flakiness — the codebase's own design is explicitly single-threaded (`docs/ARCHITECTURE.md`'s Scope
      section; `core/obj_string.odin`'s `intern_string` doc comment), and the test runner's default 16-thread
      parallelism creates a genuine, real data race on unsynchronized global state
      (`core.test_intern_string_returns_canonical_pointer` observed failing intermittently at the default
      thread count once the allocator bug above stopped masking it). The fix is running tests the way this
      VM is actually meant to run, not adding locks to the interpreter's hot path.

## Phase 6 — Native/builtin functions & standard library

- [ ] `process.wait_any()` raises a spurious "truncated message" `ProcessError` under a fire-and-forget
      multi-message pattern (suspected Windows `PeekNamedPipe`/pipe-EOF interaction, not fully root-caused
      — see `ROADMAP.md`'s Phase 6h section). `test_process.py`/`test_pool.py` are skipped at the whole-file
      level pending this. `thread`/`sync` remain permanently out of scope, not tracked here.
- [ ] `pool.lox`'s `ProcessPool` class is blocked on the `process.wait_any()` bug above; its `ThreadPool`
      class is permanently blocked by `thread` being out of scope, so this module can only ever be partially
      ported even once `wait_any` is fixed.
- [ ] `plot_grey.lox`/`plot_rgb.lox` are blocked on `gfx.draw_png(filename, float_array, is_rgb)`
      (`builtin_draw.go` in glox — a `float_array`-to-PNG-file writer, separate from the `image`/`texture`/
      `render_texture` work).

## Phase 7 — Performance pass

**Parked** after Phase 7k (compile-time-baked instance field slots) — all 13 loxcraft benchmarks now beat or
tie glox, including `trees`/`binary_trees` (previously the only two odlox lost on, at 1.09x/1.24x; now 0.84x/
0.87x). Resume from here, not from scratch — every item below is exactly where Phase 7 left off.

- [ ] Field-slot follow-ups explicitly deferred from Phase 7k's v1 scope (`ROADMAP.md`'s Phase 7k section has
      the full design rationale): extending `Property_Cache` to also cache a field-slot index for general
      `expr.field` access from outside the declaring class (today only `this.field` inside the declaring
      class's own methods gets the fast path); a `this.field(...)` (`Invoke`) fast path (only its correctness
      under dual storage is handled today, via `core.instance_get_field`); superclass-slot-table splicing so
      an inherited-but-unoverridden method also hits the fast path against a subclass instance (safe to add
      later without revisiting anything already built, per the `owner_class` guard's own design). None of
      these are required for `trees`/`binary_trees`/`method_call`, which already fully benefit.

Only after Phases 1–6 are correct and green against the test suite.

- [ ] `stack_top` hoist — deliberately not done alongside the `ip` hoist (Phase 7d): `push`/`pop`/`peek` are
      called from a dozen+ files outside `run.odin` (`arithmetic.odin`, `properties.odin`, `call.odin`,
      natives, ...), all reading/writing the canonical `vm.stack_top` field directly; a `run()`-local mirror
      would only help the handful of opcodes handled inline in the switch and need a sync before every
      called-out proc otherwise — much smaller payoff than `ip` got for meaningfully more risk. Revisit only
      if profiling specifically implicates it.
- [ ] `Dict_Object.keys()` (`core/obj_dict.odin`'s `dict_keys`) allocates a fresh `List_Object` on every call,
      even for a dict that hasn't changed since the last call — found via the Phase 7f investigation into why
      `collections.lox`'s `dict` phase still trails CPython after fixing the redundant-intern cost there
      (Phase 7f fixed the hashing cost, not this allocation cost, and `dict_ops` in that benchmark calls
      `.keys()` every iteration). Lower priority than the object-model item above; not investigated further.
- [ ] Free-list/pool allocator for upvalues/bound methods (`docs/plans/done/pool-allocator.md`'s Tier 3) — the
      same per-type intrusive free-list technique that doc's Tier 1/2 used for vec2/3/4, back when vec2/3/4
      were still heap objects; those two tiers were later reverted (`docs/plans/inline-vec-value.md`) once
      vec2/3/4 moved into `Value` directly, so this item stands on its own merits now, not as an extension of
      already-landed work.
- [ ] Stretch: NaN-boxing `Value` down to a single register-width slot — only if profiling still shows `Value`
      width as a bottleneck after the above. A live option again post-inlining, though `Value` is now 40
      bytes rather than 16 (see `docs/ARCHITECTURE.md`'s Value representation section), a wider gap to close.
- [ ] Re-run the full benchmark suite after each change; keep a results table.
