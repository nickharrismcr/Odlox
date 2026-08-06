# Inline Vec2/Vec3/Vec4 into `Value`

Design record for the change that removes vec2/3/4 from the GC's object graph entirely, inlining them
directly into `Value`'s payload as true copy-semantics values instead of heap-allocating them. Supersedes
`docs/plans/done/pool-allocator.md`'s Tier 1+2 (vec2/3/4 pooling), which addressed allocation *overhead* but
not GC-cycle *frequency* — see that doc's own superseded-header note for the full before/after.

**Status**: shipped, on branch `inline-vec-value`.

## Why this, why now

Profiling two real scripts (`fireworks.lox`, `3d_balls_physics_shaders.lox`) during the pool-allocator work
showed vec2/3/4 churn was the dominant driver of GC cycles. Pooling cut per-allocation overhead (~8%
wall-clock, measured there) but explicitly did *not* reduce how often a collection actually runs — pooled
reuse still increments `bytes_allocated` and still crosses `next_gc`'s threshold at the same rate a fresh
allocation would. The actual complaint motivating this work was a visible one, not a throughput number: heavy
vec allocation in a real-time script shows up as a periodic frame hitch during otherwise-smooth on-screen
movement — a stop-the-world-pause-*frequency* problem. Fixing that at the root means vec2/3/4 stop
allocating at all.

