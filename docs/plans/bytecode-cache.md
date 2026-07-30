# Bytecode cache (`.lxc`) for imported modules

Design record for `TODO.md`'s Phase 8 item: a serialization format for `Chunk`/`Function_Object`/`Value`,
mtime-based cache invalidation, and a real `--force-compile` flag. Grounded in a direct audit of odlox's
current compiler output, module-loading flow, and glox's own reference `.lxc` implementation — not assumed.

**Status**: shipped (`ROADMAP.md`'s Phase 8 section). All five implementation-order stages below landed,
including the correctness stress test and stale/corruption recovery test. One real bug was found during
implementation that this design didn't anticipate — `core.Environment.global_names` (a field distinct from
`Chunk.global_names`, populated only as a side effect of `compiler.Compile` actually running) wasn't wired up
by a cache hit, breaking name-based module property access (`mod.name`) the first time a real end-to-end
integration test exercised it rather than just a format-level round trip. Fixed in `bc_cache_load` itself;
see `ROADMAP.md`'s Phase 8 section for the full account.

## Why this, why now

Unlike the pool allocator (`docs/plans/pool-allocator.md`), this isn't chasing a measured bottleneck —
module-recompilation time has never been profiled as a real cost in this project, and TODO.md's own phase
heading marks it "optional, low priority... only if module-recompilation time is measured to actually
matter." The motivation here is **completeness of the port**: glox has a working `.lxc` bytecode cache for
imported modules (`glox_reference/src/vm/bc_cache.go`), and odlox currently has no caching at all — every
run recompiles every imported module from source, and the `--force-compile` CLI flag is a documented,
deliberate no-op (`main.odin`'s own comment: "there's no cache here at all... explicitly accepting and
ignoring the flag is the correct behavior, not a stopgap"). Once this ships, that comment becomes false and
the flag needs to do something real.

glox's own `.lxc` design has a documented, real weakness, called out in `glox_reference/CLAUDE.md`: "Stale
`.lxc` files (compiled with an older binary) cause hangs or out-of-memory panics when loaded by a newer
binary. Always run `bin/clear_lxc.sh` after any change that affects `.lxc` serialisation." This happens
because glox's format has no magic bytes or version header at all — invalidation is purely mtime-based, so
rebuilding the glox binary itself never invalidates an existing `.lxc`, and a schema change silently
misinterprets old bytes under the new layout. This plan makes one deliberate, explicit choice about that:
replicate glox's mtime-only invalidation model faithfully (matching the completeness framing — this is not
license to over-engineer with content hashing or anything glox itself doesn't do), but add a small
magic+version header as a named, justified improvement over glox's own documented bug class. Following this
project's established practice (see pool-allocator.md's own faithful-vs-improved calls), a deviation from
glox gets made explicitly and documented, never silently.

## Current state (compiler output, module loading, glox's reference behavior)

### odlox's compiler output shape

`Chunk` (`core/chunk.odin:132-141`):
```odin
Chunk :: struct {
	code:            [dynamic]u8,
	constants:       [dynamic]Value,
	lines:           [dynamic]int,           // parallel to code: one entry per byte
	filename:        string,
	local_vars:      [dynamic]Local_Var_Info, // debug info only
	global_count:    int,
	global_names:    [dynamic]string,         // only populated on the top-level chunk
	property_caches: [dynamic]Property_Cache,
}
```
`local_vars` (chunk.odin:119-124, `name/start_ip/end_ip/slot`) is consulted only by name/ip-range in
`debug/disassemble.odin` and `debug/inspect.odin` — never opcode-indexed, safe to omit from a cache
entirely and decode as empty.

`property_caches` (chunk.odin:159-162, `class: ^Class_Object, method: Value`) is different: it's
**opcode-indexed by array position** — `vm/run.odin`'s `Get_Property`/`Invoke` handlers index
`chunk.property_caches[cache_idx]` with a `u8` operand baked into the bytecode at compile time
(`chunk_add_property_cache`, chunk.odin:178-181). A cache format must restore an array of the *exact same
length* compile time produced (entries zeroed, `class == nil` meaning "cold," matching a fresh compile's own
starting state) — getting the length wrong is a real out-of-bounds read, not a style nitpick. Only the
*count* needs to survive the round trip; `class`/`method` are live runtime state and must never be written
to disk.

