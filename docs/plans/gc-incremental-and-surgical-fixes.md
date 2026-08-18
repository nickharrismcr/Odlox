# GC optimization: surgical wins + incremental collection

**Status**: design only, not yet implemented. Written in response to a "plan the GC optimizations"
request in a conversation with no Odin toolchain available in this session (no `odin` binary, no
prebuilt `bin/odlox`), so nothing here has been built, run, or benchmarked yet. Intended to be picked
up in a different session — see "First step for whoever picks this up" at the end.

## Context

Earlier in this conversation we identified odlox's mark-sweep collector (`src/vm/gc.odin`) as the
likely dominant real-world performance cost (per CLAUDE.md's documented "occasional multi-hundred-ms
stalls" finding), and sketched three improvement tiers. The user asked to plan the two lowest-risk
tiers: **Option 3** (cheap, mechanical fixes) and **Option 1** (incremental/interruptible collection,
so no single pause is proportional to heap size). Option 2 (generational/nursery) is out of scope —
it's a bigger rewrite, correctly deprioritized earlier.

While researching this plan, one of the four items originally proposed for Option 3 turned out to be
**unsafe as conceived** and is dropped below — see "Excluded" section. This is exactly the kind of
thing this planning pass exists to catch before it becomes a use-after-free.

## Option 3 — surgical wins

### 3a. Fix `object_size` under-counting for `List_Object`/`Dict_Object`

`gc.odin:373-376`'s `object_size` returns only `size_of(List_Object)` / `size_of(Dict_Object)` —
unlike `Float_Array_Object` and `String_Object` a few lines below, which deliberately include their
backing storage "or the GC-growth heuristic would badly under-count." `List_Object.items`
(`core/obj_list.odin:22`, `[dynamic]Value`) and `Dict_Object.items`
(`core/obj_dict.odin:12`, `map[^String_Object]Value`) have exactly the same problem: a script
holding a few large lists/dicts under-reports `bytes_allocated`, delaying `maybe_collect_garbage`'s
trigger past where it should fire and risking a larger stall once it finally does.

Fix: extend the same accounting pattern already used for `Float_Array_Object`:
```
case .List:
    l := cast(^core.List_Object)obj
    return size_of(core.List_Object) + len(l.items) * size_of(core.Value)
case .Dict:
    d := cast(^core.Dict_Object)obj
    return size_of(core.Dict_Object) + len(d.items) * (size_of(^core.String_Object) + size_of(core.Value))
```
Mechanical, no behavior change beyond triggering collection at more accurate points.

### 3b. Tunable GC threshold, exposed to scripts

Add a `vm.gc_threshold_floor: int` field (default `0`) to the `VM` struct (`vm/vm.odin`, alongside
`bytes_allocated`/`next_gc`). Change `collect_garbage`'s (soon: the incremental cycle's) end-of-cycle
recompute from `vm.next_gc = vm.bytes_allocated * GC_HEAP_GROW_FACTOR` to
`vm.next_gc = max(vm.bytes_allocated * GC_HEAP_GROW_FACTOR, vm.gc_threshold_floor)` — a floor, not a
one-shot override, so it stays in effect across every future cycle instead of being silently
overwritten after the first one.

Expose it as a new native in the existing `sys` module, following the exact pattern already used by
every other `sys.*` builtin (`vm/builtins_sys.odin`: `define_builtin(vm, "sys", name, proc)`, native
signature `proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value`, `native_vm(vm_ptr)` to
recover `^VM`, `runtime_error(vm, msg)` for bad args):

```odin
// sys.gc_set_min_threshold(bytes) -- a real-time script can call this once at
// startup to collect less often (trading memory for fewer, larger pauses)
// instead of the default doubling-from-1MiB policy.
gc_set_min_threshold_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
    vm := native_vm(vm_ptr)
    if argc != 1 || !core.is_number(vm.stack[arg_stack_ptr]) {
        runtime_error(vm, "sys.gc_set_min_threshold argument must be a number")
        return core.NIL_VALUE
    }
    vm.gc_threshold_floor = int(core.as_float(vm.stack[arg_stack_ptr]))
    if vm.next_gc < vm.gc_threshold_floor { vm.next_gc = vm.gc_threshold_floor }
    return core.NIL_VALUE
}
```
Registered alongside the others in `define_sys_builtins`.

### Excluded from Option 3 (found unsafe during research)

