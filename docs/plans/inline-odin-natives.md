# Inline-compiled Odin natives (`inline.odin(source)`)

Design record for a speculative feature, not tied to any `ROADMAP.md`/`TODO.md` phase: a Perl
`Inline::C`-style mechanism that lets a `.lox` script embed a snippet of native Odin source, have odlox
compile it to a shared library at runtime, and call it as an ordinary Lox function. Grounded in a direct
read of odlox's current native-function machinery and bytecode-cache precedent, not assumed.

**Status**: design only. Nothing below is implemented.

## Why this, why now

Unlike `bytecode-cache.md` or `pool-allocator.md`, this isn't chasing glox parity or a measured
bottleneck — it's a new capability with no equivalent in the reference implementation. The motivation is
that odlox's own native-function ABI (`core.Builtin_Fn`) already makes this unusually cheap to build
compared to the same idea in other embedded languages: Python/Perl/Ruby all pay a real marshalling tax at
the C boundary because the host and the extension language are different languages. odlox's host and
"extension" language are both Odin, so there is no such boundary — an inline-compiled snippet is just
another native function, compiled just-in-time instead of ahead-of-time. This doc exists to write that
design down before any code exists, per this project's practice of planning non-trivial features up front.

## Current state

### The native-function ABI this plugs into

Every hand-written native function — every `natives/*.odin` file, every core builtin in
`vm/builtins.odin` — implements the same shape, `core.Builtin_Fn` (`core/obj_native.odin`):

```odin
Builtin_Fn :: #type proc(argc: int, arg_stack_ptr: int, vm: rawptr) -> Value
```

`vm` is a bare `rawptr`, not `^vm.VM`, because `core` sits below both `compiler` and `vm` in the package
graph and cannot name that type — every native casts it back via `vm.native_vm(vm_ptr)` (`vm/builtins.odin`),
the one place that boundary is crossed. `core.make_native_object(fn)` wraps a `Builtin_Fn` into a
`Native_Object`; `vm.define_builtin(vm, module, name, fn)` interns it as a global or a builtin-module member
(`vm.make_builtin_module` creates the module first). This is the exact, unmodified mechanism an
inline-compiled function needs to land in — nothing about registration changes for this feature.

### The boilerplate this feature exists to eliminate

`natives/colour_utils.odin`'s functions are pure Odin with no raylib dependency, and each one hand-writes
the same shape:

```odin
colour_utils_fade :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 4 {
		vm.runtime_error(v, "fade expects 4 arguments (r, g, b, alpha)")
		return core.NIL_VALUE
	}
	r_val, g_val, b_val, alpha_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2], v.stack[arg_stack_ptr + 3]
	if !core.is_number(r_val) || !core.is_number(g_val) || !core.is_number(b_val) || !core.is_number(alpha_val) {
		vm.runtime_error(v, "fade arguments must be numbers")
		return core.NIL_VALUE
	}
	r := clamp255(core.as_float(r_val))
	...
}
```

argc check, per-argument stack read, per-argument type check, unwrap, call the real logic, repack the
result. This is exactly the code a marshalling-wrapper generator needs to emit — not a new runtime
mechanism, just automating a pattern that already exists four times over in this one file alone.

### `core.Value`'s accessor surface (`core/value.odin`)

The generated wrapper's vocabulary is entirely existing procs, nothing new:

- `is_int`/`as_int`, `is_number`/`as_float`, `is_string`/`as_string`+`string_get`, `is_bool`/`as_bool` —
  checks and unwraps.
- `make_int_value`, `make_float_value`, `make_string_value`, `make_bool_value` — repacking a native return
  value back into a `Value`.

### Caching precedent (`core/bc_cache.odin`, `docs/plans/bytecode-cache.md`)

odlox already has one content-cached compiled-artifact pipeline: `.lxc` bytecode caching for imported
modules. Its governing discipline — content-addressed rather than trusted blindly, a magic/version header,
never a hard failure on a bad cache (always fall back to recompiling), self-healing via overwrite — is the
right template for caching a compiled DLL instead of a compiled `Function_Object` tree. The concrete byte
format doesn't transfer (this caches a build artifact, not a value tree) but the *posture* does.

