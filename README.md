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
- **Dictionaries** — `get(k, default)`, `keys()`, `remove()`.
- **Strings** — `${expr}` interpolation, `format()`, `&` concat, `*` repeat, slicing, `in`, `replace`, `join`; all interned.
- **Native vectors** `vec2` / `vec3` / `vec4` — a dedicated value tag gives `+`, `.add()` (in-place addition), and `.set()` (in-place replacement) a fast dispatch path distinct from generic object method calls.
- **`float_array`** — fast native 2D float grid, with bulk RGB-encode/decode helpers for image and data work.

**Classes**
- **`toString()`** magic method, **static methods**, **class variables** (`static x = expr;`, shared across instances, inherited via the superclass chain on read), and the **iterator protocol** (`__iter__` / `__next__`).

**Native & graphics**
- **Raylib `window`** — 2D and 3D primitives, camera, textures, render textures, images, shaders (custom GLSL, uniform binding, shader/blend modes), keyboard input.
- **Batch rendering** — `batch()` draws thousands of primitives per call; `batch_instanced()` draws 100k+ instanced textured cubes.
- **`physics_world`** — native 3D rigid-body sphere/box simulation (gravity, boundary bounce, collisions).
- **Native fractal generators** — `lox_julia_array`/`lox_mandel_array` compute Julia and Mandelbrot sets directly into a `float_array`, parallelized across CPU cores, fast enough for real-time zoom/pan.
- **File & directory I/O** via `os`; PNG output; RGB encode/decode.
- **Regex** via `re` (`search`/`match`/`fullmatch`/`sub`/`subn`/`split`/`findall`/`compile`) and a minimal **`json`** module (`encode`/`decode`/`load`) built on it.
- **Built-in modules** — `math`, `random`, `colour`, `string`, `itertools`, `functools`, `logging`, `particle_sys`, `sprite`, `plot_grey`, `plot_rgb`, `re`, `json`, `pickle`, `sys`, `os`, `inspect`, `gfx` (graphics constructors: `window`, `batch`, `texture`, `shader`, `camera`, …), `physics` (`physics_world`), `colour_utils` (native colour math backing `colour`). Import with `from gfx import *` or `import gfx`.

**Concurrency**
- **`process`** — spawns separate OS worker processes and communicates over `send()`/`recv()` (values pickled across the pipe); real fault isolation, at one-process-per-worker cost.
- **`pool`** — `ProcessPool`, a fixed-size worker pool with a `map(tasks)` convenience API built on `process`.

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

---

## Testing

```bash
. ./setenv
python -m pytest tests/new_tests/ -q
```

Tests live in `tests/new_tests/` — one Python module per language feature, each running a `.lox` script and making semantic assertions on the output. The `.lox` scripts used by the tests are in `tests/new_tests/lox/`.

---

**Authorship**

Implemented in Odin, developed with the assistance of Claude Code (Anthropic).

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

**Where the remaining gap comes from.** The object-heavy end of the suite is the honest bottleneck: `Instance_Object.fields` and `Class_Object.methods`/`statics` are hash maps keyed by interned string pointers, so a user-defined class's property and method access pays a hash-map lookup per access — a monomorphic inline cache on `Get_Property`/`Invoke` short-circuits the *method*-table half of that for a stable receiver class, but there is no equivalent for instance *fields*, since Lox instances have no fixed shape and a field masking a method on one instance says nothing about another instance of the same class. `binary_trees`/`trees` build and tear down deep object graphs continuously, so this cost dominates; `collections` spends a third of its time in dictionary operations against the same underlying hash-map machinery. CPython's own attribute lookup and dict implementation are the product of decades of targeted optimization and are a genuinely hard target to beat at that specific job. The arithmetic/dispatch-heavy end of the suite (`loop`, `fib`, `invocation`, `equality`) tells a different story: a 16-byte tagged-union `Value`, slot-indexed globals (no hash lookup for `Get_Global`/`Set_Global`), and runtime-specialized numeric opcodes close — or in some cases close and reverse — the gap against CPython's own bytecode interpreter entirely.

Optimisations in place:
- **16-byte `Value` struct** — a tagged union where the payload (an object pointer or a raw `int`/`float`/`bool` bit pattern) shares one 8-byte slot with no unsafe code required, plus a 1-byte type tag and a cached object-subtype tag for O(1) dispatch on the concrete kind of any heap value.
- **Slot-indexed globals** — globals are stored in a slice indexed by a compiler-assigned integer slot rather than looked up by name at runtime; `Get_Global`/`Set_Global` are a direct slice index, not a hash-map lookup.
- **String interning** with pointer-identity equality for fast method, property, and global lookup.
- **Peephole superinstructions** — `Get_Local, Get_Local, Add` collapses to a single `Add_Nn` superinstruction, runtime-specialized to `Add_Ii`/`Add_Ff` on first execution (a minimal inline cache that patches the opcode byte in place); a matching optimisation handles `local = local + constant` via `Incr_Const_I`/`Incr_Const_F`.
- **Monomorphic inline cache** on `Get_Property`/`Invoke` — a same-class repeat access at a call site skips the method-table lookup entirely after the first hit.
- **Call frames stored inline** in the VM's own fixed-size array, not heap-allocated, avoiding per-call GC pressure.
- **Frame context hoisted** out of the dispatch loop's hot path and refreshed only at opcodes that actually change the active frame.
- **Native fast paths** — performance-critical operations (physics simulation, bulk float-array-to-texture upload, Julia/Mandelbrot fractal generation) are implemented natively rather than expressed as Lox loops; the fractal generators are additionally parallelized across CPU cores, one worker per core.
