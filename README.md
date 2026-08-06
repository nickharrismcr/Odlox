# odlox

**A bytecode interpreter for the Lox language, implemented in Odin**

---

The aim of this project is to learn more deeply about programming in Odin and the crafting of interpreters by way of implementing a clox-style bytecode virtual machine — following the design Bob Nystrom builds in *Crafting Interpreters* — and extending it with Python-inspired features along the way.
The extensions to the language include enhanced string operations, lists, dictionaries, exception handling, module imports, string and list iteration, lambda functions, Raylib bindings for graphics, and I/O.

📖 **[Full language reference: `docs/language-reference.html`](docs/language-reference.html)** — a guide to the syntax, built-in types and functions, native objects, and library modules. Open it in a browser.

### Additions to vanilla Lox

Feature summary — see the **[language reference](docs/language-reference.html)** for full syntax, methods, and examples.

**Language**
- **Optional semicolons** — a newline or a closing `}` terminates a statement; braced blocks may be written on one line.
- **Implicit variable declaration** (`a = 1`) and **`const`** immutables.
- **Integer type** with `%` modulus, distinct from float.
- **Destructuring / unpacking assignment** — `a, b, c = [1, 2, 3]`.
- **Compound assignment** — `+=`, `-=`, `*=`, `/=`, `%=`, `++`.
- **Ternary / conditional expression** — `cond ? a : b` (C-style, right-associative).
- **String interpolation** — `"total: ${count} (${pct}%)"` in either quote style; `$$` escapes a literal `$`; string literals may also span multiple lines.
- **`break` / `continue`**, and **`foreach`** over lists, strings, and iterables (`__iter__`/`__next__`).
- **`range(start, end, step)`** — native integer iterator, faster than an equivalent `for`.
- **Anonymous functions (lambdas)** — `func (x) { ... }` as expressions; full closures.
- **Default & variadic parameters** — `func f(a, b=expr)` (defaults evaluated at call time) and a trailing `*rest` that collects surplus positional arguments into a list.
- **Exceptions** — `try` / `except` / `finally`, `raise`, custom `Exception` subclasses, catchable runtime errors.
- **Module imports** — `import m`, `import m as alias`, `from m import ...`; a project's own modules resolve alongside the entry script and recursively through its subdirectories, so they can be grouped into subfolders freely. Imported modules are cached as compiled bytecode (`__loxcache__/*.lxc`, invalidated on source change); `--force-compile` bypasses a stale-looking cache for one run.

**Types & operators**
- **Lists** — slicing, slice assignment, `&` concatenation, `in` membership, `append`/`remove`.
- **Tuples** — immutable sequences.
- **Dictionaries** — `get(k, default)`, `keys()`, `remove()`, `in` key membership.
- **Strings** — `${expr}` interpolation, `format()`, `&` concat, `*` repeat, slicing, `in`, `replace`, `join`; short strings (≤40 bytes — identifiers, small literals/values) are interned to a canonical object, longer ones are ordinary garbage-collected values.
- **Native vectors** `vec2` / `vec3` / `vec4` — inlined directly into the value representation (no heap allocation, no GC involvement, true copy semantics), the same way `int`/`float`/`bool` are.
- **`float_array`** — fast native 2D float grid, with bulk RGB-encode/decode helpers for image and data work.

**Classes**
- **`toString()`** magic method, **static methods**, **class variables** (`static x = expr;`, shared across instances, inherited via the superclass chain on read), and the **iterator protocol** (`__iter__` / `__next__`).

**Native & graphics**
- **Raylib `window`** — 2D and 3D primitives, camera, textures, render textures, images, shaders (custom GLSL, uniform binding, shader/blend modes), keyboard and mouse input.
- **Batch rendering** — `batch()` draws thousands of primitives per call; `batch_instanced()` draws 100k+ instanced textured cubes, lit by up to 4 `instanced_light()`s plus `instanced_ambient()`.
- **`physics_world`** — native 3D rigid-body sphere/box simulation (gravity, boundary bounce, collisions).
- **`box2d`** — wraps Odin's Box2D v3 bindings: 2D circle/box bodies (static/kinematic/dynamic), forces/impulses/torque, and collision events.
- **File & directory I/O** via `os`; PNG output; RGB encode/decode.
- **Regex** via `re` (`search`/`match`/`fullmatch`/`sub`/`subn`/`split`/`findall`/`compile`) and a minimal **`json`** module (`encode`/`decode`/`load`) built on it.
- **Built-in modules** — `math`, `random`, `colour`, `string`, `itertools`, `functools`, `logging`, `particle_sys`, `sprite`, `plot_grey`, `plot_rgb`, `re`, `json`, `pickle`, `sys`, `os`, `inspect`, `gfx` (graphics constructors: `window`, `batch`, `texture`, `shader`, `camera`, …), `physics` (`physics_world`), `box2d` (`box2d.world`), `colour_utils` (native colour math backing `colour`). Import with `from gfx import *` or `import gfx`.

