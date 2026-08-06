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

**Parked** after Phase 7f — 11 of 13 loxcraft benchmarks beat or tie glox, the remaining two (`trees`/
`binary_trees`) are within 9-28% instead of 45%; good enough to stop for now and pick up Phase 6b (raylib
bindings, `gfx`/`physics_world`) instead. Resume from here, not from scratch — every item below is exactly
where Phase 7 left off.

Only after Phases 1–6 are correct and green against the test suite.

- [ ] `stack_top` hoist — deliberately not done alongside the `ip` hoist (Phase 7d): `push`/`pop`/`peek` are
      called from a dozen+ files outside `run.odin` (`arithmetic.odin`, `properties.odin`, `call.odin`,
      natives, ...), all reading/writing the canonical `vm.stack_top` field directly; a `run()`-local mirror
      would only help the handful of opcodes handled inline in the switch and need a sync before every
      called-out proc otherwise — much smaller payoff than `ip` got for meaningfully more risk. Revisit only
      if profiling specifically implicates it.
- [ ] Object-model cost (map-backed instance fields/methods, `core/obj_instance.odin`'s
      `fields: map[^String_Object]Value`, `core/obj_class.odin`'s `methods`/`statics` maps) is odlox's last
      remaining relative weak spot. After the redundant-intern fix (Phase 7c) and the monomorphic inline
      cache on `Get_Property`/`Invoke` (Phase 7e), `trees`/`binary_trees` improved from 1.45x/1.44x to
      1.09x/1.24x but remain the only two benchmarks where odlox loses to glox — what's left is the
      **instance-fields lookup itself** (`inst.fields[name]`), which the inline cache structurally cannot
      touch (Lox instances have no fixed shape, so field access can't be cached at the class level the way
      method dispatch can — see core/chunk.odin's `Property_Cache` doc comment), plus whatever allocation
      cost is specific to deep tree construction (`instantiation.lox`, pure allocation with little access,
      already favors odlox at ~0.8x, so it's the access pattern, not raw allocation). Attempt compile-time-
      baked instance field slots (`OP_GET_FIELD_SLOT`/`OP_SET_FIELD_SLOT`) — do it properly or skip it; a
      runtime-only slot table was a net regression in glox's own roadmap, so don't repeat that shortcut.
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
