# Pool allocator for high-churn small objects

**Superseded for vec2/3/4**: Tier 1+2 below (the vec2/3/4 pooling this document was originally written for)
was reverted by `docs/plans/inline-vec-value.md` — vec2/3/4 are no longer heap objects at all (inlined
directly into `Value`, see `docs/ARCHITECTURE.md`'s Value representation section), so there's nothing left
to pool for these three types. Pooling cut allocation *overhead* (~8% wall-clock, measured below) but not GC
*cycle frequency* (pooled reuse still counts toward the allocation threshold that triggers a collection) —
inlining addresses the frequency problem directly, at the root, instead. Tier 3 (upvalues/bound methods,
never started) is unrelated and still a live idea; the design below remains a valid reference for it. Kept
as a historical record rather than deleted — the struct-size audit, the measured 8% number, and the
free-list correctness-testing methodology (thousands of allocate/collect/reallocate cycles, asserting no
stale field leaks between reused slots) are all still accurate and reusable for Tier 3, even though Tier 1+2
themselves no longer exist in the codebase.

---

Design record for `TODO.md`'s Phase 7 item: "Consider a free-list/pool allocator for high-churn small
fixed-size objects (vec2/3/4, upvalues, bound methods)." Grounded in a direct audit of the current
allocation lifecycle for these five types (every allocation site, every GC integration point), not assumed.

**Status**: Tier 1+2 shipped (`ROADMAP.md`'s Phase 7g/7h) — vec2/3/4 is fully pooled: arithmetic ops, the
`vec2()`/`vec3()`/`vec4()` constructors, and every native query call site (camera/batch/physics_world
queries, `colour_utils`) except `pickle.loads`, which turned out to be structurally unreachable from `core`
package (below `vm` in the DAG, and sometimes runs with no VM in scope at all — see Phase 7h for the full
reasoning) and is now a permanent exclusion, not a deferred item. Only upvalues/bound methods (Tier 3) are
still outstanding; the sections below describe the full original design, not just what's landed so far.
Measured result on Tier 1: no change in GC cycle count (expected — see "why" below), ~8% faster wall-clock
on an allocation-dominated microbenchmark. Modest, real, not the dramatic win a first guess might expect.

## Why this, why now

Two real scripts profiled this session (`fireworks.lox`, `3d_balls_physics_shaders.lox`) both turned out to
be dominated by exactly this class of object: short-lived vec2/3/4 values constructed, used for one
expression or one native call, and discarded within the same frame. Fixing the *allocation rate* at the
script level (hoisting constants, reusing mutable vecs, writing into caller-provided storage instead of
returning tuples) cut GC cycles by roughly 8.6× on `3d_balls_physics_shaders.lox` alone (1130 → 132 cycles
over an identical 20s window — see `ROADMAP.md`'s Phase 6aa/6ab). That approach only goes as far as a
script author is willing to hand-optimize, though, and every one of those fixes was a workaround for the
same underlying fact: **every `vec3(...)`, every `a ++ b`, every native query that returns a fresh vector
allocates a brand-new heap object that's very likely garbage again within a few opcodes.** A pool allocator
attacks this at the interpreter level instead, so scripts that *don't* hand-optimize still benefit.

## Current allocation lifecycle (as of this writing)

### Struct sizes

All in `src/core/`, each `using obj: Obj` (`type: Object_Type`, `marked: bool`, `next: ^Obj` — 16 bytes)
plus fixed `f64` fields:

| Type | Fields beyond `Obj` | Size |
|---|---|---|
| `Vec2_Object` (`obj_vec.odin:12`) | `x, y: f64` | 32 bytes |
| `Vec3_Object` (`obj_vec.odin:24`) | `x, y, z: f64` | 40 bytes |
| `Vec4_Object` (`obj_vec.odin:36`) | `x, y, z, w: f64` | 48 bytes |
| `Upvalue_Object` (`obj_upvalue.odin:14`) | `location: ^Value`, `slot: int`, `next_open: ^Upvalue_Object`, `closed: Value` | 56 bytes |
| `Bound_Method_Object` (`obj_bound_method.odin:6`) | `receiver: Value`, `method: ^Closure_Object` | 40 bytes |

Five fixed sizes, known at compile time — no size-class bucketing needed (unlike a general-purpose
allocator). One free list per type is the natural design.

### Allocation sites

Every vec construction bottoms out in `core.make_vec{2,3,4}_object` (`obj_vec.odin`, plain `new()`, no
pooling today) via one of two paths:
- `core.make_vec{2,3,4}_value` (`core/value.odin:86`) — used by native/host code; does **not** itself
  `gc_track` (caller must).
- `vm.push_vec{2,3,4}` (`vm/arithmetic.odin:78`) — used by VM opcodes; builds, `gc_track`s, and pushes in
  one step.

Concretely, every one of these is a distinct allocation event today:
- `add_vector` (`vm/arithmetic.odin:54`, Lox `a ++ b`) and the vector branch of `numeric_binop`'s Subtract
  case (`vm/arithmetic.odin:113`, Lox `a - b`) — both `pop()` their operands (removing them from the stack
  only; the underlying heap objects are untouched and still reachable through whatever variable held them)
  and **always** allocate a brand-new object for the result via `push_vec{2,3,4}`. Neither operand's storage
  is ever reused for the result.
- `vec2()`/`vec3()`/`vec4()` native constructors (`vm/builtins.odin:477`) — every explicit Lox constructor
  call.
- Native query methods that hand back a live engine value as a fresh vec: `Camera.get_position()`
  (`vm/gfx_camera.odin:62`), batch position/size/color queries (`vm/gfx_batch.odin:175,193,211`),
  `physics_world`'s position/velocity queries (`vm/physics_world.odin:517`).
- `colour_utils` native helpers returning an RGBA `vec4` (`natives/colour_utils.odin:55,84,108,138,179,191`).
- `pickle.loads(...)` rehydrating a previously-pickled vector (`core/pickle.odin:366,374,383`).

Two operations touch vecs *without* allocating anything, already optimal, and out of scope for pooling:
- Field read/write swizzles, `v.x` / `v.x = 5` (`vm/properties.odin:94,158`) — mutate or read the existing
  object's fields directly.
- `.add(other)` / `.set(x, y, ...)` methods (`vm/call.odin:246`) — mutate the receiver's fields in place,
  same object identity, no allocation.

### Deallocation and GC integration

`vm/gc.odin`'s `free_object` has **no explicit case** for `.Vec2`/`.Vec3`/`.Vec4` (or, per the same audit,
for `.Upvalue`/`.Bound_Method`) — all five fall to the generic default, `free(obj)` (`gc.odin:396`), which is
correct today since none of them own a secondary allocation (dynamic array/map) that needs an explicit
`delete()` first. `blacken_object` also has no case for any of the five — vecs have no `Obj`-typed children
to trace at all; upvalues/bound-methods *do* reference other objects (`Upvalue_Object.location`/`closed`,
`Bound_Method_Object.receiver`/`method`) but those are already traced generically through `mark_value`
wherever the containing value itself gets marked, not through a `blacken_object` case specific to these two
types — confirm this hasn't changed before assuming it stays true post-pooling. `mark_value`
(`gc.odin:144`) treats `.Vec2`/`.Vec3`/`.Vec4` identically to `.Obj` (`case .Obj, .Vec2, .Vec3, .Vec4: mark_object(vm, v.obj)`) —
this doesn't change under pooling; a pooled-and-reused object is exactly as markable as a freshly-`new()`'d
one, since it's fully reinitialized and relinked before ever becoming reachable again (see below).

`vm.bytes_allocated` is incremented in `gc_track` (`gc.odin:39`, `+= object_size(obj)`) and decremented in
`sweep` (`gc.odin:266`, `-= object_size(obj)`, read *before* `free_object` runs) — both sides of this
accounting are already correct as of this session's earlier fix (`fireworks.lox` frame-rate investigation).

### No existing precedent

A repo-wide search for `free_list`/`pool`/`recycl` turns up nothing at the VM level — `modules/particle_sys.lox`'s
own `_pool` (a plain Lox `List_Object`, module-level, hand-managed) is a *script-level* object-reuse pattern
for `Particle` instances, with zero interaction with the VM/GC internals. It's a good precedent for *why*
pooling helps (the whole point of that module's own free list is avoiding per-frame `Particle` allocation)
but not a precedent for *how* to implement one inside the interpreter itself — this would be new
infrastructure.

## Design

### Free list shape: intrusive, per-type, unbounded

Reuse `Obj.next` — the same field `vm.objects` already uses as its own intrusive "all live objects" linked
list — as the free list's link too, once an object leaves that list. Zero extra memory per pooled object
(no separate array of pointers), and it's the same technique `vm.objects` itself already uses, so it's
consistent with the existing design rather than a new idiom:

```odin
// vm.odin, new VM fields — one per poolable type
vec2_free, vec3_free, vec4_free: ^core.Obj
upvalue_free, bound_method_free: ^core.Obj
```

**On free** (`sweep`, gc.odin): instead of falling through to `free_object`'s generic `free(obj)` case for
these five types, push onto the matching free list instead:
```odin
obj.next = vm.vec3_free
vm.vec3_free = obj
```
No `delete()`/`free()` call at all — the memory stays allocated, parked for reuse.

**On allocate**: check the free list first; pop and reinitialize in place if non-empty, otherwise fall back
to today's `new()`. This needs to go through the *same* `gc_track`-equivalent bookkeeping a fresh allocation
does — relink into `vm.objects` (`obj.next = vm.objects; vm.objects = obj`) and re-increment
`vm.bytes_allocated` — so pooled reuse doesn't need separate accounting logic, it just skips the `new()` call
and fully overwrites the recycled object's fields:
```odin
alloc_vec3 :: proc(vm: ^VM, x, y, z: f64) -> ^core.Vec3_Object {
    o: ^core.Vec3_Object
    if vm.vec3_free != nil {
        o = cast(^core.Vec3_Object)vm.vec3_free
        vm.vec3_free = vm.vec3_free.next
        o.marked = false // defensive -- should already be false, sweep only frees unmarked objects
    } else {
        o = new(core.Vec3_Object)
    }
    o.type = .Vec3
    o.x, o.y, o.z = x, y, z
    gc_track(vm, &o.obj) // relinks into vm.objects, increments bytes_allocated -- same as any fresh allocation
    return o
}
```

**Unbounded, not capped**: a per-type free list that only ever grows via frees, never proactively trimmed.
For the workloads this is actually aimed at (steady-state graphics/game loops, the two scripts already
profiled), the pool's size naturally bounds itself at whatever the *peak* concurrent live count was — it
can't grow past that, since it only gains entries when something already-allocated becomes garbage. The
honest tradeoff: a script with one brief huge spike in vec allocation and then permanent idle afterward
would keep that peak's worth of memory parked forever, never returned to the OS. Acceptable for this
project's real workloads; worth a one-line comment at the free-list declaration, not worth solving now.

### Where allocation call sites need to change

The free-list check only helps a call site that actually goes through it. Two tiers:

**Tier 1 — `vm/arithmetic.odin`'s `push_vec{2,3,4}`** (`add_vector`, the vector-subtract branch of
`numeric_binop`) and **`vm/builtins.odin`'s `vec2()`/`vec3()`/`vec4()` constructors** — these are the
highest-frequency sites by a wide margin per this session's own measurements (arithmetic + explicit
constructors dominate a typical per-frame update/render loop). Route both through the new `alloc_vec{2,3,4}`
helpers instead of `core.make_vec{2,3,4}_object`/`_value` directly. This alone covers the patterns below
that matter most in practice.

**Tier 2 — native query methods returning a fresh vec** (`gfx_camera.odin`, `gfx_batch.odin`,
`physics_world.odin`, `colour_utils.odin`) — lower frequency per-call (each fires at most once per native
call site per frame, vs. potentially several vector arithmetic ops per line of script), but real and easy to
fold in once Tier 1 proves the mechanism: same `alloc_vec{2,3,4}` helpers. **Shipped** (Phase 7h) — including
from `natives/colour_utils.odin`, which confirmed `alloc_vec{2,3,4}` are genuinely package-exported (no
`@(private)`), reachable the same way `gc_track`/`runtime_error` already are from `natives`.

**`pickle.loads` — not Tier 2 after all, a permanent exclusion.** `core/pickle.odin`'s vector deserialization
lives in `core` package, structurally below `vm` in the DAG — it cannot reference `vm.VM`/`alloc_vec{2,3,4}`
without a circular import, and `pickle_decode` can run with no VM in scope at all (the `process` module's
background pipe-reader path). Not a deferred item; there's no version of this design that reaches it without
restructuring the module system itself, and the ceiling is low anyway (deserialization is a cold path
compared to per-frame graphics/physics queries).

Not applicable to pooling at all: `set_vec_swizzle`/`get_vec_swizzle`, `.add()`/`.set()` — already
allocation-free, nothing to intercept.

### Typical Lox usage patterns and how the pool handles each

| Pattern | Example | Allocates today? | Pooled? |
|---|---|---|---|
| Vector arithmetic, var and/or literal operands | `pos ++ vec3(1, 0, 0)`, `a - b` | Yes — **two** allocations here: the `vec3(1,0,0)` literal (Tier 1 constructor) and the `++` result (Tier 1 arithmetic). Both operands' own objects are left alone (`pop()` only removes them from the stack, not from existence) | Both allocations go through `alloc_vec3`; the literal becomes garbage right after `++` consumes it and is available for reuse (by *anything*, not just another vec3) on the very next allocation once swept |
| Explicit constructor | `vec3(x, y, z)` | Yes | Tier 1 |
| Field mutation | `this.pos.x = 5` | No — mutates in place | N/A, already optimal |
| Vec passed to a native call | `win.cube_rotated(pos, size, axis, angle, color)` | No, on the call itself — every consuming native copies `x`/`y`/`z` out immediately and never retains the Lox object (confirmed for every raylib draw call this session) | N/A for the call; if an argument is an inline literal (`win.clear(vec4(0,0,0,255))`), that's the constructor pattern above, not this one |
| Native query returning a vec | `world.get_position(id)`, `cam.get_position()` | Yes | Tier 2 — shipped |
| Stored in a variable/field/list/dict | `this.pos = vec3(...)` | The store itself doesn't allocate — the vec was already allocated by whichever pattern above produced it | Identity doesn't change; returns to its type's free list whenever it *later* becomes unreachable, same as any other object |
| `.add(other)` / `.set(...)` mutating methods | `pos.add(delta)` | No — mutates receiver in place | N/A, already optimal |
| `world.get_position_into(id, vec3)`-style write-into-existing-object APIs (this session's own fix for the dominant `3d_balls` allocation source) | — | No — by design, this is the *alternative* to allocating at all | N/A — script-level reuse and pooling are complementary, not competing: a script that already reuses its own vecs benefits less from pooling (there's less to pool), which is fine |
| Unary negate `-v`, scalar multiply/divide `v * 2.0` | — | Currently **unsupported** for vector operands (`negate`/`numeric_binop`'s Multiply/Divide have no vec case — a real, separate gap, not this document's concern) | N/A until that gap is closed; note it here so it isn't silently assumed handled |

### Upvalues and bound methods

Same free-list technique applies identically (`upvalue_free`/`bound_method_free`, same push-on-free /
pop-and-reinitialize-on-allocate shape), but the case for prioritizing them is weaker than vec2/3/4 based on
what's actually been measured:
- **Upvalues** (`core.make_upvalue_object`, `vm/upvalue.odin:12`'s `capture_upvalue`) already dedupe against
  `vm.open_upvalues` before allocating — one allocation per *distinct captured stack slot*, not one per
  closure blindly. Churn is tied to how often new closures over new locals get created (e.g.
  `particle_sys.lox`'s `__init__(col1, col2)` returning one closure per emitter), which is real but nowhere near
  the per-frame, per-vector-op rate vec allocation runs at.
- **Bound methods** (`core.make_bound_method_object`, via `bind_method_cached`) only get created when a
  script reads `instance.method` *without* immediately calling it (storing a method reference/callback) —
  ordinary `instance.method()` goes through `Invoke`, which never allocates a bound method at all. Rare in
  the kind of per-frame game-loop code profiled this session.

Worth doing for completeness (the TODO names them explicitly, and the mechanism is identical/cheap once
built for vecs), but sequence them after vec2/3/4 land and prove out, not alongside.

## Implementation order

1. ✅ Free-list fields on `VM` (vec2/3/4 only so far) + `sweep`'s three new cases (park instead of free) +
   `alloc_vec{2,3,4}` helpers in `vm` package.
2. ✅ Route Tier 1 call sites (`push_vec{2,3,4}`, the three constructor builtins) through the new helpers.
3. ✅ Measure — done (Phase 7g): no cycle-count change (expected, see "why" note added above), ~8% faster
   wall-clock on an allocation-dominated microbenchmark. Real but modest; worth doing, not worth
   overselling.
4. ✅ Tier 2 call sites (native query methods) — done (Phase 7h). `pickle.loads` turned out to be a
   permanent structural exclusion, not a deferred item — see above.
5. Upvalue/bound-method pooling, same shape, lowest priority — not started.

## Verification plan

Two distinct concerns — correctness first, performance second. A pool allocator's failure mode isn't a
crash, it's *silent data corruption* (a reused object that isn't fully reinitialized leaks a stale field
value from its previous logical identity into the new one) — this needs a dedicated check, not just
"doesn't crash":

- **Correctness**: `pytest` must hold at 220/0/26 throughout (pure regression gate, no behavior should
  change). A new, dedicated stress test: allocate many vecs, let them become unreachable, force a GC cycle
  (or cross the allocation threshold naturally), allocate many *new* vecs of the same type, and assert every
  field on every new vec matches what was just written — not a leftover value from whatever the same memory
  held previously. Run this at every pool-eligible type once its tier lands, not just vec3.
- **Performance**: reuse this session's own established technique — a temporary, `ODLOX_GC_DEBUG`-gated GC
  cycle counter (not shipped), before/after comparison on `fireworks.lox` and `3d_balls_physics_shaders.lox`
  run back-to-back through the same instrumented binary for an identical bounded window. Both scripts
  already have known current baselines from this session's earlier passes (`3d_balls`: 132 GC cycles/20s as
  of the `ground_at()` fix) to compare against.
- Both build modes (`bin/build.sh` / `bin/build.sh --release`) compiling clean and the real example scripts
  running to a bounded timeout with zero crashes, zero orphaned processes — the same bar every other change
  this session has been held to.
- Document the actual measured result in `ROADMAP.md` alongside the implementation, following this
  project's established pattern of never claiming a performance win without a real before/after number.