The design is modeled on Godot's `Variant`, which inlines `Vector2/3/4`/`Quaternion`/`Color` directly in its
own tagged union (sized to `sizeof(real_t) * 4`) rather than heap-boxing them, while still heap-boxing
genuinely large aggregates (`Transform3D`, `Basis`) to keep `Variant` itself from ballooning to fit the rare
case — the same size-vs-frequency tradeoff `Value`'s new `vec: [4]f64` field makes. `Value` grows from 16 to
40 bytes as a result, a cost paid by *every* `Value` in the VM, not just vector-heavy code — accepted
deliberately (Godot's own double-precision build lives at a comparable `Variant` size in production), not
fought with, e.g., a narrower `f32` representation.

This also resolves a design inconsistency that predates this change: `values_equal`'s `.Vec2/.Vec3/.Vec4`
cases already compared component-wise (value semantics), while `.add()`/`.set()` mutated the shared heap
object in place (reference semantics, visible through aliases). Inlining resolves this in favor of true
value semantics everywhere; `.add()`/`.set()` are removed rather than reworked, since a value type has no
"receiver identity" left to usefully mutate. Scripts use the ordinary allocating operators instead
(`pos = pos ++ delta`, `v = vec3(x, y, z)`) — allocation-free now that vec2/3/4 are inline, so there's no
longer a performance reason to prefer in-place mutation.

## What changed

**Representation** (`core/value.odin`): `Value_Payload`'s `#raw_union` gained a `vec: [4]f64` field
alongside `data`/`obj`. `make_vec{2,3,4}_value` write straight into it — no allocation. `as_vec2/3/4` became
by-value accessors returning a small `Vec2`/`Vec3`/`Vec4` struct (`core/obj_vec.odin`, replacing the old
`Vec2_Object`/etc. heap types) rather than a pointer — chosen specifically so `as_vec2(v).x`-shaped call
sites across the VM/natives needed no syntax change, only the (many) sites that previously mutated through
the returned pointer.

**GC** (`vm/gc.odin`, `vm/vm.odin`): the Tier 1+2 free-list pool allocator (`alloc_vec{2,3,4}`, three
`vecN_free` fields, `sweep`'s parking cases) is deleted outright — nothing to pool once nothing allocates.
`mark_value`/`gc_adopt` drop their Vec2/3/4 cases; these types are never tracked at all now.
`Object_Type` (`core/object.odin`) drops `Vec2`/`Vec3`/`Vec4` — there's no heap object left to tag.

**Natives**: every hand-built `core.Value{type=.VecN, obj_type=.VecN, obj=...}` construction site
(`gfx_camera.odin`, `gfx_batch.odin`, `physics.odin`, `colour_utils.odin`, `box2d.odin`) now calls
`core.make_vec{2,3,4}_value` directly. Every native taking a `^Vec3_Object`/`^Vec4_Object` pointer parameter
(`gfx_batch.odin`'s `batch_add*`/`batch_set*` family, `gfx.odin`'s `vec4_to_rl_color`, `box2d.odin`'s
`box2d_vec2_of`) takes the new by-value `core.Vec3`/`core.Vec4` struct instead — a wider blast radius than
just the "query" (output) call sites, since input-side natives needed the same treatment.
`physics.odin`'s `get_position_into` — a native method that wrote into an existing vec3 argument in place
to avoid `get_position()`'s allocation cost — is deleted; it relied on the exact same shared-heap-object
mutation trick `.add()`/`.set()` did (silently a no-op under inline values), and its whole justification
(avoiding allocation) evaporated once `get_position()` stopped allocating at all. `pickle.odin`'s
`pickle_decode` no longer needs `gc_adopt`'s special vec case — `make_vec{2,3,4}_value` is pure value
construction with zero VM involvement, so the "no VM in scope" structural exclusion pool-allocator.md
documented for `pickle.loads` simply stops applying (a real simplification, not just an updated site).

**Swizzle-component assignment** (`v.x = expr`) — the one genuinely new piece of infrastructure. Reads
(`v.x`) and whole-value reassignment (`v = vec3(...)`) needed no change: a vec `Value` is always a full copy
now, so reading one is just as correct as it always was, and reassigning a whole value is ordinary
`Set_Local`/`Set_Property`/etc., unaffected by any of this. Assigning into a *component* is different: the
receiver a plain `Get_*` + `Set_Property` sequence would produce is a copy sitting on the VM stack, and
mutating it does nothing to wherever it was read from — true even for the simplest case (`pos.x = 5` where
`pos` is a bare local), not just nested property chains.

A live usage audit (`grep '\.[xyzw]\s*='` across `lox_examples/`) found real swizzle-assignment sites are
never more than one level deep: a bare `Local`/`Global`/`Upvalue` variable, or exactly one property access
(`this.pos.x = ...`, `e.pos.x = ...`) whose own object expression can be anything (evaluated once, opaquely
— `this`, a call result, doesn't matter, only the *last* link needs write-back). A second grep for indexed
swizzle-writes (`]\.[xyzw]\s*=`) found zero matches anywhere in the repo.

The compiler (`compiler/emit_expr.odin`'s `emit_swizzle_set`) recognizes `<target>.f = value` as this special
form purely from field-name text (`x`/`y`/`z`/`w`/`r`/`g`/`b`/`a`) and target *shape* — it never needs to know
at compile time whether the receiver actually holds a vector, since Lox is dynamically typed; if it turns
out to be an Instance/Class/Module with a field genuinely named `x` (a real, valid pattern), the same opcodes
fall back to an ordinary field-set with no write-back needed. Four new opcodes (`core/chunk.odin`) —
`Set_Local_Vec_Field`, `Set_Global_Vec_Field`, `Set_Upvalue_Vec_Field`, `Set_Property_Vec_Field` — read the
receiver's *current* value directly from its own storage (not off the stack, unlike every `Get_*` opcode),
delegate to `properties.odin`'s `swizzle_assign` (mutate-if-vector-else-ordinary-field-set), and write the
mutated whole value back if needed, leaving the assigned scalar as the expression's result either way.

**Unsupported target shapes are a compile-time error, not a silently-lost mutation**: `list[i].x = value`
(no `Index`-target write-back opcode exists — `emit_subscript` has no `Compound`-style get-modify-set
pattern to build on, and zero real usage justified adding one) and a vector that's a call's direct result
(`get_vec().x = value` — no assignable storage location at all). This mirrors GDScript's own historical
restriction on the identical value-type-vector-through-a-container problem. Compound assignment on a swizzle
field (`pos.x += 1`) is also a compile error for now — zero current usage, and no write-back-capable opcode
exists for it (only plain `.Set` got one); the workaround is `pos.x = pos.x + 1`.

**Removed**: `.add()`/`.set()` (`vm/call.odin`'s `invoke_vector_method`) — the only two vec instance methods
that ever existed. `docs/plans/done/pool-allocator.md`'s vec2/3/4 sections (superseded, not deleted — see
its own header note). 14 real script call sites migrated (`e.pos.add(e.dp)` → `e.pos = e.pos ++ e.dp`,
`v.set(x, y, z)` → `v = vec3(x, y, z)`) plus `3d_balls_physics_shaders.lox`'s `get_position_into` call.

## Verification

- `pytest`/`odin test` both green (see `ROADMAP.md`'s entry for this change for the actual before/after
  counts).
- New tests specifically for the new invariant: swizzle write-back through each supported target shape
  (Local/Global/Upvalue/one-level-Property — `src/vm/builtins_test.odin`), copy independence (assigning one
  variable's vec value to another and mutating one must never be observed through the other — the mirror
  image of what the deleted pool-reuse stress test used to check, now checking the *opposite* failure mode:
  accidentally-kept reference semantics rather than stale reused memory), the expression-value contract
  (`y = (this.pos.x = 5)` must yield `5`, not the mutated vector), and the two new compile-time-error cases
  (`src/compiler/compile_test.odin`).
- `size_of(core.Value)` pinned at exactly 40 via a dedicated test (`src/core/value_test.odin`), so any future
  accidental growth is caught explicitly rather than discovered indirectly.
- Real scripts (`fireworks.lox`, `3d_balls_physics_shaders.lox`, the `defender` game) run to completion with
  no behavior regression, particularly around the migrated `.add()`/`.set()` sites and `this.pos.x =`-shaped
  code already present elsewhere in those scripts.