The earlier discussion proposed skipping re-tracing a `Function_Object`'s constant pool every cycle,
on the premise that a function's constants are fixed and the function itself is structurally
permanent (never swept — `gc.odin`'s header comment). Checked this against `core/obj_string.odin`:
`STRING_INTERN_MAX_LEN :: 40` means **any string literal over 40 bytes in the source becomes a
genuinely collectible object** (`obj_string.odin:21-23`), and such a string absolutely can appear in
a function's constant pool. Caching "already traced, skip next time" for a constant pool would let a
long string literal be swept out from under a function that still references it — a real
use-after-free the first time that function is called again. Also, on inspection the actual per-cycle
cost this was meant to save is already negligible: `mark_value` short-circuits immediately for every
non-`Obj` constant (the overwhelming majority — ints, floats, bools), so there's no real win available
here safely. Not part of this plan.

A per-`Object_Type` pool allocator (cutting `new`/`free` cost directly) was considered and is *not*
included here either, on stronger grounds than "out of scope": `docs/plans/done/pool-allocator.md`
already tried this for vec2/3/4 (Tier 1+2, since superseded by inlining vectors out of the heap
entirely) and measured the result directly — ~8% wall-clock improvement on an allocation-dominated
benchmark, but **no change in GC cycle count**, because pooled reuse still counts toward the
allocation threshold that triggers a collection. Pooling cuts allocation *overhead*; it doesn't touch
pause *frequency or duration*, which is what this plan is actually after. Tier 3 of that same document
(upvalues/bound methods) is still open and worth doing for its own sake, but it's a different lever
than the one this plan targets, so it isn't bundled in here.

## Option 1 — incremental (interruptible) collection

### The core problem this solves

`collect_garbage` (`gc.odin:113-124`) currently runs `mark_roots` → `trace_references` (drains
`vm.gray_stack` completely) → `sweep` (walks the entire `vm.objects` list) as one atomic call from
`maybe_collect_garbage`, itself called once per opcode-loop iteration (`run.odin:119`, confirmed the
*only* call site — nothing else calls `collect_garbage` directly, so there's no external contract
requiring it to finish synchronously). The fix: turn marking and sweeping into resumable, bounded
steps, so no single call does more than a fixed amount of work, while preserving the documented
invariant that a collection may only ever be observed between two opcodes (never mid-instruction).

### State machine

Add to `VM` (`vm/vm.odin`, near the existing `objects`/`bytes_allocated`/`next_gc`/`gray_stack`
fields):
```odin
GC_Phase :: enum { Idle, Marking, Sweeping }
gc_phase:      GC_Phase,
sweep_cursor:  ^core.Obj,   // current walk position during Sweeping
sweep_prev:    ^core.Obj,   // last surviving node, for relinking (mirrors sweep's own `prev` today)
```

Rewrite `gc.odin`:

- `maybe_collect_garbage(vm)`: if `Idle` and `bytes_allocated > next_gc`, call `start_gc_cycle(vm)`;
  then, whatever the (possibly just-updated) phase is, dispatch to `step_mark` or `step_sweep` once.
- `start_gc_cycle(vm)`: fires `.Gc_Start` (unchanged semantics — still exactly one per cycle, so
  `debug/trace.odin`'s `Gc_Hook` before/after byte accounting keeps working unmodified), calls the
  existing `mark_roots(vm)` **unchanged and still atomic** — the root set is bounded by live
  stack/frame/global/module count, not heap size, so this part doesn't need to be incremental — then
  sets `gc_phase = .Marking`.
- `step_mark(vm)`: pops up to `GC_WORK_UNIT` entries off `gray_stack`, calling `blacken_object` on
  each — identical body to today's `trace_references` loop, just bounded. When the stack empties
  before the budget is spent, transition: `gc_phase = .Sweeping`, `sweep_cursor = vm.objects`,
  `sweep_prev = nil`.
- `step_sweep(vm)`: identical per-object body to today's `sweep` loop, bounded to `GC_WORK_UNIT`
  objects per call, resuming from `sweep_cursor`/`sweep_prev`. When the cursor reaches `nil`: compute
  `next_gc` (now using the 3b floor), set `gc_phase = .Idle`, fire `.Gc_End`.
- `GC_WORK_UNIT :: 64` (or two separate mark/sweep constants) — a fixed per-call budget. Not
  attempting a Go-style adaptive pacer in this pass; a fixed constant is the right first cut and can
  be tuned from real `--trace-gc` measurements afterward.

### The write barrier

This is the part that makes the state machine correct rather than just fast, and the main source of
risk in this plan. Once marking is spread across many opcodes with the mutator actually running
in between, an already-blackened object (fully traced, will never be revisited this cycle) can have
one of its `Obj`-typed fields mutated to point at a still-white object — and since nothing re-visits
black objects, that write is invisible to the current cycle, and the newly-referenced object gets
swept while still reachable. Every mutation site enumerated by `blacken_object`'s own children
(`gc.odin:199-276`) needs a barrier call immediately after the write:

- `vm/properties.odin` — instance field/slot writes (`Set_Property` path; `Set_Field_Slot`'s fast
  path in `run.odin`).
- `vm/collections.odin` — list element set/append, dict key set.
- `vm/upvalue.odin` — closing an upvalue (`.closed` gets written).
- `vm/properties.odin` — `do_method`/`do_inherit` (`Class_Object.methods`/`.static_methods`/
  `.statics`/`.super` mutation).
- `run.odin`'s `Set_Global`-family opcodes — `core.Environment` global/local var writes
  (`mark_environment` walks `env.globals`/`env.vars`, so these are roots too, not just
  object fields — still need the barrier, since a root can also point at something already
  discovered-and-blackened elsewhere).

Not needed: `Closure_Object.upvalues` (built once at closure creation, never mutated after) and
`Bound_Method_Object`'s receiver/method (set once at creation).

Add two small procs to `gc.odin`, no-ops outside an active mark phase:
```odin
write_barrier :: proc(vm: ^VM, obj: ^core.Obj) {
    if vm.gc_phase == .Marking { mark_object(vm, obj) }
}
write_barrier_value :: proc(vm: ^VM, v: core.Value) {
    #partial switch v.type { case .Obj: write_barrier(vm, v.obj) }
}
```
Call `write_barrier_value(vm, new_value)` right after each mutation listed above.

### Allocating during an active cycle ("allocate black")

A brand-new object created mid-cycle must never be mistaken for garbage before the cycle that's
already in progress finishes discovering the graph. Simplest correct rule: `gc_track` marks it
already-black whenever a cycle is active.
```odin
gc_track :: proc(vm: ^VM, obj: ^core.Obj) {
    obj.next = vm.objects
    vm.objects = obj
    vm.bytes_allocated += object_size(obj)
    obj.marked = vm.gc_phase != .Idle
}
```

### Files touched

- `vm/vm.odin` — `GC_Phase` enum, three new `VM` fields, `gc_threshold_floor` (3b).
- `vm/gc.odin` — the rewrite above; `object_size` fix (3a) lands here too.
- `vm/properties.odin`, `vm/collections.odin`, `vm/upvalue.odin`, `run.odin` — one
  `write_barrier_value` call added at each mutation site listed above.
- `vm/builtins_sys.odin` — new `gc_set_min_threshold_builtin`, registered in `define_sys_builtins`.

## Verification

1. **Odin unit tests** (`src/vm`, run via `bin/test_odin.sh` per this repo's one-test-per-process
   convention for the `vm` package — direct `odin test` hangs unpredictably, see CLAUDE.md):
   - A multi-call incremental cycle reclaims dead objects and preserves live ones when opcodes run
     between `maybe_collect_garbage` calls (simulate by driving `step_mark`/`step_sweep` directly
     across several calls instead of one).
   - The write-barrier regression case specifically, since it's the one bug class this whole change
     risks introducing: mark an object black mid-cycle, mutate one of its fields to point at a fresh
     white object, assert the referent survives sweep instead of being incorrectly collected.
   - 3a: assert `object_size` for a large `List`/`Dict` reflects backing-storage size, not just the
     struct header.
2. **`bin/run_tests.sh`** (the ported pytest suite against the built binary) before and after, as the
   full-program correctness gate — this exercises real scripts end-to-end and should show zero
   behavioral difference.
3. **`--trace-gc`** (already wired to `Gc_Hook` in `debug/trace.odin`) against one of the
   allocation-heavy graphics examples (e.g. `lox_examples/game_of_life_shader.lox`) before/after:
   same total bytes freed per logical cycle (correctness), now spread across many bounded
   `maybe_collect_garbage` calls instead of one large synchronous one. Add a quick ad-hoc timer
   around individual `maybe_collect_garbage` calls to confirm max single-call latency drops
   relative to the pre-change baseline.

## First step for whoever picks this up

Build first (`odin build src -out:bin/odlox.exe` or this repo's usual build command) and run
`bin/run_tests.sh` to confirm a clean baseline before touching anything — this plan was written and
reviewed without a toolchain available to verify it compiles or behaves as described. Land Option 3
(3a, 3b) first: it's small, mechanical, and independently useful even if Option 1 stalls or needs
rework. Option 1 is the one to budget real review time for — the write-barrier site list in "The write
barrier" section is derived from `blacken_object`'s own child enumeration (`gc.odin:199-276`) and
should be treated as a checklist to re-verify against that switch statement directly (not just this
document) before considering it complete, since a missed site is a silent, hard-to-reproduce
correctness bug, not a crash.
