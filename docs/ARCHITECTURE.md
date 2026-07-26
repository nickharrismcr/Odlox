# odlox architecture

Design record for the Odin port of [glox](https://github.com/nickharrismcr/glox)
(branch `experimental/gc-odin-port-basis`). Written before any code exists —
this is the blueprint, kept up to date as decisions change. Read
[`ROADMAP.md`](../ROADMAP.md) for the phased build order; this file is the
"why/what shape" reference for when you're modifying the port later and need
to know why a piece is shaped the way it is.

Grounded in a line-by-line reading of the source branch, in particular
`src/core/{value,object,chunk,types,environment,gc_registry,copy}.go`,
`src/vm/{vm,gc,builtin,bc_cache}.go`, `src/compiler/{scanner,compile}.go`,
and the project's own `docs/performance-roadmap.md` /
`docs/exception-handling.md`. Where this document says "glox does X", that's
the Go reference implementation on that branch; where it says "odlox will
do Y", that's this port's design decision.

## Table of contents

1. [Scope](#scope)
2. [Package layout](#package-layout)
3. [Value representation](#value-representation)
4. [Object model](#object-model)
5. [Garbage collector](#garbage-collector)
6. [Environment & globals](#environment--globals)
7. [Chunk, opcodes, bytecode](#chunk-opcodes-bytecode)
8. [Scanner](#scanner)
9. [Compiler](#compiler)
10. [VM dispatch loop & calling convention](#vm-dispatch-loop--calling-convention)
11. [Exceptions](#exceptions)
12. [Modules & imports](#modules--imports)
13. [Native/builtin functions](#nativebuiltin-functions)
14. [Bytecode cache (.lxc)](#bytecode-cache-lxc)
15. [Test strategy](#test-strategy)
16. [Performance: what Odin allows that Go didn't](#performance-what-odin-allows-that-go-didnt)

---

## Scope

Explicitly **out of scope** for this port, per the porting brief:

- **Threads.** No `thread.spawn`/`thread.channel`/`sync.Mutex`. This removes,
  wholesale, everything in glox's `src/core/thread.go`, `src/vm/thread.go`,
  `src/builtin/obj_builtin_thread.go`, `obj_builtin_sync.go`,
  `thread_functions.go`, `thread_methods.go`, `sync_functions.go`,
  `sync_methods.go`, and `src/core/copy.go` (the deep-copy-for-spawn
  machinery). None of it needs an Odin equivalent, not even a stub.
- **Thread safety.** The VM is single-goroutine — sorry, single-threaded —
  for its whole life. Every `sync.Mutex`/`sync.RWMutex`/`atomic` in glox
  exists *only* to make some shared structure safe under `thread.spawn`
  (`Environment.varsMu`, the module-cache mutex, `liveClassesMu`/
  `liveModulesMu`, the `stringDepth` atomic in `obj_list.go`/`obj_dict.go`).
  None of it is ported; odlox's equivalents are plain unsynchronized fields.
- **Graphics/native modules** (raylib window/texture/shader/batch/camera/
  render_texture/image, physics, regex, pickle, process, os file I/O beyond
  the basics) are a later phase (see ROADMAP Phase 6+), layered on top of a
  working core VM. This document's core sections (2–13) are unaffected by
  when/whether that phase happens.
- **The `.lxc` bytecode cache** is deferred — see
  [Bytecode cache](#bytecode-cache-lxc) for why.

**In scope**, matching glox's actual language surface (per
`docs/language-reference.html`): scanner → single-pass Pratt compiler → VM,
lists/dicts/tuples/slices, closures/upvalues, classes with single
inheritance, exceptions (`try`/`except`/`finally`), module imports,
`foreach`/`range` and the user-level iterator protocol, string
interpolation, default/variadic parameters, destructuring assignment,
`vec2`/`vec3`/`vec4`, integer *and* float numeric types, and a real
mark-and-sweep garbage collector.

---

## Package layout

**Odin supports this directly — the Go package graph can be replicated
almost 1:1.** Any directory is an importable package (`import "core"` for a
sibling directory named `core`, or a relative path); the `examples` repo
confirms this is a normal, idiomatic pattern (e.g.
`raylib/ports/shaders/shaders_mesh_instancing.odin` imports the sibling
`rlights` package by bare name). There's no requirement to flatten
everything into one `package main`, unlike this user's smaller game
projects (`defender` is one flat `package main` because it's ~4k lines with
no natural seams) — an interpreter this size benefits from the same
separation glox itself chose, for the same reason: each layer only needs to
know about the one below it.

```
odlox/
├── src/
│   ├── main.odin           package main    — CLI arg parsing, REPL loop, wires native registration
│   ├── core/                package core    — Value, Object model, Chunk/opcodes, Environment, interning
│   ├── compiler/             package compiler — Scanner, Parser/Pratt compiler   (imports core)
│   ├── vm/                   package vm      — VM struct, dispatch loop, GC, core builtins, module import
│   │                                            (imports core, compiler)
│   ├── natives/              package natives — raylib-backed native objects/functions, Phase 6+
│   │                                            (imports core, vm)
│   └── debug/                package debug   — disassembler, execution tracer   (imports core)
└── docs/
```

(All Odin sources live under `src/` — `odin build src`/`odin test src/compiler` etc.
— keeping the repo root free for `README.md`/`ROADMAP.md`/`docs/`.)

Dependency direction is a strict DAG, same as glox's:
`core ← compiler ← vm ← natives`, with `debug` hanging off `core` alone and
`main` at the top wiring everything together. No cycles anywhere.

### The one real translation wrinkle: `core.VMContext`

Glox's `src/core/object.go` defines a `VMContext` interface (`Stack`,
`RunTimeError`, `Peek`, `GCLink`, `SpawnThread`, ...) specifically so that
`src/builtin/*.go` (the large raylib-dependent package) can implement
native functions — `type BuiltInFn func(argCount, arg_stackptr int, vm
VMContext) Value` — **without importing `src/vm`**, breaking what would
otherwise be an import cycle (`vm` would need `builtin`'s native
registration, `builtin` needs to call back into the VM). This same
`BuiltInFn` type is also what `core.BuiltInObject` (a heap object in the
core object model) carries as its callable field — so in Go, `core`
itself never needs to import `vm` either, for the same interface reason.

**Odin has no structural interfaces**, so this needs two separate fixes,
not one — discovered in practice while implementing `core`'s object model
(Phase 2), where the first-pass plan below turned out to only solve half
of it:

1. **`natives` importing `vm` directly**, taking a concrete `^vm.VM`
   rather than an abstract context, with `vm` exposing plain procs
   (`vm_stack`, `vm_peek`, `vm_runtime_error`, `vm_gc_link`, ...) and a
   registration entry point (`vm.register_native :: proc(module, name:
   string, fn: Builtin_Fn)`) that `main.odin` calls after constructing the
   VM. This part of the original plan holds up fine — `vm` never imports
   `natives`, so there's no cycle on that side.
2. **What it doesn't fix**: `core.Native_Object` (see `obj_native.odin`)
   still needs a field typed as "a callable that takes the VM" — and
   `core` sits *below* both `compiler` and `vm` in the package graph
   (`vm` depends on `compiler` for module-import recompilation, and both
   depend on `core` for `Value`/`Chunk`), so `core` cannot import `vm` to
   spell that field as `^vm.VM` any more than it could in the interface
   case. The actual fix: `Builtin_Fn`'s `vm` parameter is `rawptr`, and
   every native function's first line casts it back to the concrete
   `^vm.VM` — a plain opaque-pointer boundary, the same shape Odin's own
   `context.user_ptr` uses to solve this exact "lower layer must call
   back into a higher one" problem. `vm`/`natives` provide typed wrapper
   procs so call sites never write that cast themselves.

---

## Value representation

Glox's `Value` (`src/core/value.go`) is 32 bytes:

```
Obj Object          // 16 bytes — Go interface: (itab, data) fat pointer
Data uint64         // 8 bytes  — int/float64-bits/bool
InternedId int32     // 4 bytes  — cached string-intern id (fast-path equality)
Type ValueType       // 1 byte
ObjType ObjectType   // 1 byte  — cached concrete subtype (added later; see below)
Immut bool           // 1 byte
_ [1]byte            // padding
```

Glox's own `docs/performance-roadmap.md` (already read in full before this
document was written) spends a long section on why this is 32 bytes and
what a smaller representation would cost — and concludes that the cheapest
wins are available (a tag byte, done) but the big ones (`unsafe.Pointer`
instead of the interface, or pointer-free handles) are **"high risk" /
"medium-high effort" in Go specifically because Go's own tracing garbage
collector must be able to identify every pointer by static type** — smuggle
a raw pointer somewhere Go's GC doesn't expect one, and it gets collected
out from under you while still in use. That constraint is why the roadmap
calls NaN-boxing "a dead end in Go" and handles "high risk."

**That constraint does not exist for odlox.** Odin's default allocator has
no tracing collector to fool — *we* are the collector, and root-marking
(§[Garbage collector](#garbage-collector)) is done by hand, walking exactly
the structures we choose to walk. A raw pointer sitting inside a `Value` is
just a raw pointer; nothing scans memory looking for pointer-shaped bit
patterns behind our back. This is the single biggest reason the Odin port
can plausibly approach clox's performance where the Go port structurally
cannot: **every option glox's roadmap rejected as unsafe-in-Go is safe and
ordinary in Odin.**

### V1 design (safe, no unsafe code, 16 bytes)

```odin
Value_Type :: enum u8 {
    Nil,
    Bool,
    Int,
    Float,
    Obj,
    Vec2,
    Vec3,
    Vec4,
    Undefined,   // VM-internal: an omitted default-parameter slot before its default runs
}

Value :: struct {
    using payload: struct #raw_union {
        data: u64,   // int (cast), f64 bits (transmute), or bool (0/1)
        obj:  ^Obj,  // heap object pointer — meaningful iff type is Obj/Vec2/Vec3/Vec4
    },
    type:      Value_Type,
    obj_type:  Object_Type,  // cached concrete subtype; see Object model
    immutable: bool,
}
```

`size_of(Value) == 16` — the union makes `data` and `obj` share one 8-byte
slot (never both meaningful at once, exactly like clox's own `as` union),
and the three 1-byte tags round up to the next 8-byte alignment step for
free. This is **clox parity, achieved with a safe tagged union — no
`unsafe.Pointer`, no NaN-boxing, no pointer tagging** — because Odin never
needed the interface (`Obj Object`) glox's `Data`+`Obj` split existed to
work around in the first place.

Dropping `InternedId` entirely is deliberate, not an oversight — see
[Object model](#object-model): with true pointer-interning, string equality
degenerates to `a.obj == b.obj`, so there's no separate cached id to carry.

`obj_type` is kept (glox added this itself, mid-project, as "Option 1" in
its performance roadmap, specifically to avoid a vtable-style dispatch call
just to discriminate object subtypes) — in Odin there's no vtable to avoid,
but the cached byte still saves a pointer dereference (`obj.type`) at every
hot-loop discrimination site (`OP_ADD_VECTOR`, `OP_GET_PROPERTY`, equality),
which matters when that pointer is cold in cache. Free in the padding, so
there's no reason not to keep it.

### Future option: 8-byte NaN-boxing

[OrigamiDev-Pete/odinLox](https://github.com/OrigamiDev-Pete/odinLox) — an
existing from-scratch Odin port of clox itself, cross-checked during
glox's own experimental-GC design (see the doc comment atop glox's
`src/vm/gc.go`) — implements NaN-boxing in Odin successfully
(`src/value.odin`, `NAN_BOXING :: true`), confirming the technique is
practical in this language once you're not fighting a tracing GC. glox's
value model has one wrinkle clox doesn't: **separate `VAL_INT`/`VAL_FLOAT`**
rather than one `NUMBER` double (this is deliberate in glox — it's what
lets `OP_ADD_II` skip float conversion entirely on the hot integer-loop
path). Classic NaN-boxing gives the *non-tagged* case to one float type for
free; fitting a second first-class numeric type in means spending one more
tag pattern (there's room — quiet-NaN payload space is wide) to hold a
53-or-so-bit integer directly in the boxed `u64`, no heap indirection at
all for integers (an improvement over both clox and glox, where only floats
are unboxed). **Not attempted at V1** — ship correctness on the 16-byte
struct first, then revisit if profiling (see
[Performance](#performance-what-odin-allows-that-go-didnt)) says width is
still the bottleneck.

### Vec2/Vec3/Vec4 stay heap objects — but tracked correctly

A `vec3` is 24 bytes of `f64` — too big to live in the 8-byte union
payload, so it stays a heap-allocated `Obj` referenced through
`payload.obj`, same as glox. Two differences from glox's Go version:

1. Glox's own comment on `pushVec` admits vec2/3/4 objects "got a GCHeader
   for interface conformance from the start but were never actually linked
   into any VM's registry" — relying entirely on Go's real GC as a
   backstop. **Odin has no backstop GC**, so odlox must actually link every
   vec2/3/4 allocation into the real registry from day one, or they leak
   for the process lifetime. Non-optional for correctness.
2. Vector arithmetic in a tight loop (`a = a ++ vec3(2,3,4)`) is exactly
   the kind of high-churn, fixed-size, short-lived allocation a general
   `new`/`free` pair handles worst. See
   [Performance](#performance-what-odin-allows-that-go-didnt) for the
   free-list pool this motivates.

---

## Object model

Glox's `Object` (`src/core/object.go`) is a Go interface implemented by
every heap type, with a shared embedded `GCHeader{Marked bool; Next
Object}` struct providing `GetGCHeader()` via Go's method-promotion. Every
hot-loop type discrimination is `obj.GetType()` — an interface (vtable)
call — which glox's own performance roadmap identifies as tax #1 of four
distinct costs the interface representation imposes (dispatch, type-assert
cost, width, and GC-scan/write-barrier cost — see the roadmap's "Deep dive:
the `Value.Obj` interface representation" section for the full breakdown).

**Odin has no interfaces**, so this doesn't port as "find the Odin
equivalent of a Go interface" — it ports as "use the pattern Odin actually
has for a closed set of heap-object kinds," which is the same pattern
[odinLox](https://github.com/OrigamiDev-Pete/odinLox) already validates end
to end (`src/object.odin`): a common base struct, embedded via `using`, plus
an enum tag and a type switch on the concrete pointer.

```odin
Object_Type :: enum u8 {
    String, Function, Closure, Upvalue, Native,
    List, Dict, Class, Instance, Bound_Method,
    Module, File,
    // Three separate tags where glox shares one ("Iterator") across
    // three different Go structs, distinguishing them via a type switch
    // on the concrete type instead of the tag (Go's blackenObject can do
    // that; Odin's tag-then-cast dispatch convention needs the tag
    // itself to already be enough).
    List_Iterator, Int_Iterator, String_Iterator,
    Vec2, Vec3, Vec4,
}

Obj :: struct {
    type:   Object_Type,
    marked: bool,
    next:   ^Obj,   // intrusive GC list — see Garbage collector
}

Closure_Object :: struct {
    using obj: Obj,
    function:      ^Function_Object,
    upvalues:      []^Upvalue_Object,
    upvalue_count: int,
}
```

...and so on for every concrete type (`List_Object`, `Dict_Object`,
`Class_Object`, `Instance_Object`, `Bound_Method_Object`, `Upvalue_Object`,
`Function_Object`, `Module_Object`, the four iterator kinds, `Vec2/3/4_Object`).
`using obj: Obj` promotes `.type`/`.marked`/`.next` onto every concrete
struct, exactly mirroring how glox's Go structs embed `GCHeader` today —
this part of the port is closer to a straight transliteration than most.

Dispatch is a `switch obj.type { case .List: l := (^List_Object)(obj); ... }`
— one enum compare and a pointer cast, no vtable, no `reflect`. This kills
every one of the roadmap's four interface taxes at once, for free, as a
side effect of the language rather than as an optimization pass: no
dispatch call (tax #1), no type-assert check beyond the same cast a type
switch already does (tax #2), no interface width — `Value.payload.obj` is
one bare pointer, not a `(itab, data)` pair (tax #3) — and no interface-driven
GC scanning, since our own mark-sweep walks explicit fields, not "every
pointer-shaped word Go's GC finds" (tax #4).

### One correctness bug this removes for free

glox's mark phase has a documented workaround (`src/vm/gc.go`,
`markObject`): a `reflect.ValueOf(obj).IsNil()` check, because "a nil
`*ClassObject` stored in an `Object` interface value is a non-nil interface
wrapping a nil pointer" — Go's classic typed-nil gotcha, found the hard way
via a real test failure (`TestGCHandlesSelfReferentialInstanceCycle`).
**This class of bug cannot occur in Odin.** `^Obj` is a plain pointer; `obj
== nil` means exactly what it looks like it means, always. The `reflect`
import and its check simply have no reason to exist in the port.

### Strings: interned to canonical pointers, not a separate id

glox interns every string through a global `map[string]int` (name → id;
`src/core/string_intern.go`), and separately caches that id on `Value` as
`InternedId` so hot-path equality can compare integers instead of hashing.
`ValuesEqual`'s very first check is `if a.InternedId != 0 && b.InternedId
!= 0 { return a.InternedId == b.InternedId }` — a fast path that only
works because both sides happen to carry the same cached id.

odlox's intern table maps `string → ^String_Object` instead of `string →
int`. Every `Value` that denotes a string holds `payload.obj` pointing at
that *one* canonical `String_Object` — so two equal strings are, by
construction, the same pointer. `ValuesEqual` for two `Object_Type.String`
values is just `a.payload.obj == b.payload.obj`; there's no separate id
field to keep in sync (see [Value representation](#value-representation)
for why `InternedId` was dropped from `Value` entirely), and no fallback
path is needed the way glox's generic-object equality falls back to
`a.Obj.String() == b.Obj.String()` (stringify-and-compare) for object kinds
that aren't specifically numeric/vector — worth flagging as a real
oddity in glox worth *not* porting as-is: comparing two lists with `==`
today round-trips both through `String()`. odlox should give every
container kind real structural (recursive `Value`) equality instead — a
behavior improvement, not just a port, and one worth calling out
explicitly in review since it's a deliberate deviation from glox's current
semantics.

Interning itself needs no lock (`sync.RWMutex` in glox exists only because
multiple thread-module VMs might intern concurrently — out of scope here):
a plain `map[string]^String_Object` plus a `[dynamic]string` (or just the
`String_Object`s themselves, if kept alive permanently — see next section)
for reverse id→name lookup where still needed for debug output.

---

## Garbage collector

**Status: implemented (Phase 4), in `vm/gc.odin`.** glox's
`src/vm/gc.go` is explicitly a **design blueprint for this exact port** —
its doc comment says so directly: "modeled on clox's design... and
cross-checked against a reference Odin port (OrigamiDev-Pete/odinLox)
during design... it exists purely to validate root enumeration and object-
graph traversal against glox's real object model, and to serve as the
design blueprint for a future Odin port." This section is that blueprint,
carried over — with real refinements found while actually building it, not
just the two anticipated ahead of time. All of them are explained in full,
with the "found the hard way" detail, in `vm/gc.odin`'s own header comment
and the per-section comments below; read the code comments as the primary
source and this section as the summary.

### The mark-sweep cycle (ports directly)

```
collect_garbage :: proc(vm: ^VM) {
    gray := mark_roots(vm)
    gray = trace_references(gray)
    sweep(vm)
    vm.next_gc = vm.bytes_allocated * GC_HEAP_GROW_FACTOR   // 2×, matches clox/glox/odinLox
}
```

- **`mark_roots`**: every live `Value` on `vm.stack[0:vm.stack_top]`; every
  frame's `closure`; the *open* upvalue list (`vm.open_upvalues`, walked via
  `.next`); every global slot + `Vars` map reachable from every still-live
  `Environment` (glox's `markRoots` has a documented gotcha here worth
  preserving verbatim as a comment in the port: the *main script's own*
  `Environment` is reachable only through `frame.closure.function.environment`
  — it's the one environment with no `Module_Object` wrapper, found via a
  real bug where `GLOX_GC_STRESS` swept a live top-level `var` file handle
  out from under a running script).
- **`mark_object`** appends to a gray worklist (`[dynamic]^Obj`) on first
  mark, mirroring both glox's slice-append gray stack and odinLox's
  identical `grayStack`/`grayCount` pair.
- **`blacken_object`**: a `switch obj.type` tracing each concrete type's
  own children into more `mark_object` calls — `Closure_Object` marks its
  function + every upvalue, `Instance_Object` marks its class + every field
  value, `List_Object`/`Dict_Object` mark every element, etc. Direct port
  of glox's `blackenObject`, one case per `Object_Type`.
- **`sweep`**: walks the intrusive `vm.objects` (`^Obj` head, chained via
  `.next` — the same shape as clox's `vm.objects` and glox's
  `GCRegistry.head`), freeing anything left unmarked and clearing the mark
  bit on survivors. Anything implementing "has a real external resource"
  (a file handle) gets an explicit teardown call first — see
  [GCFreer equivalent](#gcfreer-equivalent) below.

`gc_track` (allocation-site hook, called from every constructor of a
collectible type): links the new object at the registry head. **Not
pre-marked, unlike glox's version** — see the next section for why that
whole mechanism turned out to be unnecessary here.

### No mid-opcode collection, so no "pre-mark on link" trick

glox's `gcTrack` pre-marks a just-linked object, and its comment explains
a real bug this works around: a builtin (e.g. `os.open` constructing a
`FileObject`) allocates the object *before* the resulting value is pushed
anywhere a root scan would find it; if `bytesAllocated` crosses the
threshold and triggers a collection in that exact gap, an unmarked new
object would be swept by the very cycle it triggered.

odlox's `run()` dispatch loop only ever calls `maybe_collect_garbage`
**between** opcodes (top of the `for` loop, before decoding the next
instruction) — never from inside a single opcode's own handler. Every
opcode that builds a compound value out of several already-on-the-stack
pieces (`Op_Create_List` popping N items before combining them, `Op_Call`
shaping arguments, ...) does that whole sequence atomically with respect to
collection: nothing can run a cycle partway through. That means the value
stack is *always* exactly what source-level semantics say it should be —
including every intermediate expression result — at the one point a
collection is ever allowed to happen, so there's no window where a
just-allocated, not-yet-reachable-from-anywhere object needs artificial
protection at all. This removed a whole mechanism glox needed, not just
simplified it.

### "No permanent-object exemption" — landed for two of four kinds, for a structural reason

glox deliberately **never sweeps** `ClassObject`, `ModuleObject`,
`FunctionObject`, or `StringObject` — its own doc comment
(`src/core/gc_registry.go`) calls this a scope decision ("small in number
and long-lived, so there's no real cost to it"), leaning on Go's own GC as
the real backstop for actually reclaiming them eventually. odlox has no
such backstop, so the original plan here was to make all four ordinary
sweepable `Obj`s.

**What actually happened, discovered while wiring this up**: `Class_Object`
and `Module_Object` *are* ordinary sweepable objects now — both are
constructed entirely by `vm`-package code (`Op_Class`'s handler,
`module.odin`'s `load_module`), so `gc_track` is always reachable right at
their construction site, and the `LiveClasses`/`LiveModules` side-registry
glox needed is gone entirely; a class is alive exactly when something
really points to it. `Function_Object` and `String_Object`, though, are
built by code that **cannot** call `gc_track` at all: `Function_Object` is
constructed by the *compiler* (`compiler/functions.odin`, `compile_function`),
and `String_Object` by `core.intern_string`, called from both the compiler
and the VM — neither has a `^VM` in scope, for the same package-graph
reason `core.Native_Object`'s `Builtin_Fn` needed a `rawptr` boundary in
Phase 2 (`core` sits below both `compiler` and `vm`; see
[Package layout](#package-layout)). Both remain structurally permanent —
still fully traced (a closure stashed in a class static, or a string held
only by an interned-but-unlinked pointer, stays correctly reachable), just
never freed. Not a change of plan so much as discovering that "no VM in
scope" is a real constraint two of the four kinds run into and two don't.

### String weak-table sweeping: deferred, not implemented

The follow-on idea from the original plan — treat the intern table as a
*weak* set, removing an entry once its `String_Object` goes unmarked for a
cycle (clox's and odinLox's actual answer, `tableRemoveWhite`) — needs
`String_Object` to be a normal sweepable object first, which the section
above explains it structurally can't be without moving where interning
happens (likely into the `vm` package itself, sacrificing "the compiler
can intern constants with no VM in scope at all"). Not attempted this
phase; interned strings are permanent for now, matching glox's actual
behavior (though arrived at for a different reason) rather than the
originally-planned improvement. Worth revisiting if a long-running
REPL/script session's intern-table growth ever actually matters in
practice — there's no evidence yet that it does.

### GCFreer equivalent

glox's `core.GCFreer` interface (`GCFree()`, checked via type-assertion in
`sweep`) lets native types with a real external resource (an open
`FileObject`, later a raylib texture/shader/window) run teardown exactly
once, idempotently (a script may have already closed the resource itself).
Ports as a `switch obj.type` case inside `sweep` for exactly those object
kinds that need it (`.File` today; `.Texture`/`.Shader`/etc. once the
natives phase lands) — no interface needed, since the switch already knows
the concrete type.

### No concurrency anywhere

Every mutex/atomic in glox's GC-adjacent code (`gc_registry.go`'s
`liveClassesMu`/`liveModulesMu`, `obj_list.go`/`obj_dict.go`'s
`stringDepth atomic.Int32` recursion guard) existed only because multiple
thread-module VMs could touch shared state concurrently. With threads out
of scope (see [Scope](#scope)), all of it becomes a plain field —
`string_depth: int`, no registry mutexes, no `sync.RWMutex` on the intern
table.

One place this assumption surfaced an open issue rather than just a
theoretical risk, found while writing Phase 2's and Phase 4's own test
suites rather than in the interpreter itself: running many `@(test)`
procs together in one `odin test` binary against `core`'s one
package-level, deliberately unsynchronized string-intern table
occasionally produces wrong results or crashes that do **not** reproduce
running the same test alone. This isn't fully explained by Odin's test
runner defaulting to multiple *OS threads* (the first, natural
hypothesis, since many independent tests genuinely do touch the shared
table concurrently that way) -- it still reproduces with
`-define:ODIN_TEST_THREADS=1`, and shows up in `src/core`'s own test
binary too, which never constructs a `VM` at all, only plain `core`-level
values. The common factor across every occurrence is simply *many tests,
one process, one shared table* -- consistent with either a real data race
that single-threading doesn't fully rule out (e.g. the OS thread pool a
`-define:ODIN_TEST_THREADS=1` run still uses under the hood for other
runtime bookkeeping) or a toolchain-level issue in this project's
installed compiler, an active `dev-2026-07` build rather than a numbered
release. Every single test passes running alone, and the compiled
`odlox` binary itself has produced correct output for every hand-written
smoke-test script exercised against it (see `ROADMAP.md`'s Phase 4
section for specifics) -- so this reads as a test-execution artifact
tied to this specific toolchain build running many tests in one process,
not a correctness bug in the interpreter's actual logic, but it is
**not fully root-caused**. Documented honestly rather than hidden or
worked around silently; re-evaluate after any Odin compiler update
before assuming it's this project's code again.

---

## Environment & globals

glox's `Environment` (`src/core/environment.go`) is the runtime home for a
compilation unit's globals — a deliberate two-tier design worth preserving
exactly, since it's already the fix for a real perf problem (globals used
to be map-backed; the fast slot array was itself an earlier optimization
pass, the same shape as the still-unfinished "slot-based instance fields"
idea from the performance roadmap):

- `globals: []Value` / `defined: []bool` — slot-indexed, populated by
  compile-time-assigned integer slots (`Parser.globalSlot`), for `O(1)`
  `OP_GET_GLOBAL`/`OP_SET_GLOBAL` with no hashing.
- `vars: map[int]Value` (interned-name-id → value) — for module-export
  lookup by name (`from mod import x`) and `__all__` iteration, where the
  caller doesn't have a compile-time slot for the *importing* side's view
  of the name.
- `global_names: []string` — slot → name, shared by every function in one
  compilation unit (only the top-level chunk populates it; inner functions
  share the *Environment*, not the chunk, so they resolve names through it
  too) — used for error messages and for resolving a `try`/`except`
  clause's exception class name from an arbitrary frame (see
  [Exceptions](#exceptions)).

Porting notes:

- Drop `varsMu sync.RWMutex` entirely (thread-module-only, see
  [Scope](#scope)) — `vars` becomes a plain `map[int]Value`.
- `GrowGlobals` (used by the REPL so earlier lines' globals survive into
  later ones, unlike a fresh `InitGlobals` reallocation) ports directly —
  it's just "reallocate-and-copy if the new count is bigger," no Go-specific
  behavior involved.
- Every built-in module (`sys`, `gfx`, `os`, ...) is *just* a
  `Module_Object` wrapping an ordinary `Environment`, populated
  programmatically at startup instead of by running Lox source — this
  detail (from `vm/builtin.go`) matters for the native-functions phase, see
  [Native/builtin functions](#nativebuiltin-functions).

---

## Chunk, opcodes, bytecode

Direct, low-risk port. `Chunk` becomes:

```odin
Chunk :: struct {
    code:          [dynamic]u8,
    constants:     [dynamic]Value,
    lines:         [dynamic]int,     // parallel to code, one entry per byte
    filename:      string,
    local_vars:    [dynamic]Local_Var_Info,   // debug info
    global_count:  int,
    global_names:  [dynamic]string,
}
```

Opcodes become an Odin enum, `Op_Code :: enum u8 { Return, Noop, Constant,
Negate, Add_Numeric, ... }` (Odin's enum namespacing means no `OP_` prefix
stutter is needed — `.Constant` reads fine at a use site, unlike C/Go where
a flat global namespace forces the prefix). The full set from glox's
`chunk.go` carries over 1:1 in meaning; exact ordinal values don't need to
match glox's (nothing cross-language ever reads raw opcode bytes — see
[Bytecode cache](#bytecode-cache-lxc)).

Two families of opcode are worth flagging up front because they're not
simple "one opcode, one operation" cases — both documented in detail in
their own sections below:

- The **self-specializing arithmetic family** (`OP_ADD_NN`/`OP_ADD_II`/
  `OP_ADD_FF`, `OP_INCR_CONST_N`/`_I`/`_F`) — produced by a *compile-time*
  peephole pass, then further specialized by the VM at *runtime* via
  in-place opcode-byte patching on first execution (a minimal inline cache).
  See [VM dispatch loop](#vm-dispatch-loop--calling-convention).
- The **exception-handling opcodes** (`OP_TRY`/`OP_END_TRY`/`OP_EXCEPT`/
  `OP_END_EXCEPT`/`OP_FINALLY`/`OP_RAISE`) — see [Exceptions](#exceptions).

Jump operands are 2-byte, big-endian, exactly as in glox — no reason to
change this; it's an arbitrary-but-fine convention with no Go-specific
reasoning behind it.

---

## Scanner

Straightforward port of `src/compiler/scanner.go`. Key behaviors to
preserve exactly (each is load-bearing elsewhere in the compiler):

- **All tokens are materialized up front** into a `[dynamic]Token`, not
  scanned lazily one at a time. This is *not* just a style choice — the
  compiler's `finally`-block handling (see [Compiler](#compiler)) depends
  on being able to snapshot a token index and *replay* a range of already-
  scanned tokens later, which only works because the whole token stream is
  a stable, already-built array by the time parsing starts.
- **Separate `Int`/`Float` tokens** (no unified "number" token) — direct
  input to `Value`'s separate `VAL_INT`/`VAL_FLOAT` split; the scanner
  decides int-vs-float purely lexically (digit run with no `.` followed by
  a digit → int).
- **String interpolation is desugared at scan time**, not parse time: a
  string containing `${expr}` is rewritten into a synthetic token stream
  equivalent to `("lit0" & str(expr0) & "lit1" & ...)`, queued and drained
  by subsequent scan calls, using a **recursive sub-scan** of the
  interpolated expression's own source text. No AST-level interpolation
  node exists anywhere downstream; the compiler never knows interpolation
  happened.
- **Implicit-semicolon suppression** (`skip_eol`): an end-of-line right
  after an opening bracket, comma, colon, `=`, or binary operator is
  swallowed rather than emitted as a statement terminator, enabling
  multi-line expressions without explicit continuations.
- **Lexemes are slices of the source**, not copied strings — `Token.source`
  is a pointer/slice into the backing source string (or a synthetic
  string, for scanner-generated tokens), and `Token.lexeme()` slices it
  lazily. Odin's `string` is already `(^u8, len)`, so a `Token{ source:
  string, start, length, line: int }` with a `lexeme :: proc(t: Token) ->
  string { return t.source[t.start:][:t.length] }` is a direct, allocation-
  free equivalent.

---

## Compiler

`src/compiler/compile.go` is a **single-pass Pratt (operator-precedence)
parser with no AST** — every construct emits bytecode directly as it's
recognized. This is the single biggest file in glox (2946 lines) and the
biggest porting effort, but structurally it's one giant, mostly mechanical
translation: Go structs → Odin structs, Go closures-as-parse-functions →
Odin `proc` values, recursion stays recursion.

### Core structures (name changes only — semantics port exactly)

```odin
Precedence :: enum {
    None, Assignment, Conditional, Or, And, Equality,
    Comparison, Term, Factor, Unary, Call, Primary,
}

Parse_Fn :: #type proc(p: ^Parser, can_assign: bool)
Parse_Rule :: struct { prefix, infix: Parse_Fn, precedence: Precedence }

Local :: struct { name: Token, lexeme: string, depth: int, is_captured, is_const: bool }
Upvalue :: struct { index: u8, is_local: bool }

Compiler :: struct {
    enclosing:   ^Compiler,
    function:    ^Function_Object,
    type:        Function_Type,   // Function / Script / Method / Initializer
    locals:      [256]Local,
    local_count: int,
    scope_depth: int,
    loop:        ^Loop,
    tries:       ^Try_Finally,
    upvalues:    [256]Upvalue,
    environment: ^Environment,
}
```

`Loop`, `Try_Finally`, and `trampoline_site` port with their exact fields
and algorithm — these back `break`/`continue`/`return` correctly crossing
`finally` blocks, already documented start-to-finish in glox's own
`docs/exception-handling.md` (worth reading directly rather than
re-summarizing here; the compiler-side "trampoline" design and the
`localCountAtCrossing` bookkeeping are subtle and easy to break silently if
re-derived from scratch instead of ported as-is).

### Local/upvalue resolution: ports as pure recursion, no change in shape

`resolve_local` (linear backward scan by lexeme within the current
compiler), `resolve_upvalue` (the classic clox-style recursive climb: try
the enclosing compiler's locals first, marking `is_captured` and calling
`add_upvalue(is_local=true)` on a hit; otherwise recurse into the
enclosing compiler's own `resolve_upvalue` and, on a hit, `add_upvalue
(is_local=false)`) — none of this is Go-specific; it ports as-is.

### Globals are compile-time slot-assigned, not stack-based

Worth restating because it's easy to assume "globals" means "interpreter-
maintained map": `Parser.globals: map[string]int` assigns each global name
a monotonically increasing integer slot **the first time it's mentioned**
(read or write, whichever comes first — this is what makes forward
references to not-yet-declared globals work), and every `OP_DEFINE_GLOBAL`/
`OP_GET_GLOBAL`/`OP_SET_GLOBAL` operand is that slot index. Actual storage
at runtime is the `Environment.globals []Value` array from
[Environment & globals](#environment--globals) — the *parser* only ever
hands out slot numbers, it never touches values.

### Peephole optimizer lives in the compiler, not the VM

Contrary to what you might guess from "peephole optimizations usually run
over finished bytecode right before execution" — glox's peephole pass
(`(*Parser).peepHoleOptimise`) runs inside `endCompiler()`, once per
function, immediately after that function's bytecode is finalized. It's a
simple two-pattern byte-level rewrite (`GET_LOCAL x, GET_LOCAL y,
ADD_NUMERIC, SET_LOCAL x, POP` → `ADD_NN x y` + padding no-ops to preserve
byte offsets so already-computed jump targets don't shift). This part is
compile-time and type-agnostic; the runtime type-specialization half of the
same optimization (`ADD_NN` → `ADD_II`/`ADD_FF` on first execution) belongs
to the VM — see next section.

### REPL compilation

`compile_repl` differs from a normal compile only in seeding the `Parser`'s
`globals`/`globals_declared`/`global_count` from a persistent `Repl_State`
struct (copied first, so a failed compile can't corrupt the session; only
committed back on success) rather than starting empty — the single
`Environment` is what actually carries values across REPL lines; the slot
tables just need to stay in sync with it across separately-compiled lines.

---

## VM dispatch loop & calling convention

### Hoisted locals, not fields

glox's `run()` hoists five pieces of per-frame state into true Go locals
before the dispatch loop (`frame`, `function`, `chunk`, `constants`,
`vm.currCode`) specifically so the hot loop reads them without chasing
`frame.Closure.Function.Chunk...` on every single instruction — a
`refreshFrame()` closure re-derives all five and must be called after any
opcode that changes `vm.frameCount` (call, return, invoke, a caught
exception, etc.). **Port this exact shape.** In Odin these become real
local variables in the `run` proc, refreshed by a local `refresh_frame ::
proc()` (or just an inlined block, since Odin closures capturing locals by
reference work the same way) — same reasoning applies, same discipline
about calling it after the same opcode set.

### The one further step Go couldn't take: raw pointers for `ip` and stack top

glox's own performance roadmap explicitly wishes for this and can't have
it: *"`frame.Ip` is a heap field, not a register... where clox keeps `ip`
in a local the C compiler pins to a register... The stack pointer is
likewise an index."* Every operand read is `currCode[frame.Ip];
frame.Ip++` — a bounds-checked slice index, not pointer arithmetic, because
Go offers no raw-pointer-into-a-slice idiom that isn't `unsafe`.

Odin does offer this, safely: `ip: ^u8`, `stack_top: ^Value`, ordinary
pointer arithmetic (`ip = ip[1:]` via slice-of-pointer idioms, or literal
`ip = mem.ptr_offset(ip, 1)`/`ip^`). Hoist `ip` as a genuine pointer local
at the top of `run`, dereference/advance it directly for every opcode and
operand byte, and only write the resulting byte-offset back into
`frame.ip` at the same points `refresh_frame` already has to run (call/
return/frame-switch) — the exact clox-parity optimization the Go roadmap
names and rules out. Bounds checking can still be enabled in debug builds
(`-no-bounds-check` is a release-only flag) so this isn't a safety
regression during development, only in the optimized build.

### Opcode dispatch: direct port, grouped by family

Every opcode case ports as a straightforward translation of glox's `vm.go`
switch — see the [background research summary](#) inlined in project
history for the exhaustive per-opcode mapping; the noteworthy families are:

- **Self-specializing arithmetic** (`OP_ADD_NN`/`OP_INCR_CONST_N` and their
  `_I`/`_F` children): on first execution, if both operands are ints, the
  VM **patches its own opcode byte in place** (`vm.currCode[ip-N] =
  OP_ADD_II`) and computes the result immediately; same for floats. This is
  a minimal inline cache — port the exact mechanism, including the "don't
  patch if types don't match, just compute generically" fallback (keeps the
  generic form available for a call site that later sees a different type
  combination).
- **Call mechanism** (`call_value` → `call`): arity/default/variadic
  shaping exactly as documented in glox's own
  `docs/plans/default-variadic-params.md` (implemented, not just planned,
  on the reference branch) — pad missing optional params with
  `VAL_UNDEFINED`, pop-and-collect surplus positional args into a `*rest`
  list when variadic, `OP_JUMP_IF_DEFINED` in the callee's prologue skips
  a default-value expression when the caller supplied that argument.
- **Native/builtin call convention**: `Builtin_Fn :: #type proc(argc: int,
  arg_stack_ptr: int, vm: ^VM) -> Value` — `arg_stack_ptr` is the absolute
  stack index of the first argument, so a native reads args via
  `vm_stack(vm, arg_stack_ptr + i)` with no boxing/copying beyond what's
  already on the VM's own value stack. The caller (`call_value`/
  `invoke_from_builtin`) uniformly collapses `argc + 1` stack slots down to
  1 (the single returned `Value`) regardless of which of the four callee
  kinds (closure/native/class-constructor/bound-method) it was.
- **Foreach/iterator protocol** (`OP_FOREACH`/`OP_NEXT`/`OP_END_FOREACH`):
  two paths — native iterables (list/string) convert in place via a
  `Get_Iterator` proc and call `.next()` directly with zero Lox-level call
  overhead; user class instances go through the real `__iter__`/`__next__`
  method-call protocol, which requires a **nested re-entrant call into
  `run` itself** (glox's `RUN_CURRENT_FUNCTION` mode) — port this exactly,
  including the "raise the exception floor for the nested call's duration"
  detail (an uncaught exception inside the nested call must not unwind
  past its own boundary into the real caller).
- **Upvalue capture/closing** (`capture_upvalue`/`close_upvalues`): the
  open-upvalues list is sorted descending by stack slot, walked to find-or-
  insert; closing copies the live stack value into `.closed` and repoints
  `.location` at `&.closed`, detaching it from the stack — standard clox-
  style closing, unchanged by the port.

---

## Exceptions

Already documented exhaustively, start to finish, in glox's own
`docs/exception-handling.md` — bytecode shape, the VM-side handler-matching
loop (`raise_exception`/`next_handler`), and the compiler-side `finally`
trampoline design. **Read that file directly when implementing this phase**
rather than working from a re-summary; it documents two easy-to-break
invariants (`OP_END_EXCEPT` must be immediately followed by the next
clause's `OP_EXCEPT`/`OP_FINALLY` with nothing in between; `OP_TRY`'s
operand is patched exactly once, to the first clause) that matter far more
than the broad shape, which is otherwise a direct, mechanical Go→Odin port
(a cons-list of `Exception_Handler{except_ip, stack_top, prev}` per frame,
unwind-and-retry-in-caller's-frame on no match).

One behavior glox documents as a **known, deliberate limitation** — an
exception raised inside an `except` clause's own body doesn't run the
enclosing `finally` — should be ported as the same deliberate limitation,
not silently fixed or silently left ambiguous; note it in code comments at
the same place glox does.

---

## Modules & imports

`import mod [as alias]` / `from mod import a, b` / `from mod import *`
compile to `OP_IMPORT`/`OP_IMPORT_FROM` respectively; both resolve at
runtime through `import_module`, which:

1. Resolves a `.lox` path (search order: `LOX_PATH` env var's module
   directory, the running script's own directory, then a recursive
   subdirectory search) and checks a **process-wide** module cache
   (`name → Module_Object`) first — since threads are out of scope, this
   cache needs no mutex in odlox, unlike glox's `moduleCacheMu`.
2. On a cache miss, spins up a **fresh, nested VM instance** to compile-and-
   run the module's top-level code in isolation, then harvests its
   resulting `Environment` into a `Module_Object`. This nested-VM pattern
   is not concurrency — it's a synchronous helper call, same goroutine (or
   in Odin's case, no goroutine at all) — port it as a plain recursive/
   sequential call into `interpret`, not as anything requiring isolation
   machinery.
3. Optionally consults the bytecode cache — see next section for why this
   step is deferred in odlox.

`from mod import *` (`__all__`) iterates the module's `Environment.vars`
snapshot, copying each exported closure/class/native value into the
importing scope and allocating it a fast global slot on the importing
side — port as-is; no Go-specific behavior involved.

---

## Native/builtin functions

glox's `src/vm/builtin.go` registers built-ins via a **flat, hand-written
call sequence** — no reflection, no table-driven registry, just repeated
calls to a `define_builtin(vm, module, name, fn)` helper, once per native
function. Built-in *modules* (`sys`, `gfx`, `os`, `re`, ...) are themselves
just `Module_Object`s wrapping an ordinary `Environment`
(`make_builtin_module`), populated programmatically instead of by running
Lox source — and deliberately **not** auto-imported into the global scope;
a script must `import sys` explicitly, same as any other module.

One detail worth carrying forward exactly: glox defines its **base
exception class hierarchy** (`Exception`, `RunTimeError`, `EOFError`, etc.)
by compiling and running a small embedded *Lox source string* through a
disposable sub-VM at startup, then harvesting the result into
`vm.BuiltIns` — rather than hand-writing `Class_Object`/`Closure_Object`
graphs directly in Odin. This is worth keeping: it's far less code, and
the exception hierarchy is guaranteed to behave exactly like any other Lox
class (inheritance, `toString`, etc.) because it *is* one, compiled by the
same compiler as user code.

Given the [package layout](#package-layout) decision above, core builtins
(`len`, `type`, `append`, `range`, `rand`, core `sys`/`os` functions) live
inside the `vm` package itself, same as glox's own split between
`src/vm/builtin.go` (core) and `src/builtin/*.go` (raylib-heavy) — the
latter becomes odlox's `natives` package, wired in by `main.odin` calling
`natives.register_all(vm)` after core builtin registration, entirely a
Phase-6+ concern.

---

## Bytecode cache (.lxc)

**Deferred, not ported at V1.** glox's `.lxc` cache
(`src/vm/bc_cache.go`) is a direct binary mirror of the in-memory
`Chunk`/`Function_Object`/`Value` shapes, mtime-invalidated (cache valid
only if the `.lxc` file is strictly newer than the source `.lox`), used
purely to skip recompiling an imported module's source on every run.

Reasons to defer rather than port immediately:

- It's a pure performance optimization for module *load* time, not
  execution time — orthogonal to the scanner→compiler→VM core path this
  port is building first, and to the "approach clox performance" goal
  (which is about the interpreter loop, not disk I/O).
- Its binary format is bespoke and tightly coupled to `Value`/`Chunk`'s
  exact shape — glox's own `CLAUDE.md` warns that *any* change to `Value`,
  `Chunk`, or the serializer requires clearing all `.lxc` files, which is
  exactly the kind of format churn a young, still-changing port should
  avoid committing to early.
- If revisited, an Odin version has a much simpler option than
  hand-rolling a tagged binary reader/writer: `core:encoding/*` or a
  straight `mem.copy` of the (now much smaller, pointer-light-in-the-
  right-places) `Chunk` struct plus manual handling of the dynamic-array/
  string fields — worth a fresh design pass rather than transliterating
  glox's `readValue`/`readChunk` tag-byte format verbatim.

Revisit only if module-recompilation time is actually measured to matter
(most modules are small; this may simply not be worth the format-stability
cost for a personal project). Until then, every module import recompiles
from source every run — simpler, and one less moving part while the rest
of the port is still in motion.

---

## Test strategy

**The existing test suite ports wholesale, unmodified, and is the primary
correctness gate for every phase.** glox's `tests/new_tests/` is a pytest
suite driving a *compiled binary* as a subprocess — it has no dependency on
Go at all beyond the path to that binary:

- `tests/new_tests/lox/*.lox` — 198 fixture scripts covering closures,
  classes/inheritance, exceptions, destructuring, defaults/variadics,
  slicing, dicts, modules, iterators, `vec2/3/4`, and more (a `_ns` suffix
  marks the "no screen" variant of any test that would otherwise need
  Raylib/a display, for headless runs).
- `tests/new_tests/test_*.py` — one file per feature area, each asserting
  on the captured stdout lines of a fixture run via a shared `run_lox()`
  helper (`lox_helper.py`).
- The only two files with a hardcoded path to the Go binary are
  `lox_helper.py` (`GLOX = .../bin/glox`) and `conftest.py` (same constant,
  plus a "skip everything if the binary isn't built" guard). **Copy the
  whole `tests/new_tests/` directory into odlox verbatim and change those
  two path constants** to point at the built `odlox` binary — every
  `test_*.py` and every `.lox` fixture needs zero changes, because they
  only ever talk to a binary on disk via stdout comparison.

This means the port has an objective, incremental pass/fail signal from
the moment scanner+compiler+VM can run *any* script at all — run the whole
suite after every phase, watch the pass count climb, and treat "which
tests newly pass" as the actual definition of "phase N is done," rather
than a subjective judgment call. See `ROADMAP.md` for how each phase maps
to which slice of the suite should go green.

Test scripts that exercise out-of-scope features (`thread.*`, `sync.*`,
graphics-dependent non-`_ns` tests before the natives phase lands) are
expected to stay red or be explicitly skipped until/unless those phases are
undertaken — not a regression, just an honest reflection of scope.

---

## Performance: what Odin allows that Go didn't

Collected in one place for reference — every item below is a case where
glox's own `docs/performance-roadmap.md` names a cost, and Go's own
constraints (a tracing GC needing precise pointer info, no raw pointer
arithmetic without `unsafe`, no safe tagged unions, interface-based
polymorphism being the only cheap polymorphism available) are *why* that
roadmap either couldn't fix it or rated the fix "high risk":

| Cost (glox roadmap's own naming) | Why Go was stuck | What Odin does instead |
|---|---|---|
| `Value` interface width (32B struct) | Fixing needs `unsafe.Pointer`/handles; roadmap rates this medium-high effort, and full pointer-free handles "high risk" (semi-manual heap, use-after-free) *in Go specifically* | Safe `#raw_union` of `u64`/`^Obj` → 16 bytes, zero unsafe code — see [Value representation](#value-representation) |
| `GetType()` vtable dispatch | Interface method call, rarely devirtualised | Enum tag + pointer cast, no vtable exists to call — see [Object model](#object-model) |
| GC scanning the whole value stack + write barriers | `Value.Obj` is a real Go-GC-visible pointer; roadmap calls this "the one tax that is family B" and the hardest to remove in Go | We write the collector; it scans exactly what `mark_roots` says to scan, nothing more, nothing implicit |
| `frame.Ip`/stack-top as bounds-checked indices, not registers | No safe raw-pointer-into-slice idiom without `unsafe` | Ordinary Odin pointer arithmetic, safely, in a release build — see [VM dispatch loop](#vm-dispatch-loop--calling-convention) |
| Per-instance `map[int]Value` fields (family A, the largest attributable cost the roadmap's own profiling found — ~32% cumulative CPU on `trees.lox`) | Attempted a slot-based fix, **reverted** — net *regression* on access-heavy benchmarks because a runtime-resolved slot table is still a map lookup, just smaller; roadmap concludes the real fix needs compile-time-baked slot *opcodes* or an inline cache, not attempted alongside this experimental branch | Not automatically fixed by the language switch — but worth attempting properly in odlox from the start, since a fresh compiler is being written anyway: bake per-class field slot numbers into `OP_GET_FIELD_SLOT`/`OP_SET_FIELD_SLOT` bytecode operands at compile time (the roadmap's own conclusion for what "not an optional refinement" would need to look like) |
| Per-object churn: fresh method-table maps, bound-method allocation on every access | Already partly fixed in glox (package-level shared method tables) | Port the already-fixed version directly; consider a monomorphic inline cache on `OP_GET_PROPERTY`/`OP_INVOKE` (class-id → slot/method) as a stretch goal, same as the roadmap's own "Option 5" |
| Vec2/3/4 arithmetic allocation churn | Relies on Go's GC as backstop (never even registered with glox's own experimental collector) | Correctly GC-tracked (required — no backstop), *and* a candidate for a dedicated free-list/pool allocator per small fixed-size object kind (vec2/3/4, upvalues, bound methods), reusing sweep-freed slots instead of round-tripping through the general allocator — natural in Odin's manual-memory model, awkward to express safely in Go |

**Sequencing recommendation** (mirrors the source roadmap's own
"profile-first" philosophy — don't guess, measure): get correctness first
(scanner → compiler → VM → GC, all green against the ported test suite),
then profile odlox the same way glox's roadmap did (`-cpuprofile`/
`-memprofile` equivalents — `core:prof`/`pprof`-style tooling, or Odin's
`core:sys` timing primitives, plus the same benchmark scripts glox already
has under `benchmarks/lox/*.lox`, portable unmodified) before spending
effort on any specific item above. The table exists to explain *why* an
option is available, not to prescribe doing all of them regardless of
whether a profile says they matter.