**Concurrency**
- **`process`** — spawns separate OS worker processes and communicates over `send()`/`recv()` (values pickled across the pipe); real fault isolation, at one-process-per-worker cost. `process.start()` launches a pipeless companion process instead, for one that does its own I/O (e.g. over a `socket`).
- **`pool`** — `ProcessPool`, a fixed-size worker pool with a `map(tasks)` convenience API built on `process`.
- **`socket`** — raw TCP sockets (`connect`/`listen`/`accept`/`send`/`recv`, plus non-blocking `try_accept`/`try_recv`) for IPC with any process, not just another odlox instance; a lower-level alternative to `process`'s pickled-value pipe.

---

## Requirements

- The [Odin](https://odin-lang.org) compiler, installed and on `PATH`. Building the latest version from source is recommended.
- Python 3 — optional, only needed to run the test suite (see Testing below).

---

## Build

```bash
# Debug build -- -vet/-strict-style lints, and the --debug/--instrument trace hooks compiled in
bin/build.sh

# Release build -- -o:speed -disable-assert -no-bounds-check, no trace hooks
bin/build.sh --release
```

```bash
# Run a script
bin/odlox.exe script.lox

# Start the REPL
bin/odlox.exe --repl

# Set LOX_PATH so module imports resolve
. ./setenv.ps1     # PowerShell
. ./setenv          # bash
```

Run `bin/showcase.sh` (after `. ./setenv`, from the repo root) to build a release binary and run through the graphics demos in `lox_examples/` one after another — press `Esc` to close the current demo and move on to the next.

---

## Testing

```bash
. ./setenv
python -m pytest tests/new_tests/ -q
```

Tests live in `tests/new_tests/` — one Python module per language feature, each running a `.lox` script and making semantic assertions on the output. The `.lox` scripts used by the tests are in `tests/new_tests/lox/`. This is the project's actual correctness gate.

### Odin unit tests

```bash
odin test src -all-packages -define:ODIN_TEST_THREADS=1
```

`-define:ODIN_TEST_THREADS=1` is required, not optional — always include it. This codebase's global state (`core/obj_string.odin`'s string-interning table, `vm/module.odin`'s module caches) is deliberately single-threaded by design (see `docs/ARCHITECTURE.md`'s Scope section), and the test runner's default 16-thread parallelism races on it. It isn't a workaround for flakiness; it's running the tests the way the VM is actually meant to run.

Even single-threaded, this suite is a known, not-fully-reliable secondary check, not a substitute for `pytest` above: `vm/module.odin`'s `module_cache` holds GC-managed values allocated through the test runner's short-lived per-task allocator, which can still produce a rare hang or segfault unrelated to any real bug in a change under test. See `TODO.md`/`ROADMAP.md` (Phase 0) for the full root-cause writeup.

---

**Authorship**

Implemented in Odin, developed with the assistance of Claude Code (Anthropic).

---

## Compiler Architecture

clox compiles Lox source to bytecode in a single pass: a Pratt parser recognizes grammar, resolves names/scopes, and emits bytecode all in the same walk over the token stream, with no intermediate representation ever built. `odlox`'s compiler (`src/compiler/`) instead runs three explicit phases:

1. **Parse** (`parser.odin`, `rules.odin`, `expr.odin`, `stmt.odin`, `functions.odin`) — a Pratt parser identical in structure to clox's, except prefix/infix functions build and return AST nodes (`ast.odin`) instead of writing bytecode.
2. **Resolve** (`resolve.odin`) — walks the AST, annotating each node in place with its resolved scope (local slot, upvalue index, or global slot) and running every validity check that needs more than the current token to decide (duplicate declarations, break/continue outside a loop, `this`/`super` outside a class, const reassignment, and so on).
3. **Emit** (`emit.odin`, `emit_expr.odin`, `emit_stmt.odin`) — walks the resolved AST and generates bytecode into the same `core.Chunk`/`Op_Code` target clox-style compilation would have produced directly.