`Function_Object` (`core/obj_function.odin:13-22`):
```odin
Function_Object :: struct {
	using obj:     Obj,
	arity:         int,
	min_arity:     int,
	is_variadic:   bool,
	chunk:         ^Chunk,
	name:          ^String_Object,
	upvalue_count: int,
	environment:   ^Environment,  // runtime-only back-pointer, never serialized
}
```
Nested functions/closures are constants of their enclosing chunk (`compiler/functions.odin:108-117`'s
`emit_closure` adds each nested `Function_Object` via `chunk_add_constant`, then emits the `Op_Code.Closure`
opcode plus one `(is_local, index)` byte pair per upvalue — already fully captured in `code`, so no separate
upvalue-descriptor section is needed). The whole compiled unit is one recursive tree rooted at a single
top-level `Function_Object` — `main.odin`'s `program_stats` already walks exactly this tree for `--info`.
Function/Closure constants are never deduplicated (chunk.odin:193-198's doc comment), so there's no
structural-sharing concern for the format either — every node gets encoded exactly once, in tree order.

Exhaustively confirmed by grepping every `chunk_add_constant` call site in `src/compiler/`: a
`Chunk.constants` entry is always exactly one of **Int, Float, String, or (recursively) Function** — nothing
else. Bool/Nil have dedicated opcodes and are never constant-pool entries; no other `Object_Type` (Vec2/3/4,
Class, Instance, Module, Native, File, iterators, graphics/physics objects) is ever passed to
`chunk_add_constant` anywhere in the compiler. So the format only ever needs four constant shapes.

`Value` (`core/value.odin:37-42`), 16 bytes: `payload: #raw_union{data: u64, obj: ^Obj}, type: Value_Type,
obj_type: Object_Type, immutable: bool`.

String interning (`core/obj_string.odin`): `intern_string(s: string) -> ^String_Object` is fully
self-healing — checks its file-private `intern_table`, returns the existing canonical pointer or
clones+registers+returns a new one. A deserializer just calls `intern_string(s)` for every string it reads
back, any order, no pre-population or reconciliation pass needed.

### odlox's module-loading flow

`compiler.Compile(source, filename, environment) -> (^core.Function_Object, bool)` (`compiler/compile.odin:17`)
is already a clean, separable compile-only step — it needs a live `^core.Environment` (for global-slot
resolution) but has zero dependency on the `vm` package.

`vm/interpret.odin`'s `interpret` (11-55) is the single place that fuses compile and run, with no
caller-visible seam between them: `Compile` → `env_grow_globals` → `seed_builtin_globals` → make closure →
`call` → `run`. `main.odin`'s entry-script path (`run_file`) and `vm/module.odin`'s `load_module` both call
this exact same `interpret` — there is no separate entry-script code path in odlox (unlike glox, which has
genuinely distinct entry-vs-module VM setup).

`vm/module.odin`'s `load_module` (111-190): checks the in-memory `vm.module_cache` and builtins, reads
source text (three-tier search), builds a throwaway sub-VM, calls `interpret(sub, source)` (line 139), then
**splices `sub.objects` into the parent's object list** (145-175) — this is a recent use-after-free fix with
a detailed comment explaining exactly why the splice is necessary (an unspliced sub-VM's allocations would
never get swept by anyone once the sub-VM itself is discarded). This block must not be disturbed by the
cache work, only built around.

`core` cannot import `vm` (hard package-DAG constraint) — any serialize/deserialize code operating directly
on `Chunk`/`Function_Object` fields can live in `core`, but path derivation, file I/O, mtime comparison, and
wiring a deserialized function's `environment` back up must live in `vm`, the only layer with a live
`^core.Environment` in scope for a given module load.

### Existing precedent: `core/pickle.odin`

odlox already has a near-identical serializer for a different value population (runtime `pickle.dumps`/
`pickle.loads` values, not compile-time constants): tag-byte dispatch, length-prefixed strings, and a
bounds-checked decoder that **slices into the existing buffer rather than allocating from an untrusted
length** — this alone structurally defeats glox's OOM/hang bug class, since no allocation is ever sized from
a number read out of the file; a garbage-huge length just fails the very next bounds check instead of
attempting a giant `make()`. `pickle.odin` also already settled the int-width question this format faces:
it round-trips `.Int` through a full 8-byte `u64`, not glox's truncate-to-`u32` (a real, acknowledged bug in
glox — `bc_cache.go` silently wraps any int constant outside 32-bit range on a cache round trip). This
format follows both of `pickle.odin`'s precedents rather than glox's.

