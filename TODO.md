# TODO

Outstanding work only, generated from `ROADMAP.md`'s checklists. This file tracks *what's left*, not
history — completed items are removed here (not checked off), with the full record staying in
`ROADMAP.md` (each phase's own section, including root causes and bugs found, lives there permanently).
When an item below is finished, delete it from this file and (if relevant) check it off in `ROADMAP.md`.

Regenerate/re-sync this list against `ROADMAP.md` if the two drift — `ROADMAP.md` is the source of truth.

## Phase 0 — Project scaffolding

- [ ] `odin test src/vm -all-packages` is unreliable — confirmed **pre-existing and unrelated to any change
      in this session** (reproduces on a clean worktree at the commit before today's build-script work).
      `python -m pytest tests/new_tests/` (the project's actual correctness gate) is unaffected throughout.
      Bisection ruled out a single broken test (every individual test passes alone; `core`/`compiler`
      packages alone never fail) and pointed at first toward a data race on `core/obj_string.odin`'s
      unsynchronized global `intern_table` (multiple `vm`-package tests compile/run real Lox code
      concurrently under the test runner's default 16-thread parallelism) — `-define:ODIN_TEST_THREADS=1`
      made a known-crashing batch pass reliably, which looked like confirmation. **But it isn't a full fix**:
      re-running the identical `-all-packages -define:ODIN_TEST_THREADS=1` command twice produced two
      different failure modes on two different runs — a genuine infinite-loop hang (an orphaned child test
      process burning real CPU, not blocked/waiting) once, a segfault at a different point in the log the
      next time. Same input, same flags, different outcomes each run — meaning either `ODIN_TEST_THREADS=1`
      isn't fully honored by this Odin dev-build's test runner, or there's a genuine memory-corruption bug
      (use-after-free / stale pointer / buffer overrun) whose *symptom* varies with heap layout, independent
      of threading. Not root-caused, and a genuine compiler/test-runner bug can't be ruled out either — this
      is a `dev-YYYY-MM` from-source Odin build, not a numbered release (see the workspace root `CLAUDE.md`),
      so pre-1.0 toolchain bugs are a real possibility alongside a bug in odlox's own code. Needs proper
      tooling (a memory sanitizer, if available for this Odin build, or testing against a different Odin
      build/version to see if the instability follows) rather than further ad hoc bisection before this is
      trustworthy as a verification step again.

## Phase 6 — Native/builtin functions & standard library

- [ ] Raylib-backed natives: `physics_world`, `gfx.window()` + core 2D drawing, `texture`/`image`/
      `render_texture` (+ `win.draw_texture*`/`draw_texture_pro`/`begin_texture_mode`/`end_texture_mode`/
      `draw_render_texture`/`draw_render_texture_ex`/`begin_blend_mode`/`end_blend_mode`, plus
      `render_texture`'s own mirrored 2D primitives — `clear`/`pixel`/`line`/`line_ex`/`triangle`/
      `rectangle`/`circle`/`circle_fill`/`draw_texture`/`draw_texture_pro`/`get_texture`, each drawn
      directly on the render texture rather than through `win.begin_texture_mode`), `win.BLEND_*`/`WRAP_*`/
      `KEY_*` constants, and `gfx.shader()` (+ `win.begin_shader_mode`/`end_shader_mode`) are all complete
      (see `ROADMAP.md`'s Phase 6i/6j/6k/6l/6m/6p) — verified both by scripted smoke tests (open a real
      window, exercise every method, close cleanly; no way to visually confirm rendered output from here) and
      by actually running several real example scripts (`lox_examples/defender` with its real `pngs/` art
      copied from `d:/go/glox/lox_examples/defender/pngs/`; `tile_planes.lox`; `cobweb-bifurc.lox`;
      `kaleido.lox`; `julia.lox` up to its one remaining gap, see below) to a live loop under a bounded
      wall-clock timeout with zero crashes (no display access here, so a *visual* correctness check still
      needs a human look). Still outstanding, each its own real chunk of work: `render_texture.text()`/
      `draw_array_fast` (+ the free function `gfx.lox_julia_array`, a native Julia-set computation helper —
      together the only things blocking `lox_examples/julia.lox` from running end to end), `camera`/`batch`/
      `batch_instanced`, 3D drawing, `draw_array`. `d:/odin/glox_reference/src/builtin/` is the ground truth
      for each (`obj_builtin_camera.go`+`camera_methods.go`,
      `obj_builtin_batch.go`+`batch_methods.go`, `obj_builtin_batch_instanced.go`+
      `batch_instanced_methods.go`, `builtin_draw.go` for `lox_julia_array`/`draw_array_fast`).
- [ ] `process` module: **parked, not finished**. `spawn`/`send`/`recv`/`wait`/`kill`/`pid` work and are
      tested; `wait_any()` raises a spurious "truncated message" `ProcessError` under a fire-and-forget
      multi-message pattern (suspected Windows `PeekNamedPipe`/pipe-EOF interaction, not fully root-caused
      — see `ROADMAP.md`'s Phase 6h section). `test_process.py`/`test_pool.py` are skipped at the whole-file
      level pending this. `thread`/`sync` remain permanently out of scope, not on this list.
- [ ] `pool.lox` — blocked on the parked `process.wait_any()` bug above (its `ProcessPool` class needs it
      working correctly); its `ThreadPool` class is permanently blocked by `thread` being out of scope, so
      this module can only ever be partially ported even once `wait_any` is fixed. `plot_grey.lox`/
      `plot_rgb.lox` are blocked on `gfx.draw_png(filename, float_array, is_rgb)` (`builtin_draw.go` in
      glox — not yet ported, a `float_array`-to-PNG-file writer, separate from the `image`/`texture`/
      `render_texture` work above); `sprite.lox` is done (Phase 6k), no longer blocked.

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
- [ ] Consider a free-list/pool allocator for high-churn small fixed-size objects (vec2/3/4, upvalues,
      bound methods).
- [ ] Stretch: NaN-boxing `Value` down to 8 bytes — only if profiling still shows `Value` width as a
      bottleneck after the above.
- [ ] Re-run the full benchmark suite after each change; keep a results table.

## Phase 8 (optional, low priority) — Bytecode cache

Only if module-recompilation time is measured to actually matter.

- [ ] Design a fresh serialization format for `Chunk`/`Function_Object`/`Value`.
- [ ] mtime-based cache invalidation.
- [ ] `--force-compile`-equivalent CLI flag.

## Phase 9 (final, do last) — Comment cleanup pass

Housekeeping only, done once the port is otherwise feature-complete and stable — see `ROADMAP.md`'s Phase
9 section for the full rationale before starting.

- [ ] Read through every `.odin` file under `src/` and rewrite comments that reference phase numbers, this
      port's own name, specific pytest/fixture names, "real bug found via...", before/after descriptions,
      or comparisons to glox — leave only what describes this interpreter's current architecture/behavior
      on its own terms.
- [ ] Keep genuine "why" explanations (invariants, non-obvious contracts) restated as plain facts about
      this codebase, not as a diff against glox or its own history.
- [ ] Migrate anything genuinely worth keeping from the comparison-to-glox material into
      `docs/ARCHITECTURE.md` before deleting it from source.
- [ ] Do this once, at the end — not piecemeal alongside ordinary feature work.
- [ ] Spot-check a representative file from each package (`core`, `compiler`, `vm`, `debug`, `natives`,
      `main.odin`): could someone who has never seen glox understand the architecture and behavior from
      the comments alone?