### Compiler discovery (`bin/build.sh`)

```sh
ODIN=odin
if ! command -v "$ODIN" >/dev/null 2>&1; then
	ODIN="$HOME/AppData/Local/Programs/Odin/odin.exe"
fi
```

The existing, already-relied-upon convention for locating the Odin compiler: prefer `PATH`, fall back to
the known install location on this machine. A runtime invocation from inside odlox itself should mirror
this exactly rather than inventing a second convention.

## Design

### Layer 1: compile-and-cache pipeline

1. Hash the embedded snippet's source text.
2. Look for `<script_dir>/__odlox_inline_cache__/<hash>.dll`, mirroring `bc_cache`'s
   `<module_dir>/__loxcache__/` placement (same reasoning: co-located with what produced it, hash-named so
   concurrent/partial writes can't collide with a different snippet's cache entry — a torn write just fails
   to load as a valid DLL, treated as a cache miss like any other bad-cache case).
3. On a hit, skip straight to step 5.
4. On a miss: write the snippet plus its generated wrapper (layer 2) into a scratch package directory —
   `package inline_snippet_<hash>`, `import "../../core"`, `import "../../vm"` — then invoke
   `odin build <dir> -build-mode:dll -out:<cache_dir>/<hash>.dll` using the `build.sh`-style
   PATH-then-fallback compiler discovery above. Keep both the generated `.odin` source and the resulting
   `.dll` in the cache directory (not just the artifact) — cheap, and the generated wrapper source is the
   first thing worth inspecting if a snippet misbehaves.
5. Load the DLL via `core:dynlib` (`dynlib.load_library`, then `dynlib.symbol_address(lib, "lox_native")` —
   a fixed, documented export name; there's no discovery step, the loader always looks for exactly this
   symbol).
6. Cast the resulting `rawptr` to `core.Builtin_Fn`, wrap it with `core.make_native_object`, and return
   `core.make_object_value(&native.obj)` — indistinguishable, from the VM's point of view, from any
   hand-written native.

### Layer 2: hidden marshalling

The snippet author writes a plain, ordinary-looking Odin function:

```odin
lox_fn :: proc(r, g, b, alpha: f64) -> f64 {
	return math.min(255, math.max(0, r)) * math.min(1, math.max(0, alpha))
}
```

Before invoking the compiler, parse the snippet with Odin's own `core:odin/parser`/`core:odin/ast` (Odin
ships a real parser as a library — this is what tools like `odinfmt` build on) and extract `lox_fn`'s
parameter names, parameter types, and return type from the actual AST. Using the real parser instead of a
hand-rolled signature scanner avoids the usual fragility of that approach (whitespace, multi-line
signatures, comments between parameters) for close to zero extra cost, since the parser is already a
dependency-free standard package.

Validate every extracted type against a fixed whitelist — `int`, `f64`, `string`, `bool` — **before** ever
invoking `odin build`. An unsupported type (a struct, `^Obj`, a slice) is rejected immediately with a clear
message; the compiler is never given a chance to produce a confusing build error for something the
signature scan already knows is unsupported.

From a validated signature, generate a second proc and splice it into the same scratch package:

```odin
@(export)
lox_native :: proc "c" (argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 4 {
		vm.runtime_error(v, "lox_fn expects 4 arguments (r, g, b, alpha)")
		return core.NIL_VALUE
	}
	a0 := v.stack[arg_stack_ptr + 0]
	a1 := v.stack[arg_stack_ptr + 1]
	a2 := v.stack[arg_stack_ptr + 2]
	a3 := v.stack[arg_stack_ptr + 3]
	if !core.is_number(a0) || !core.is_number(a1) || !core.is_number(a2) || !core.is_number(a3) {
		vm.runtime_error(v, "lox_fn arguments must be numbers")
		return core.NIL_VALUE
	}
	result := lox_fn(core.as_float(a0), core.as_float(a1), core.as_float(a2), core.as_float(a3))
	return core.make_float_value(result)
}
```