### glox's reference implementation

`glox_reference/src/vm/bc_cache.go`: custom little-endian binary writer, `<module_dir>/__loxcache__/
<name>.lxc` naming (confirmed against real cache dirs, `src/modules/__loxcache__/{colour,math,random}.lxc`),
purely mtime-based invalidation (cache used iff the `.lxc` exists and its mtime is strictly after the
source's), no fixup step needed on a cache hit beyond deserialization itself (fresh allocations, re-interned
strings). `-f`/`--force-compile` bypasses the cache *read* only — checked as the very first line of the
cache-load function, never even stat-ing the file — but doesn't stop a fresh cache *write* afterward, so `-f`
means "ignore what's cached, but still refresh it for next time." Caching applies only to imported modules,
never the entry script.

## Design

### On-disk format

6-byte header, then one recursive `Function_Object` encoding (a module compiles to exactly one top-level
function; every nested function is already reachable purely through `chunk.constants`):

```
offset 0..3   magic:   [4]u8  = "OLXC"
offset 4..5   version: u16 LE = 1
```

Deliberate deviation from glox: a magic+version header. Bounds-checking (inherited from the `pickle.odin`
shape below) already prevents the *crash/hang/OOM* failure mode glox's own weakness produces, but it can't
prevent a subtler one — a stale cache whose bytes still parse as *plausible*, differently-meaning data under
a changed schema, silently producing wrong results rather than failing loudly. A magic+version check catches
that case for free; skipping it would leave the one gap bounds-checking alone can't close.

Chunk section, in order:
```
u32              code_len;       [code_len]u8 code
u32              lines_count;    [lines_count]u32 lines      // == code_len, parallel array, no RLE
u32              constants_count [constants_count] Value      // tag byte + payload, see below
u32              filename_len;   [filename_len]u8 filename
u32              global_count
u32              global_names_count [global_names_count] (u32 len + bytes)  // 0 on non-top-level chunks
u32              property_cache_count   // COUNT ONLY -- decodes to a zero-valued array of this exact
                                        // length; class/method are never written (live runtime state)
// local_vars: omitted entirely -- decodes to an empty [dynamic]Local_Var_Info
```

Value tags:
```odin
Bc_Value_Tag :: enum u8 {
	Int      = 1, // 8 bytes, raw u64 bit pattern
	Float    = 2, // 8 bytes, raw u64 bit pattern (transmute f64<->u64)
	String   = 3, // u32 len + bytes; re-interned via core.intern_string on decode
	Function = 4, // recursive: name (u32 len+bytes), arity, min_arity, is_variadic (u8),
	              // upvalue_count, then its own Chunk section per the layout above
}
```
`Nil`/`Bool`/`Vec2/3/4` are deliberately absent — never producible by `chunk_add_constant`. An unrecognized
tag byte is a decode failure (`ok = false`), never a panic, matching `pickle.odin`'s own discipline.

