# String interning: length-based split (short/permanent vs. long/collectible)

**Status: shipped.** `core/obj_string.odin`'s `STRING_INTERN_MAX_LEN` (40 bytes, matching
Lua's own `LUAI_MAXSHORTLEN` default), plus the map-key-safety and identifier-interning
follow-ons below.

## Why

Every string in odlox was permanently interned (`core.intern_string`): `vm/gc.odin`'s own
header comment documented `String_Object` (with `Function_Object`) as one of two kinds
structurally exempted from sweep, because `intern_string` is called from `core`/`compiler`
— below `vm` in the package graph — with no `^VM` in scope to `gc_track` anything with.
`docs/ARCHITECTURE.md`'s "String weak-table sweeping" section flagged this as a deferred
follow-up ("worth revisiting if a long-running REPL/script session's intern-table growth
ever actually matters in practice — there's no evidence yet that it does").

It started mattering once native code began interning *bulk external data*, not just
compiler-emitted identifiers/literals: building the `socket` module, `recv()`/`try_recv()`
turned out to permanently leak memory — every distinct payload a script read grew
`intern_table` (one process-wide global map) forever, with no way back down. `os.read_all()`
and pickled values crossing `process.recv()`/`pickle.loads()` had the identical shape of
problem, just less immediately visible.

## What changed

Split by **length**, not by source — matching Lua's own short/long string design more
directly than a per-call-site "is this bulk data" classification would have:

- `String_Object` gained a `collectible: bool` field (default `false` — every pre-existing
  construction path is unaffected).
- `core.make_string_value(s)` now interns (permanent, deduplicated) only when
  `len(s) <= STRING_INTERN_MAX_LEN`; longer strings get an ordinary, non-deduplicated,
  `collectible = true` object instead — swept by `vm/gc.odin` like any other heap value
  once unreachable, the same as `List`/`Dict`/`Instance`.
- `vm/gc.odin` grew the matching GC-integration pieces: `object_size`/`free_object` cases
  for `.String`, a `.String` case in `gc_adopt` (so `pickle_decode`-reconstructed long
  strings become collectible without `core/pickle.odin` itself needing a `^VM`), and a new
  `vm.make_tracked_string_value(vm, s)` helper for `vm`/`natives` call sites that have a
  `^VM` in scope and want a long result to actually be freed, not just skip interning.
  `natives/socket.odin`'s `recv()`/`try_recv()` and `vm/builtins_os.odin`'s `read_all()`
  were switched to it — the two known-unbounded sources. Everything else (string
  concatenation, `str()`, `format()`, regex results, `pickle.dumps()`) still calls plain
  `core.make_string_value`: correct either way after the length split, just not yet wired
  to actually collect. Good follow-up candidates, not required to close the leak that
  triggered this.

## Two correctness follow-ons this split required

Both were found by auditing every place `^String_Object` **pointer identity** — not just
content equality — is load-bearing, before assuming a length-based split was safe:

1. **Value equality needed no change.** `objects_equal`'s `.String` case is
   `s1.chars == s2.chars` — Odin's native `string` `==` is a full content comparison, not
   a pointer compare. Already correct for any mix of interned/collectible strings.

2. **`Dict` genuinely depends on pointer identity**, via `map[^String_Object]Value`. Three
   call sites took a Value already known to be a string and used its `^String_Object`
   pointer as-is for a dict key, trusting the (now-broken) "every string is interned"
   assumption: `vm/collections.odin`'s `dict_key()` (behind `[]`/`[]=`/`in`), and
   `vm/call.odin`'s `dict.get()`/`.remove()`. Fixed by re-canonicalizing through
   `core.intern_string` at each — a cheap no-op map lookup for the (overwhelmingly common)
   case where the key was already canonical. `Class.methods/statics`/`Instance.fields`/
   `Environment.vars` needed no changes: property/method names always come from the
   compiled constant pool, never a runtime string (verified against `run.odin`'s
   `Op_Get_Property`/`Op_Set_Property`), and no `setattr`/dynamic-property API exists.

3. **Compiler-emitted identifiers are also map keys, and are not guaranteed short.** The
   compiler compiles property/method/super/class/module/global *names* through the same
   `core.make_string_value` every string literal uses (`compiler/expr.odin`,
   `compiler/stmt.odin`) — so a property/method name over 40 bytes would, under the plain
   length split, get a *different*, non-interned object every time it's compiled in a
   separate chunk, silently breaking `Instance.fields`/`Class.methods` lookups for that
   name specifically. Fixed with a new `core.make_interned_string_value(s)` — always
   interns regardless of length, used at every identifier-name compile site instead of
   `make_string_value`. `core/bc_cache.odin`'s bytecode-cache deserializer also switched to
   it for its generic `.String` constant case: a cached chunk's constant pool can't
   distinguish "this was an identifier" from "this was a literal value" once serialized,
   so always-intern-on-cache-load is the safe choice (the cost: a long string *literal*
   loaded from a `.lxc` cache stays permanently interned rather than getting the
   length-split treatment a fresh compile would give it — bounded by source size, not
   external data, so not a regression against the actual leak this change exists to fix).

## Verification

- `odin test src/core -define:ODIN_TEST_THREADS=1` — new tests in `object_test.odin`
  covering: a ≤40-byte `make_string_value` call still hits `intern_string` (same pointer,
  not `collectible`); a >40-byte call is `collectible` and *not* deduplicated (two calls
  with equal content return different pointers); those two still compare `==` correctly
  despite being different objects.
- `tests/new_tests/test_string_interning.py` — `dict_long_string_key.lox` (a dict keyed by
  an independently-built >40-byte string, looked up/`in`/`.get()`/`.remove()`'d via an
  equal-content literal); `long_identifier_names.lox` (a >40-char property name set in one
  method, read back in another, on a real `Instance`).
- Full `python -m pytest tests/new_tests/` — no regressions (235 passed / 26 skipped,
  unchanged skip set).
- `scratch/client.lox`/`scratch/server.lox` (a real `socket` file-transfer demo) re-run
  end to end post-fix: 20 GET responses including a 43KB file sent twice, byte-correct,
  clean shutdown.