This is to facilitate possible future compiler enhancements such as optional typing.

---

## Performance Notes

Benchmarks run via `bin/benchmarks.sh` (the loxcraft suite: arithmetic, object/class dispatch, collections, and recursion). All numbers are from the release build (see **Build** above), measured back-to-back in one sitting, 3-run averages.

| benchmark | odlox | CPython | odlox / CPython |
|---|---|---|---|
| binary_trees | 23.59s | 7.40s | 3.19× |
| collections | 5.33s | 2.95s | 1.81× |
| equality | 27.68s | 20.86s | 1.33× |
| fib | 10.11s | 9.17s | 1.10× |
| instantiation | 33.19s | 22.38s | 1.48× |
| invocation | 8.82s | 9.38s | 0.94× |
| loop | 2.60s | 3.59s | 0.72× |
| method_call | 12.68s | 8.82s | 1.44× |
| properties | 11.49s | 8.09s | 1.42× |
| string_equality | 22.02s | 17.49s | 1.26× |
| trees | 26.75s | 6.90s | 3.88× |
| zoo | 10.32s | 10.10s | 1.02× |
| zoo_batch | 10.01s | 10.02s | 1.00× |

A ratio below 1.00× means odlox is faster. Across the suite: 1.58× arithmetic mean, 1.41× geometric mean, 1.49× by total time. odlox is at or ahead of CPython on `loop`, `invocation`, and `zoo`/`zoo_batch`; furthest behind on `binary_trees`/`trees` (deep object-tree construction and traversal) and `collections` (dictionary-heavy code).

**Where the remaining gap comes from.** The object-heavy end of the suite is dominated by one cost: `Instance_Object.fields` and `Class_Object.methods`/`statics` are hash maps keyed by interned string pointers, so a user-defined class's property and method access pays a hash-map lookup per access — a monomorphic inline cache on `Get_Property`/`Invoke` short-circuits the *method*-table half of that for a stable receiver class, but there is no equivalent for instance *fields*, since Lox instances have no fixed shape and a field masking a method on one instance says nothing about another instance of the same class. `binary_trees`/`trees` build and tear down deep object graphs continuously, so this cost dominates; `collections` spends a third of its time in dictionary operations against the same underlying hash-map machinery. CPython's own attribute lookup and dict implementation are the product of decades of targeted optimization and are a difficult target to beat at that specific job. The arithmetic/dispatch-heavy end of the suite (`loop`, `fib`, `invocation`, `equality`) tells a different story: slot-indexed globals (no hash lookup for `Get_Global`/`Set_Global`) and runtime-specialized numeric opcodes close — or in some cases close and reverse — the gap against CPython's own bytecode interpreter entirely.

Optimisations in place:
- **Slot-indexed globals** — globals are stored in a slice indexed by a compiler-assigned integer slot rather than looked up by name at runtime; `Get_Global`/`Set_Global` are a direct slice index, not a hash-map lookup.
- **String interning** (strings ≤40 bytes — identifiers, small values) with pointer-identity equality for fast method, property, and global lookup; longer strings are ordinary garbage-collected values instead of growing the intern table forever.
- **Peephole superinstructions** — `Get_Local, Get_Local, Add` collapses to a single `Add_Nn` superinstruction, runtime-specialized to `Add_Ii`/`Add_Ff` on first execution (a minimal inline cache that patches the opcode byte in place); a matching optimisation handles `local = local + constant` via `Incr_Const_I`/`Incr_Const_F`.
- **Monomorphic inline cache** on `Get_Property`/`Invoke` — a same-class repeat access at a call site skips the method-table lookup entirely after the first hit.
- **Call frames stored inline** in the VM's own fixed-size array, not heap-allocated, avoiding per-call GC pressure.
- **Frame context hoisted** out of the dispatch loop's hot path and refreshed only at opcodes that actually change the active frame.
- **Native fast paths** — performance-critical operations (physics simulation, bulk float-array-to-texture upload) are implemented natively rather than expressed as Lox loops.