No per-section marker bytes (glox's repeated `0xFF` sentinel) — a length-prefixed, bounds-checked format
already catches truncation for free; a marker byte would be faithful-for-its-own-sake without adding real
protection (it's also easily fooled by same-sized field reordering, per glox's own source).

### Code location

`src/core/bc_cache.odin` (new) — pure data-shape logic, modeled directly on `pickle.odin`'s
encoder/decoder shape, zero `vm` dependency:
```odin
// function_serialise encodes fn and, recursively, every nested Function_Object
// reachable through its own chunk.constants. Never touches fn.environment.
function_serialise :: proc(fn: ^Function_Object) -> (data: []u8, ok: bool)

// function_deserialise decodes data back into a fresh Function_Object tree.
// Every node's .environment is left nil -- the caller must wire it up (see
// bc_cache_wire_environment below). ok is false on any malformed/truncated/
// wrong-version input; callers should treat that identically to "no cache."
function_deserialise :: proc(data: []u8) -> (fn: ^Function_Object, ok: bool)
```

`src/vm/bc_cache.odin` (new) — file I/O, path derivation, mtime comparison, and the environment fixup:
```odin
bc_cache_path :: proc(module_source_path: string) -> string  // <dir>/__loxcache__/<stem>.lxc

// Returns ok=false for *any* reason to fall back to compiling -- missing
// file, stale mtime, bad header, malformed body. Callers never need to
// distinguish these cases.
bc_cache_load :: proc(vm: ^VM, module_source_path: string, environment: ^core.Environment) -> (fn: ^core.Function_Object, ok: bool)

bc_cache_write :: proc(module_source_path: string, fn: ^core.Function_Object)

// Recursive -- required because Get_Global/Set_Global resolve globals
// through *whichever frame's own* fn.environment is currently executing,
// not just the top-level function's. The compiler already points every
// nested function at the same shared Environment; a fixup that only
// patches the root leaves nested functions with a nil environment, which
// crashes the first time one of them touches a global.
bc_cache_wire_environment :: proc(fn: ^core.Function_Object, environment: ^core.Environment)
```

### Integration point

Split `vm/interpret.odin`'s `interpret` into the existing compile step plus a new `run_compiled(vm, fn) ->
(Interpret_Result, string)` covering everything after a `^Function_Object` exists (`env_grow_globals`,
`seed_builtin_globals`, closure+call+run). Pure refactor for the entry-script/REPL paths — both still call
`interpret` exactly as today, behavior unchanged.

`load_module` gains a small local step (a `compile_and_cache_module`-style helper) that tries
`bc_cache_load` first (unless `--force-compile`); on a hit, calls `run_compiled` directly; on a miss, calls
`compiler.Compile` + `run_compiled` + `bc_cache_write`. The existing splice block (module.odin:145-175)
stays exactly as-is downstream of either branch — it operates on `sub.objects`/`sub.bytes_allocated`
regardless of which path produced `sub`'s top-level function.

### Path derivation and invalidation

Mirrors glox: `<module_dir>/__loxcache__/<name>.lxc`. The `__loxcache__` directory name is already
reserved/skipped by `find_module_in_subdirs` (module.odin), anticipating this feature. Cache used iff the
`.lxc` exists, its header parses (magic+version match), and `os.modification_time_by_path`
(`core/os/stat.odin:109`) shows it strictly newer than the source.

### `--force-compile`

Thread `Options.force_compile` (`main.odin`) → a `force_compile` bool on `vm.VM`, checked as the first line
of `bc_cache_load` — never even stats the file when set, matching glox's own placement. The write side is
unaffected: a fresh compile under `-f` still calls `bc_cache_write` afterward, matching glox's "bypass the
read, but still refresh the write" semantics. Applies only to imported modules; the entry script never calls
`bc_cache_load` at all, so the flag naturally has no effect there, same as glox.

### Version mismatch handling

Never a hard error — falling back to source-compile is always correct and always available.
- Bad magic: silent fallback (the common/expected case — no cache yet for this module).
- Recognized magic, wrong version: fallback plus one `stderr` diagnostic line (informational only, never
  affects control flow), distinguishing "a real, outdated cache of ours" from "not a cache file at all."
- Any decode failure partway through a well-headered file (truncation, a bounds-check miss): same `ok=false`
  → silent fallback; `function_deserialise`'s single boolean return is the right granularity here, the
  caller never needs to know *why* a cache was unusable, only that it was.

Either way, the stale/incompatible `.lxc` is naturally overwritten by the subsequent `bc_cache_write` —
self-healing on the very next successful import of that module, no manual clear tool needed (unlike glox's
`bin/clear_lxc.sh`, not worth porting once the header removes the need for it).

### Scenario walkthrough

| Scenario | Expected behavior |
|---|---|
| Import a module for the first time (cold, no `.lxc`) | Compiles from source, writes a fresh `.lxc` afterward |
| Import it again, unchanged | `.lxc` newer than source → cache hit, no recompile; output identical to the cold run |
| Edit the source, re-import | Source now newer than `.lxc` → recompile, cache rewritten |
| Run with an older-schema/corrupt `.lxc` present | Header/bounds check fails → safe fallback to recompile, never a crash/hang/OOM; `.lxc` self-heals via overwrite |
| Run with `--force-compile` | Cache lookup skipped entirely (never stat'd); fresh compile happens; `.lxc` still rewritten afterward |
| Two processes importing the same module concurrently | No locking designed in (glox has none either); worst case is a torn/partial write, caught by the next reader's bounds-checked decode + header check and treated as any other corruption case — a self-healing cache miss, not data reaching a running script. Not worth building file-locking for a feature explicitly framed as non-performance-critical |
| A closure capturing a module-level global, loaded from cache | Exercises the environment-fixup-on-every-node requirement — must resolve correctly, not crash on first global access |
| A class method invoked twice through the same call site, loaded from cache | Exercises the property-cache-array-length requirement — a wrong length would corrupt or crash on the *second* invocation, once the inline cache has something to check against |

## Implementation order

1. **Format + isolated round-trip test.** `core/bc_cache.odin`'s serialize/deserialize, proven against a
   real `compiler.Compile`-produced `Function_Object` tree (not a hand-built fixture) in a new
   `core/bc_cache_test.odin` — asserts structural equality of everything except `environment` (nil
   post-decode) and `local_vars`/live `property_caches` contents (reset). No `vm`, filesystem, or
   module-loading involvement at this stage.
2. **Read-only wiring into `load_module`**, using hand-constructed `.lxc` fixtures (bypassing
   `bc_cache_write` entirely) to prove `bc_cache_load` + the environment fixup work end-to-end, including
   the nested-function/global-resolution case.
3. **Cache writing** — `bc_cache_write` wired into the no-cache-hit branch. From here, real
   compile→write→read-back round trips exist without hand-built fixtures.
4. **mtime invalidation** — verify editing a module's source after a cache exists triggers recompilation,
   not a stale serve, and that the cache gets rewritten.
5. **`--force-compile`** — smallest, most mechanical stage; last because nothing else depends on it.

## Verification plan

Two distinct concerns, same discipline the pool-allocator work was held to — a cache's real failure mode is
*silent data corruption* (a subtly wrong round trip), not a crash, so correctness needs a dedicated check
beyond "doesn't crash":

- **Round-trip stress test** (`tests/new_tests/lox/bc_cache_roundtrip_stress.lox` + pytest driver), modeled
  on `pool_reuse_stress.lox`'s exact-value-assertion discipline: a module exercising large ints spanning the
  32-bit boundary (`2147483647`, `2147483648`, `4294967296`, negatives — positively confirming no
  truncation, since a regression here would look exactly like glox's own known bug reappearing), floats,
  strings containing non-ASCII/null bytes (confirms length-prefixing, not C-string-style termination), a
  closure capturing a module global, and a class method invoked at least twice through the same call site.
  Run the same script twice via the pytest fixture pattern this project already uses for module imports,
  asserting identical output cold (no cache) vs. warm (cache hit) — any divergence is definitionally cache
  corruption.
- **Stale/corruption recovery test** (`vm/bc_cache_test.odin`, real-filesystem fixtures matching
  `module_test.odin`'s style): corrupt a written `.lxc` three ways — bad version byte, mid-file truncation,
  and a garbage-huge length field deep in the constants section (the closest analog to glox's actual
  documented OOM/hang trigger) — and assert each falls back to a correct source compile with no
  hang/crash/huge allocation, that the module import still succeeds end-to-end, and that a subsequent
  import leaves a fresh, valid `.lxc` in place (self-healing, not permanently poisoned).
- **Regression gate**: `python -m pytest tests/new_tests/` run twice — once with `__loxcache__/` cleared
  (cold) and once warm — confirming the existing pass count is unaffected either way. Existing modules
  under `modules/` (`math.lox`, `random.lox`, `colour.lox`, ...) are good real-world smoke subjects for this
  but not a substitute for the purpose-built stress/corruption fixtures above, none of which are designed to
  exercise this format's specific known risk points (32-bit-boundary ints, deliberate corruption, a
  double-invoked method).
- Both build modes (`bin/build.sh` / `bin/build.sh --release`) compiling clean throughout.
- Document the shipped result in `ROADMAP.md` (a new Phase 8 section: what shipped, the header-vs-glox
  deviation and why, the int-truncation-avoidance decision, verification results) and delete the TODO.md
  Phase 8 bullet entirely once done, per this project's standing TODO-must-be-outstanding-only discipline.
