# TODO

Outstanding work only, generated from `ROADMAP.md`'s checklists. This file tracks *what's left*, not
history — completed items are removed here (not checked off), with the full record staying in
`ROADMAP.md` (each phase's own section, including root causes and bugs found, lives there permanently).
When an item below is finished, delete it from this file and (if relevant) check it off in `ROADMAP.md`.

Regenerate/re-sync this list against `ROADMAP.md` if the two drift — `ROADMAP.md` is the source of truth.

## Phase 0 — Project scaffolding

- [ ] Decide and record the Odin build flags for debug vs. release (`-debug`, `-vet`, `-strict-style` for
      dev; `-o:speed -disable-assert -no-bounds-check` for release/benchmark).

## Phase 6 — Native/builtin functions & standard library

- [ ] Raylib-backed natives: window/2D drawing first, then texture/shader/batch/camera/render_texture/
      image, then a real `physics_world` (a stub exists). The one remaining piece of Phase 6b — a separate,
      much larger effort (real windowing, a `vendor:raylib` dependency, a native object per raylib resource
      type).
- [ ] `process` module: **parked, not finished**. `spawn`/`send`/`recv`/`wait`/`kill`/`pid` work and are
      tested; `wait_any()` raises a spurious "truncated message" `ProcessError` under a fire-and-forget
      multi-message pattern (suspected Windows `PeekNamedPipe`/pipe-EOF interaction, not fully root-caused
      — see `ROADMAP.md`'s Phase 6h section). `test_process.py`/`test_pool.py` are skipped at the whole-file
      level pending this. `thread`/`sync` remain permanently out of scope, not on this list.
- [ ] `pool.lox` — blocked on the parked `process.wait_any()` bug above (its `ProcessPool` class needs it
      working correctly); its `ThreadPool` class is permanently blocked by `thread` being out of scope, so
      this module can only ever be partially ported even once `wait_any` is fixed. `plot_grey.lox`/
      `plot_rgb.lox`/`sprite.lox` are blocked on raylib instead, tracked under the raylib bullet above.

## Phase 7 — Performance pass

Only after Phases 1–6 are correct and green against the test suite.

- [ ] Confirm the raw-pointer `ip`/stack-top change (Phase 4) actually measures as a win. **Correction: this
      was never implemented, not just unconfirmed** — `docs/ARCHITECTURE.md` documents it as the design intent
      but `run.odin`/`vm.odin` still use plain `int` index fields (`fl.f.ip`, `vm.stack_top`), not raw pointer
      locals. Needs to actually be built, then measured.
- [ ] `get_property`/`bind_method` (`vm/properties.odin`) call `core.intern_string(name)` on every single
      property/method access, even though the name is already an interned string constant from the bytecode
      (`Op_Get_Property`'s operand). This re-hashes on every access for no reason — pass the already-interned
      `^String_Object` (or cache it on the constant) instead of re-interning a plain `string` each time. Cheap,
      high-confidence win; found via the Phase 7 benchmark baseline (see ROADMAP.md's Phase 7b), not yet implemented.
- [ ] Object-model cost (map-backed instance fields/methods, `core/obj_instance.odin`'s
      `fields: map[^String_Object]Value`, `core/obj_class.odin`'s `methods`/`statics` maps) is now confirmed
      as odlox's own worst relative cost, not just a theoretical carry-over from glox: the Phase 7 baseline
      (ROADMAP.md's Phase 7b) shows `trees` at 1.45x and `binary_trees` at 1.44x *slower* than glox specifically (odlox wins
      everywhere else), matching glox's own performance-roadmap identification of this as its top pain point.
      odlox ported the map-backed design unchanged rather than improving on it. Attempt compile-time-baked
      instance field slots (`OP_GET_FIELD_SLOT`/`OP_SET_FIELD_SLOT`) — do it properly or skip it; a
      runtime-only slot table was a net regression in glox's own roadmap, so don't repeat that shortcut.
- [ ] Consider a monomorphic inline cache on `OP_GET_PROPERTY`/`OP_INVOKE`.
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