This is generated text, byte-for-byte the same shape `colour_utils_fade` already is by hand. The type table
the generator works from:

| declared type | check | unwrap | wrap (return) |
|---|---|---|---|
| `int` | `core.is_int` | `core.as_int` | `core.make_int_value` |
| `f64` | `core.is_number` | `core.as_float` | `core.make_float_value` |
| `string` | `core.is_string` | `core.string_get(core.as_string(v))` | `core.make_string_value` |
| `bool` | `core.is_bool` | `core.as_bool` | `core.make_bool_value` |

**Escape hatch**: if the snippet defines `lox_native` directly, with the real `Builtin_Fn` signature,
instead of `lox_fn`, codegen is skipped entirely and the proc is exported as written. This covers anything
outside the whitelist — GC-tracked allocation via `vm.alloc_vec4`-style helpers, `Vec4`/list/dict values,
multiple return values, direct stack manipulation — the same tier of access every hand-written native in
`natives/*.odin` already has, just written by the script author instead of ahead of time.

### Registration surface

A new `natives/inline_odin.odin`, following the exact pattern `register_colour_utils` sets in
`natives/natives.odin`:

```odin
register_inline_odin :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "inline")
	vm.define_builtin(v, "inline", "odin", inline_odin_builtin)
}
```

Lox-facing usage:

```
import inline;
var fast_sum = inline.odin("""
lox_fn :: proc(a, b, c: int) -> int {
    return a + b + c
}
""");
print fast_sum(1, 2, 3);
```

### Odin-specific caveats (documented, not solved here)

- **`context` crosses the DLL boundary.** A dynamically loaded Odin DLL does not inherit the host process's
  `context` (allocator, temp allocator, logger) automatically. Since a `lox_fn`-generated wrapper calls back
  into `vm.native_vm`/`vm.runtime_error`/GC-linked allocation helpers, the loader needs to ensure the correct
  context is in effect across the call, not assume the DLL's own default.
- **Runtime compiler dependency.** This only works where the Odin compiler is actually reachable (`PATH` or
  the known fallback path) — a dev-machine/trusted-environment feature, not something a distributed odlox
  binary should assume is available.
- **Compile latency makes caching load-bearing, not optional.** Even a trivial snippet's build is not free;
  without the cache in layer 1, any loop calling `inline.odin(...)` on first use would be unusable.
- **Unsandboxed code execution, by construction.** A script that can embed and compile Odin has full native
  code execution. This is noted as an inherent property of the feature, not a defect to guard against —
  consistent with this project's existing stance on unguarded speculative features for a personal language.

## Implementation order

1. **Compile-and-cache pipeline only**, requiring the raw `lox_native` escape-hatch signature by hand (no
   codegen yet). Proves the hash → build → `dynlib` load → cache-hit loop end-to-end before any AST work
   exists.
2. **AST-based signature extraction + marshalling-wrapper generation** for `lox_fn`, whitelist-checked
   before the compiler is invoked.
3. **`inline` module registration wiring** (`natives/inline_odin.odin`, `define_natives`).

## Verification plan

Not run yet — documented for whoever implements this:

- A `.lox` fixture calling `inline.odin(...)` twice with byte-identical source: the second call must hit the
  cache (no recompile — observable via the `.dll`'s mtime not changing, or a debug counter on the compile
  path).
- The same fixture with the source changed between calls: must miss and rebuild.
- One case per whitelist type (`int`, `f64`, `string`, `bool`) as both a parameter and a return type, via
  the codegen path (not the escape hatch).
- A snippet using the escape hatch (`lox_native` written directly) alongside one using `lox_fn`, confirming
  codegen is actually skipped for the former.
- A snippet with an unsupported parameter/return type: must fail before `odin build` runs, with a message
  naming the offending type — not a raw Odin compiler error surfaced to Lox code.
