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
13. [Debug tooling](#debug-tooling)
14. [Native/builtin functions](#nativebuiltin-functions)
15. [Bytecode cache (.lxc)](#bytecode-cache-lxc)
16. [Test strategy](#test-strategy)
17. [Performance: what Odin allows that Go didn't](#performance-what-odin-allows-that-go-didnt)
18. [Embedding odlox in a host application](#embedding-odlox-in-a-host-application)

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
- **The `.lxc` bytecode cache** is shipped (Phase 8) — see
  [Bytecode cache](#bytecode-cache-lxc) for the design.

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
│   └── debug/                package debug   — disassembler, execution tracer   (imports core, vm)
└── docs/
```

(All Odin sources live under `src/` — `odin build src`/`odin test src/compiler` etc.
— keeping the repo root free for `README.md`/`ROADMAP.md`/`docs/`.)

Dependency direction is a strict DAG, same as glox's:
`core ← compiler ← vm ← natives`, with `main` at the top wiring everything
together. No cycles anywhere. **One correction from the original plan,
found while building Phase 5**: `debug` was planned to hang off `core`
alone (a disassembler only needs `Chunk`/`Op_Code` to read bytecode), and
`disassemble.odin` genuinely does only need `core`. But the *other* half
of this phase — `Trace_Hook`/`Instrument_Hook`, which implement
`vm.Debug_Hook` so `main.odin` can plug them straight into a running
`VM.debug_hook` field — has to import `vm` to even name that type. Since
`vm` doesn't import `debug` (nothing about running bytecode needs to know
a disassembler exists), this is still a clean DAG, just one layer deeper
than first planned: `core ← compiler ← vm ← debug`, with `natives` a
sibling of `debug` off `vm` rather than the other way around.

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
    Float_Array, // Phase 6f -- a plain w*h f64 buffer, ported from glox's FloatArrayObject
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
int`. Every `Value` that denotes a string *at or under
`core.STRING_INTERN_MAX_LEN` bytes* holds `payload.obj` pointing at that
*one* canonical `String_Object` — so two equal short strings are, by
construction, the same pointer (longer strings are ordinary
garbage-collected objects instead, not deduplicated — see
[String interning: later split by length](#string-interning-later-split-by-length-not-permanent-for-every-string)
below). `ValuesEqual`/`objects_equal` for two `Object_Type.String` values
is a content comparison (`s1.chars == s2.chars`, Odin's native `string`
`==`) rather than a bare pointer compare — behaviorally equivalent to
`a.payload.obj == b.payload.obj` back when every string really was
interned, but also correct now that some aren't; there's no separate id
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
[Package layout](#package-layout)). `Function_Object` remains fully
structurally permanent — still fully traced (a closure stashed in a class
static stays correctly reachable), just never freed; that's proportionate
to how many distinct functions a program actually compiles, a bounded set.
`String_Object` originally landed the same way, for the same reason — but
see the next section for why that stopped being true for *all* strings.

### String interning: later split by length, not permanent for every string

At the time this GC design landed (Phase 4), `String_Object` was made
structurally permanent for the reason above, matching glox's own behavior
(though arrived at differently — glox leans on Go's GC as a backstop for
its own permanently-registered strings; odlox has no such backstop, it's
just genuinely never freed). The follow-on idea noted at the time — treat
the intern table as a *weak* set, removing an entry once its
`String_Object` goes unmarked for a cycle (clox's/odinLox's actual answer,
`tableRemoveWhite`) — was left unimplemented, since it needs
`String_Object` to be a normal sweepable object first, which (per the
section above) it structurally can't be without moving where interning
happens.

**This did eventually matter in practice**, once native code started
interning bulk external data rather than just compiler-emitted identifiers
— `socket.recv()`/`try_recv()` turned every distinct payload a script read
into a permanent `intern_table` entry, an unbounded leak for a
long-running script reading a lot of unique data. The actual fix wasn't
the weak-table idea above (still blocked on the same "no VM in scope"
constraint) but a length split instead, closer to Lua's own short/long
string design: `core.STRING_INTERN_MAX_LEN` (40 bytes, matching Lua's
`LUAI_MAXSHORTLEN` default) — strings at or under that length still
intern exactly as described above (permanent, deduplicated, canonical
pointer); longer strings get an ordinary `collectible` `String_Object`
instead, swept like any other heap value once unreachable. Two
correctness follow-ons this required — `Dict`'s `map[^String_Object]Value`
genuinely depends on pointer identity (fixed at its 3 call sites that
didn't already re-intern), and compiler-emitted *identifiers*
(property/method/class/module/global names) turned out not to be
guaranteed short either, so those now always intern via a dedicated
`core.make_interned_string_value`, bypassing the length check entirely —
are covered in full in
[`docs/plans/string-interning-split.md`](plans/string-interning-split.md),
along with what was audited to confirm `Class.methods/statics`/
`Instance.fields`/`Environment.vars` needed no equivalent change.

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

### A narrow, deliberate exception to "no concurrency"

One native module genuinely touches OS-level concurrency, staying safe
without any general threading model:

- **`process`** (`vm/process.odin`) has no blocking multi-handle wait to
  reach for (there is no threading primitive anywhere in this
  interpreter), so `recv`/`try_recv` poll the pipe via Windows'
  `PeekNamedPipe` instead of blocking on a background reader, and
  `wait_any` round-robins `try_recv` across every live process with a
  short sleep between rounds — while still presenting ordinary blocking-
  wait semantics to script code. One real platform gotcha this design
  runs into: a failed `PeekNamedPipe` call must **not** be treated as
  EOF, because Windows can report a broken pipe as soon as the writer
  closes its end even while data the writer already sent is still
  sitting unread in the pipe's buffer — only an actual blocking read is
  authoritative on EOF vs. a genuine pending message.

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

`Loop`, `Try_Finally`, and `Trampoline_Site` port glox's `TryFinally`/
`trampolineSite` algorithm exactly (`local_count_at_crossing`'s dummy-local
reservation, the deferred-then-drained `pending` list, replaying `finally`
from a snapshotted token position) — these back `break`/`continue`/`return`
correctly crossing `finally` blocks, and the design is documented
start-to-finish in glox's own `docs/exception-handling.md` (worth reading
directly rather than re-summarizing here).

**Correction, Phase 6d**: this section originally said the fields port
"exactly" — one deliberately doesn't. glox's `trampolineSite.finalize` is a
`func(p *Parser)` closure captured over the enclosing `*Loop`, safe in Go
because an escaping closure is heap-promoted by the GC. Odin gives no such
guarantee for a `proc(p: ^Parser)` value stored in a struct field and
invoked much later from a different point in the compile pass, after the
call that created it has long since returned, and nothing in this codebase
exercised that pattern beforehand to lean on it with confidence. `Trampoline_
Site` here instead carries an explicit `kind: Trampoline_Kind` enum
(`Return`/`Break`/`Continue`) plus a plain `loop: ^Loop` field — already a
stable heap allocation via `push_loop`'s own `new(Loop)` — and
`compile_pending_trampolines` switches on `kind` rather than calling a
stored closure. Also plain `[]^Try_Finally` for `remaining` rather than
`[dynamic]^Try_Finally` (Go's slice there is just sliced further, never
appended to, once built — an ordinary Odin slice matches that usage more
directly than a dynamic array). Everything else — including this whole
feature actually being implemented, rather than deferred as a Phase 3-era
known simplification — landed in Phase 6d; see `ROADMAP.md`'s section of
that name for the full writeup.

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

### Control-flow headers: parens optional, not mandatory like glox's

`if`/`while`/`for`/`foreach` all wrap their header in `(...)` in glox's
real grammar (`ifStatement`/`whileStatement`/`forStatement`/
`foreachStatement` in `compile.go` all call
`p.consume(TOKEN_LEFT_PAREN, ...)` unconditionally — there is no bare
form in glox at all). This wasn't caught until Phase 6's testing
against the ported suite: Phase 3's original port had it backwards,
accepting only a bare (no-parens) form, so every parenthesized fixture
in the ported test suite failed to compile outright.

Fixed by making the parens **optional** (`stmt.odin`'s `parse_condition`
for `if`/`while`; equivalent inline handling in `for_statement`/
`foreach_statement`) rather than mandatory — a deliberate divergence
from glox, not an oversight this time: flipping to "mandatory" would
match glox exactly but break every bare-style script this compiler's
own test suite (`compile_test.odin`, `vm_test.odin`) and every
hand-written example already uses, for no benefit worth that cost.

The other real grammar fact this surfaced: in glox, an `if`/`while`/
`foreach` body is *any single statement* (`p.statement()`, called
directly — no block-specific path), not only a `{ block }`. This
port's original version hard-required `{`. Fixed the same way, by
routing the body through the general `statement(p)` dispatch (which
already has its own `.Left_Brace` case doing exactly what used to be
inlined at each call site, so a braced body is unaffected — this also
simplified `if_statement`'s `else`/`else if` handling from a
hand-rolled special case into a single generic `statement(p)` call,
since `statement()`'s own `.If` case already recurses back into
`if_statement` for a following `if`). `for`'s body deliberately stays
brace-required: with no parens, there's no unambiguous token telling
the parser where an omittable increment clause ends and a bare
statement body begins (parens sidestep this in glox by making `)`
that delimiter — exactly why glox's own grammar makes them mandatory
there specifically). No fixture in the ported suite needs otherwise.

### REPL compilation

`compile_repl` differs from a normal compile only in seeding the `Parser`'s
`globals`/`globals_declared`/`global_count` from a persistent `Repl_State`
struct (copied first, so a failed compile can't corrupt the session; only
committed back on success) rather than starting empty — the single
`Environment` is what actually carries values across REPL lines; the slot
tables just need to stay in sync with it across separately-compiled lines.

**Real bug, found via an actual multi-line REPL session** (not caught by
any single-compile test, since it only manifests across *multiple*
`end_compiler` calls sharing one `Environment`): `end_compiler`
(`compiler_state.odin`) publishes the current compile unit's slot→name
table onto `Environment.global_names` for error messages/exception-class
lookup (see [Environment & globals](#environment--globals)) — but it
used to `append` that table every time, never clearing first. For a
normal file compile this is harmless (one `end_compiler` call per fresh
`Environment`), but a REPL session reuses the same `Environment` across
every line, and each line's `p.global_names_by_slot` is *already* the
complete, correct, cumulative mapping (rebuilt fresh each
`Compile_Repl` call from `Repl_State.globals`) — so appending it on top
of what previous lines already appended left `Environment.global_names`
holding roughly N stacked, overlapping copies after N lines.
`env_slot_for_name`'s linear search would then resolve any given name
to whatever leftover index the *first* stale copy happened to still
hold it at: consistently wrong, not randomly, and wrong by exactly the
accumulated duplication — a 3-line session was enough to reproduce it.
Fixed by clearing `Environment.global_names` before republishing,
rather than appending to it.

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

### `ip`: a hoisted plain `int`, not a pointer

`run`'s dispatch loop hoists `ip` as a genuine local at the top of the
proc — a plain `int` byte offset into the current frame's code slice, not
a raw `^u8`. The property that actually matters for keeping it
register-resident across the loop's whole body is that it's a real local,
never read back through a pointer-chased struct field (`frame.ip`)
between sync points — an `int` local satisfies that exactly as well as a
pointer local would, and every operand/opcode read already goes through a
bounds-checked slice index (`code[ip]`) either way, since
`-no-bounds-check` (a release-only build flag) is what actually removes
that check's cost, independent of whether `ip` itself is an `int` or a
pointer. `stack_top` is hoisted the same way, as a plain `int` index into
`vm.stack`.

**Sync discipline**: every point in the dispatch loop that already calls
`refresh_frame()` (because `frame_count` might have changed) re-seeds
`ip` from the refreshed frame's own `ip` field right after; every call
this loop makes into anything that could transitively read or reposition
the *current* frame's `ip` while it's suspended (`call_value`/`invoke`/
`do_super_invoke`, `raise_exception`, `do_foreach`/`do_next`, the
per-opcode debug hook) writes `frame.ip = ip` immediately before making
that call. Every other reader of `Call_Frame.ip` elsewhere in the
codebase (stack-trace/handler-matching, frame-introspection natives, the
disassembler's trace mode) is only ever reached via one of these same
call points, so this set of sync points is complete.

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
- **Foreach/iterator protocol** (`Op_Foreach`/`Op_Next`/`Op_End_Foreach`,
  `foreach.odin`) — **implemented**: two paths, native iterables (list/
  string/`range()`, converted in place to one of three built-in
  iterator kinds, pulled with zero Lox-level call overhead) and user
  class instances (a real `__iter__`/`__next__` method-call protocol),
  the latter needing a **nested re-entrant call into `run` itself**
  (`Run_Mode.Current_Function`, `foreach.odin`'s `call_closure_now`) —
  ported closely against glox's own `RUN_CURRENT_FUNCTION` usage in its
  `OP_FOREACH`/`OP_NEXT` instance branches, including the "raise the
  exception floor for the nested call's duration" detail (`run()`
  already had this from Phase 4's original `Run_Mode` scaffolding — see
  [Exceptions](#exceptions)). **`Op_Str`'s `toString()` dispatch does
  *not* use this mechanism**, worth calling out since it's easy to
  assume every "call a Lox method from inside an opcode" case needs the
  same nested-`run()` machinery: checked against glox's own `OP_STR`
  handling directly, and glox just pushes a new call frame for
  `toString` and lets the *outer* dispatch loop carry on (`continue`
  after `vm.call(...)`/`refreshFrame()`) — no nested `run()` call at
  all, because `Op_Str`'s call is the very last thing that opcode does,
  unlike `Op_Foreach`/`Op_Next`, which need the call's result back
  *immediately, mid-opcode* to decide what happens next. Ported the
  same way odlox-side (`run.odin`'s `Op_Str` case).
- **Upvalue capture/closing** (`capture_upvalue`/`close_upvalues`): the
  open-upvalues list is sorted descending by stack slot, walked to find-or-
  insert; closing copies the live stack value into `.closed` and repoints
  `.location` at `&.closed`, detaching it from the stack — standard clox-
  style closing, unchanged by the port.
- **Dict/property gaps found in Phase 6c**, both real, both fixed by
  matching glox's own per-type dispatch rather than the narrower
  version that had shipped: `Op_Index`/`Op_Index_Assign` had no `Dict`
  case at all (`do_index` required an integer index before even
  checking the container's type, so `dict["key"]` always failed
  outright — glox's own `index()`/`indexAssign()` fully support it);
  `Op_Set_Property` only ever checked `receiver.type == .Obj` before
  dispatching, but a `vec2`/`vec3`/`vec4` value's `.type` is never
  `.Obj` (see [Value representation](#value-representation)), so
  `v.x = expr` always fell through to a generic error even though
  *reading* `v.x` already worked — glox's own `OP_SET_PROPERTY` has a
  real `Vec2`/`Vec3`/`Vec4` case (`set_vec_swizzle` now mirrors the
  existing `get_vec_swizzle`). Relatedly, `create_dict` used to reject
  any non-string dict-literal key outright instead of coercing it to
  its string representation the way glox's own `createDict` does
  (`key.String()`) — real glox source relies on this (an int-keyed
  dict literal looked up later via `str()`), so this wasn't a
  hypothetical gap.

---

## Exceptions

**Status: implemented (Phase 4), with a real deviation from the plan below
and two bugs found later worth knowing about.** glox's own
`docs/exception-handling.md` documents its design exhaustively (bytecode
shape, the VM-side handler-matching loop, the compiler-side `finally`
trampoline) and is still worth reading for the parts that ported
unchanged (a cons-list of `Exception_Handler{except_ip, stack_top, prev}`
per frame, unwind-and-retry-in-caller's-frame on no match) — but two of
the specific invariants it calls out don't apply to what's actually
here, and this port has bugs of its own glox's design doesn't share.

**`break`/`continue`/`return` crossing an enclosing `try`**: these need to
both unwind the exception handlers registered by any `try` they cross
(so a frame's own handler chain never holds a stale entry for a `try` no
longer lexically in scope) and replay that `try`'s `finally` block on the
way out. `finally` is parsed *last*, so a `return`/`break`/`continue`
written inside a `try` body can't yet know, at the point it's compiled,
whether cleanup code will need to run first — it defers into a
`Trampoline_Site` (`compiler/compiler_state.odin`) instead of emitting
its terminal jump/return immediately, and the code that finishes
compiling the enclosing `try`/`except`/`finally` resolves every pending
site once it knows whether a `finally` exists. A `Trampoline_Site` stores
a plain pointer to the loop/function it targets rather than a closure,
because its resolution step can run arbitrarily later in the compile
pass (once the enclosing `try` actually closes) — nothing in this
codebase establishes that stashing an Odin closure in a struct field
that outlives the call that created it is safe to invoke from that later
point, so a pointer plus an explicit resolution step avoids relying on
that.

**Deliberate deviation from the plan**: glox finds "the next except/finally
clause" by scanning raw bytecode for `OP_END_EXCEPT` immediately followed
by `OP_EXCEPT`/`OP_FINALLY` — fragile once a clause body can contain a
*nested* try/except (that inner `OP_END_EXCEPT` would be found first,
wrongly), which is exactly why glox's own doc calls "must be immediately
followed by" a load-bearing invariant. This port doesn't have that
invariant at all: `Op_Except` carries its own explicit 2-byte skip
offset to the next clause (`exceptions.odin`'s `match_clause_chain`),
patched exactly like any other jump, computed and read entirely by this
port's own compiler/VM. No scanning, no ambiguity, correct through
nested `try`s for free — see `exceptions.odin`'s own header comment for
the full rationale.

**Two real bugs found well after Phase 4**, both in
`exceptions.odin`/`run.odin`, neither caught until an exhaustive
individual-test pass (Phase 6a-continued) stopped attributing every
`vm`-package test failure to already-documented toolchain flakiness:

- `match_clause_chain`'s "is there another clause" check only verified
  `next_clause` was still within the *chunk's* bounds — true for
  almost any position in almost any real function, since a `try`/
  `except` is rarely the very last thing compiled. It needed to check
  what opcode is actually *at* `next_clause` (`.Except` or `.Finally`,
  or there's no more clauses), not just whether that position exists.
- `Op_End_Try`'s runtime handler never applied its own jump offset at
  all — treated the two operand bytes as inert padding on a since-
  disproven comment that the compiler always emits zero there. It
  doesn't: the compiler emits a real forward jump, needed to route
  normal completion past the *exceptional* copy of a `finally` block
  straight to the *normal-path* copy. Every `try`/`finally` with no
  `except` clause fell through into the exceptional copy regardless,
  which ends in an unconditional re-raise — so completely ordinary,
  non-exceptional `try`/`finally` completion reported a bogus uncaught
  exception, unconditionally, every time.

See `ROADMAP.md`'s Phase 6a-continued-part-2 section for the full
writeup, including why these went undetected for as long as they did
(both are 100%-reproducible in isolation — the toolchain flakiness
documented in the Scope/Garbage collector sections is real, but it
had been providing unearned cover for these too).

One behavior glox documents as a **known, deliberate limitation** — an
exception raised inside an `except` clause's own body doesn't run the
enclosing `finally` — is ported as the same deliberate limitation here
too, not silently fixed or silently left ambiguous.

---

## Modules & imports

`import mod [as alias]` / `from mod import a, b` / `from mod import *`
compile to `OP_IMPORT`/`OP_IMPORT_FROM` respectively; both resolve at
runtime through `import_module`, which:

1. Resolves a `.lox` path and checks a **process-wide** module cache
   (`name → Module_Object`) first — since threads are out of scope, this
   cache needs no mutex in odlox, unlike glox's `moduleCacheMu`.
   **Fixed, Phase 6**: this section originally described glox's own
   three-tier search order as the plan, but Phase 4's actual
   `read_module_source` implementation diverged from it (script's own
   directory first, no subdirectory search at all) — not caught until
   Phase 6 needed `import math` to find a copied-over `.lox` module and
   couldn't. Now fixed to match glox's order with one deliberate path
   difference: `$LOX_PATH/modules/<name>.lox` first (not glox's
   `$LOX_PATH/src/modules/` — odlox's own `src/` is exclusively Odin
   source, so that convention doesn't transfer), then the running
   script's own directory, then a recursive subdirectory search of it
   (`find_module_in_subdirs`, using `core:os`'s `Walker` API, skipping
   VCS/build/cache directories). Found a real, separate, pre-existing
   bug while building the subdirectory search: `read_module_source` was
   calling `delete()` on `filepath.dir(vm.script)`'s result, which is a
   slice *view* into `vm.script` (see `os/path.odin`'s `split_path`),
   not an owned allocation — a bad free that silently corrupted the
   heap on every successful module import since Phase 4, which the new
   search path's extra allocations turned into an actual, reliably
   reproducing segfault. Fixed by simply not deleting it.
2. On a cache miss, spins up a **fresh, nested VM instance** to compile-and-
   run the module's top-level code in isolation, then harvests its
   resulting `Environment` into a `Module_Object`. This nested-VM pattern
   is not concurrency — it's a synchronous helper call, same goroutine (or
   in Odin's case, no goroutine at all) — port it as a plain recursive/
   sequential call into `interpret`, not as anything requiring isolation
   machinery.
3. Optionally consults the bytecode cache — see next section for why this
   step is deferred in odlox.

**The single most severe bug found in this project so far lived exactly
at this "nested VM instance" boundary, found in Phase 6c porting real
`.lox` modules.** A module's own closures (functions/methods it
declares) genuinely do end up living in the *importing* script's own
VM after import — the nested sub-VM that compiled and ran the
module's top-level code once is disposable, only its `Environment`
survives (wrapped in the `Module_Object`) — but each of those
closures' `Function_Object.environment` field still correctly points
at the *module's own* `Environment`, distinct from whatever VM later
calls them (see [Compiler](#compiler) on `Function_Object.environment`
being set once, at compile time, and never changing). `run.odin`'s
`Get_Global`/`Set_Global`/`Define_Global(_Const)` cases, though,
resolved through `vm.environment` — the *running VM instance's own*
field — rather than the *currently executing frame's function's own*
environment. Those coincide only for the top-level script itself. The
instant an imported module's function referenced *any* global at
all — calling another function in its own module, reading a
module-level var, or calling an underscore-prefixed native — it
silently read/wrote the wrong slot, in the *importing* script's global
space, or hit `Undefined variable '#N'` outright. This had been true
since Phase 4 first wired module property access up; nothing caught
it because the one existing module test only ever read a plain
exported *value*, never *called* an imported function that itself
touched a global. Fixed by resolving through the current frame's
`fl.fn.environment` throughout, hoisted by `refresh_frame` same as
every other per-instruction hot-path field (see
[VM dispatch loop](#vm-dispatch-loop--calling-convention)).

`from mod import *` (`__all__`) iterates the module's `Environment.vars`
snapshot, copying each exported closure/class/native value into the
importing scope and allocating it a fast global slot on the importing
side where one exists — **corrected, Phase 6c**: "port as-is" was the
original plan, but two real bugs needed fixing to get there. First, a
scanner-level one: `*` (the wildcard marker) is lexically
indistinguishable from the multiplication operator, which the Eol-
suppression heuristic ([Scanner](#scanner)) treats as "the expression
continues onto the next line" — so the Eol that should terminate `from
mod import *` was never scanned into the token stream, and the parser's
old unconditional newline-check always failed. Second: this "allocate a
fast global slot" step used to treat "no matching slot in the importing
script" as a fatal internal-error bug, on the assumption every name
being walked was a deliberate module export — but `Environment.vars`
also holds whatever free builtins the module's own code happened to
reference internally (`seed_builtin_globals` writes those into both a
module's globals *and* vars), and there's no reason the importing
script would have a slot reserved for a name it never itself mentioned
by identifier, nor any need for one (slot-indexed `Op_Get_Global` can
never ask for a name that was never referenced). Fixed by making that
specific case silently skip the fast-slot write instead of erroring —
confirmed against glox's own `importFunctionFromModule`, which does
exactly that.

---

## Debug tooling

Port of `src/debug/debug.go`. Two independent pieces, in one package but
with different runtime costs, so they're gated differently.

**The disassembler** (`disassemble_chunk`/`disassemble_instruction`, and
`disassemble_program` — not in glox, added here since it's a natural fit
once `Chunk` and `Function_Object` already exist) only needs `core` —
no VM required to read bytecode, just like clox's own disassembler runs
over a `Chunk` with no interpreter attached. `disassemble_program` walks
a compiled script's *whole* function tree (every `func`/method/lambda is
its own `Chunk`, stored as a `Function_Object` constant in its enclosing
chunk — see [Chunk, opcodes, bytecode](#chunk-opcodes-bytecode)), not
just the top-level one, with a visited-set guard against printing the
same `Function_Object` twice.

Two small additions beyond a bare port, both because the compiler
already tracks the data and a debug tool is exactly where surfacing it
earns its cost: `Get_Local`/`Set_Local`/`Inc_Local` print the local
variable's *source name*, recovered from `Chunk.local_vars` (debug info
`add_local`/`end_scope` were already recording for other reasons — see
[Compiler](#compiler)) rather than just a bare slot number;
`Get_Global`/`Set_Global`/`Define_Global(_Const)` resolve their slot to
a name via `Chunk.global_names`. Both are lookups the disassembler does
locally — they add no new state anywhere else.

**The trace/instrument hooks** (`Trace_Hook`, `Instrument_Hook`) are a
different matter: they implement `vm.Debug_Hook`
(`proc(vm: ^VM, event: Debug_Event)`, fired from `run()`'s dispatch loop
between opcodes and from `call()` on every call/return — see
[VM dispatch loop](#vm-dispatch-loop--calling-convention)), so `debug`
has to import `vm` to even name that type. This is the one place this
phase's package layout diverges from the original plan — see
[Package layout](#package-layout)'s note on why that's still a clean DAG.

Gating matches glox's own hot-loop debug hook
(`core.HotLoopDebugHookCompiled`, toggled by commenting/uncommenting a
call site via a build shell script) in *intent* — compiled out of a
release build entirely, not just skipped at runtime — but the mechanism
is native to Odin rather than a script working around Go's lack of one:
each hook proc's body is wrapped in `when ODIN_DEBUG { ... }`, Odin's own
builtin constant that's true exactly when the binary is built with
`-debug`. `run()`/`call()`'s call sites (`if vm.debug_hook != nil { ... }`)
are unconditional either way — that check is cheap enough it isn't worth
compiling out, and Phase 4 already needed it as the mechanism's on/off
switch regardless of which hook (if any) is attached. What `when
ODIN_DEBUG` actually removes from a release binary is the *work* each
hook does when it fires: `Trace_Hook`'s per-step stack dump plus a full
`disassemble_instruction` call, and `Instrument_Hook`'s counter
increment — real, avoidable per-opcode cost if left in.

`main.odin` exposes both through CLI flags (`--debug`, `--instrument`),
plus `--compile-only` (compile, report, don't run — the milestone check
[Phase 3](../ROADMAP.md) refers to), `--disassemble` (compile, dump via
`disassemble_program`, don't run), `--info` (compile, print a size
summary), and `--no-peephole` (toggles `compiler.DebugSkipPeephole`,
combinable with any of the above). `--debug`/`--instrument` on a non-
`-debug` build still set `vm.debug_hook` (there's no reason not to — the
hook body itself is what's compiled out) but `main.odin` also prints one
`when !ODIN_DEBUG`-gated note explaining why nothing will appear, so the
flag fails informatively instead of silently doing nothing.

---

## Native/builtin functions

**Status: core builtins implemented (Phase 6a)** — `len`/`type`/`append`/
`range`/`rand`/`float`/`int`/`replace`/`format`/`vec2`/`vec3`/`vec4`/the
underscore-prefixed math floor, `sys.*`, `os.*`, and the `replace`/`join`
string methods. Raylib-backed natives, `re`/`pickle`/`process`,
`colour_utils`, and glox's own `src/modules/*.lox` Lox-source standard
library are all still unimplemented — see `ROADMAP.md`'s Phase 6 section
for the exact boundary and what each still needs.

glox's `src/vm/builtin.go` registers built-ins via a **flat, hand-written
call sequence** — no reflection, no table-driven registry, just repeated
calls to a `define_builtin(vm, module, name, fn)` helper, once per native
function. This ported directly (`vm/builtins.odin`'s `define_builtin`).
Built-in *modules* (`sys`, `os`, ...) are themselves just `Module_Object`s
wrapping an ordinary `Environment` (`make_builtin_module`), populated
programmatically instead of by running Lox source — and deliberately
**not** auto-imported into the global scope; a script must `import sys`
explicitly, same as any other module. Confirmed working exactly as
planned, once two gaps the original plan didn't anticipate were closed:

- **Free functions need an explicit seeding step to be reachable at
  all.** The compiler assigns every referenced name a global slot
  purely from source text (`global_slot`'s "first mention wins" — see
  [Compiler](#compiler)), with no notion that some names are builtins;
  a bare `type(1)` compiles to an ordinary `Op_Get_Global` on a slot
  nothing has called `Define_Global` for. `Op_Get_Global` has no
  map-fallback path of its own — a direct slice index by design, the
  whole point of slot-indexed globals over glox's earlier map-backed
  one (see [Environment & globals](#environment--globals)). glox
  solves this with its own `initGlobals`: after every compile, walk
  the slots the top-level chunk's `GlobalNames` actually names and
  seed any still-undefined slot whose name matches a registered
  builtin or built-in module — this port's `interpret.odin` calls the
  equivalent `seed_builtin_globals` right after `core.env_grow_globals`,
  for the same reason and at the same point in the pipeline. Missed
  initially (the free functions were registered into `vm.builtins` but
  nothing ever consulted that map for ordinary global resolution) —
  found immediately by the first `type(1)` smoke test failing.
- **`module.fn(args)` needs its own `Op_Invoke` case.** `.name(args)`
  always compiles through `Op_Invoke` (the fast path for *every* call
  of that shape — see [VM dispatch loop](#vm-dispatch-loop--calling-convention)),
  and `call.odin`'s `invoke` had a branch for every receiver kind that
  can have "methods" except `Module`, so every built-in module
  function call fell through to "Undefined method" — not a Phase 6
  regression so much as a latent gap since Phase 4 first wired module
  property *access* up (`get_property`'s `.Module` case existed;
  `invoke`'s never did, since nothing had called a module function
  before this phase). Fixed with an `Module` case mirroring glox's own
  `invokeFromModule`: resolve the member by name through the module's
  `Environment`, then delegate to the same `call_value` an ordinary
  `Op_Call` would use.

One detail worth carrying forward exactly: glox defines its **base
exception class hierarchy** (`Exception`, `RunTimeError`, `EOFError`, etc.)
by compiling and running a small embedded *Lox source string* through a
disposable sub-VM at startup, then harvesting the result into
`vm.BuiltIns` — rather than hand-writing `Class_Object`/`Closure_Object`
graphs directly in Odin. This landed in Phase 4, not Phase 6 (the VM
needed *a* working exception hierarchy to run anything at all, long
before native functions existed) — see
[Exceptions](#exceptions)/`exceptions.odin`'s `bootstrap_exceptions`.
Only three of glox's seven exception classes are bootstrapped
(`Exception`/`RunTimeError`/`EOFError`); `PickleError`/`ProcessError`/
`ThreadError`/`SyncError` belong to modules that either aren't
implemented yet (`pickle`/`process`) or are permanently out of scope
(`thread`/`sync` — see [Scope](#scope)), so adding their exception
classes now would be dead code. Add each alongside its own module.

Given the [package layout](#package-layout) decision above, core builtins
live inside the `vm` package itself (`builtins.odin`, plus
`builtins_math.odin`/`builtins_sys.odin`/`builtins_os.odin` — split by
glox's own module grouping, not by any Odin-level necessity), same as
glox's own split between `src/vm/builtin.go` (core) and `src/builtin/*.go`
(raylib-heavy) — the latter still becomes odlox's `natives` package once
Phase 6b starts; not created yet, since an empty package with a no-op
registration call would be scaffolding with no purpose (see
`ROADMAP.md`'s Phase 6 checklist).

### Raylib-backed graphics: non-obvious constraints

A handful of facts about the `gfx`-family native objects (`vm/gfx_window.odin`,
`gfx_texture.odin`, `gfx_batch.odin`, `obj_batch.odin`,
`obj_render_texture.odin`) aren't obvious from reading the code and are
easy to get wrong if touched without knowing them:

- **Matrix composition order for rotated/scaled 3D primitives.** raylib/
  OpenGL uses the column-vector convention, so transforming a mesh about
  its own center (not the world origin) requires composing
  `translation * rotation * scale`, in that order — reversing it rotates
  the object about the origin instead of about itself.
- **`begin_blend_mode()` is deliberately permissive.** Unlike every other
  method on `Window`, it doesn't validate its argument's type. A
  non-numeric mode value silently resolves to raylib's default alpha
  blending (via the same int-conversion path every other numeric argument
  uses, which itself defaults to 0 for a non-numeric input) rather than
  raising a runtime error — a deliberate API-permissiveness choice for
  this one call, not an oversight.
- **`draw_render_texture` and `draw_render_texture_ex` don't handle the
  Y-flip consistently.** A render texture is stored bottom-up by OpenGL;
  `draw_render_texture` compensates for this (negative source height),
  `draw_render_texture_ex` does not, and draws upside-down. Both are the
  real, current, intentional-if-inconsistent behavior of two sibling
  methods.
- **`render_texture.get_texture()`'s otherwise-pointless Load/Unload
  round trip is a GPU sync point**, not dead code: each render-texture
  drawing method opens and closes its own texture-mode context rather
  than holding one open across a frame, so the discarded
  `LoadImageFromTexture`/`UnloadImage` pair exists purely to force the
  GPU driver to finish in-flight writes before the texture it returns is
  safely sampled.
- **Translucent circle-quad batches must flush and disable depth-write
  around themselves** (`obj_batch.odin`'s `batch_draw`). raylib/rlgl's
  immediate-mode primitives only *queue* into a render batch rather than
  hitting the GPU right away, so an unflushed translucent quad can
  rasterize — and write depth, even at alpha 0 — before an
  earlier-queued opaque primitive it's meant to sit on top of.
- **`draw_array_fast`'s persistent GPU texture is updated in place, never
  recreated per frame** (`obj_render_texture.odin`'s `array_texture`).
  Loading and unloading a fresh GPU texture every frame races the
  driver's double-buffered pipeline: a freshly-loaded texture can reuse
  an ID still referenced by an in-flight draw call from the previous
  frame, producing stray stale-color pixels. Keeping one long-lived
  texture and updating its contents avoids this.

---

## Bytecode cache (.lxc)

**Shipped (Phase 8, `docs/plans/bytecode-cache.md`, `ROADMAP.md`'s own
Phase 8 section) — a completeness/faithfulness feature, not a performance
one.** Imported modules (never the entry script, matching glox) are
cached as compiled bytecode in `<module_dir>/__loxcache__/<name>.lxc`,
mtime-invalidated exactly like glox's own `.lxc` (cache used iff the
`.lxc` exists and is strictly newer than the source `.lox`) — `core/bc_cache.odin`
holds the pure format (a hand-rolled, length-prefixed, bounds-checked
binary encoding of a `Function_Object` tree, modeled on `core/pickle.odin`'s
own reader/writer shape rather than a straight port of glox's
`readValue`/`readChunk`), and `vm/bc_cache.odin` holds the file I/O, path
derivation, mtime comparison, and the `Function_Object.environment`
fixup a decoded tree needs before it's callable (core has no
`vm.Environment` in scope to do that itself).

Two deliberate points of departure from glox's own `.lxc`, both
explicit, not silent:

- **A 6-byte magic+version header.** glox's own `bc_cache.go` has none
  at all and relies solely on mtime for validity — its own `CLAUDE.md`
  documents the real cost of that: a stale `.lxc` written by an older
  binary schema can cause a hang or OOM panic when a newer binary blindly
  reinterprets its bytes under the current layout, since rebuilding the
  glox binary never touches any `.lox` file's mtime. odlox's decoder is
  already bounds-checked against the buffer it was given (no allocation
  is ever sized from an untrusted length — see `core/bc_cache.odin`'s own
  doc comment), which closes the hang/OOM failure mode on its own; the
  header closes the other one bounds-checking can't: a schema change
  whose bytes still happen to parse as *plausible*, differently-meaning
  data. A version mismatch falls back to a fresh compile exactly like any
  other unusable cache — never a hard error.
- **Int constants round-trip the full 8-byte payload, no truncation.**
  glox's own format truncates every int constant to a `uint32` on the
  cache round trip — a real, acknowledged bug there. `core/pickle.odin`
  had already settled this the other way for a different value
  population (see that file's own doc comment); this format follows the
  same precedent rather than reintroducing glox's bug.

Verification: `core/bc_cache_test.odin`/`compiler/bc_cache_test.odin`
round-trip both hand-built and real-`compiler.Compile`-produced
`Function_Object` trees and check every documented decode-error case
(bad magic, wrong version, truncation, a corrupted `property_caches`
count) never panics; `vm/bc_cache_test.odin` exercises the real
integration (a cache hit through a live module import, including a
closure nested two levels deep capturing a module global and a class
method invoked twice through one call site — the two places a subtly
wrong implementation would silently corrupt rather than crash); the
pytest-level `tests/new_tests/test_bc_cache.py` asserts byte-identical
output on a cold run (no cache) versus an immediately-following warm run
(cache hit) for `tests/new_tests/lox/bc_cache_roundtrip_stress.lox`. See
`ROADMAP.md`'s Phase 8 section for the full verification record.

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

## Embedding odlox in a host application

`src/main.odin` is a thin CLI wrapper (`package main`) around four
library-shaped packages: `core`, `compiler`, `vm`, `natives` (see
[Package layout](#package-layout)). Nothing else under `src/` declares
`package main`, so those four packages are already independent Odin
packages — embedding odlox in another Odin process needs no source
changes, only a way to import them and a handful of setup calls.

### Importing odlox from another Odin project

Odin has no project-level package manager; cross-project imports go
through the compiler's `-collection:name=path` flag, then
`import "name:subpackage"`. A host project builds with
`-collection:odlox=<path-to-odlox>/src` and then:

```odin
import "odlox:vm"
import "odlox:core"
```

The import identifier defaults to each package's own declared name
(`vm`, `core`) unless given an explicit alias, so this reads as
`vm.new_vm(...)`/`core.env_get_var(...)` etc. below, same as within
odlox's own source (and optionally `import "odlox:natives"` — see
"Choosing what to link" below).

### Minimal embedding sequence

The setup `main.odin`'s own `run_file` performs is the whole embedding
API surface today:

```odin
v := vm.new_vm("<embedded>")   // script is just a label for error messages/stack traces, not a required real path
vm.define_builtins(v)          // core builtins: len/type/append/range/vec2.../sys/os -- pure core+compiler, no raylib
status, result := vm.interpret(v, source)  // source is Lox text directly, no file I/O
```

- `vm.new_vm(script: string) -> ^VM` (`vm/vm.odin:145`).
- `vm.define_builtins(vm: ^VM)` (`vm/builtins.odin:27`) is an explicit,
  separate step from `new_vm` — a host can construct a VM and skip it
  entirely if it wants an even more minimal core.
- `vm.interpret(vm: ^VM, source: string) -> (Interpret_Result, string)`
  (`vm/interpret.odin:11`) takes source text directly; there's no file
  requirement anywhere in this path.
- Errors surface as data, not Odin panics: `status == .Runtime_Error`
  means `vm.error_msg` holds the message and `vm.print_stack_trace(vm)`
  (backed by `vm.stack_trace`) gives the full traceback, mirroring how
  `main.odin`'s own `run_file` reports a failure.

### Choosing what to link

`vm.define_builtins` alone is a complete scripting core with no raylib
dependency — arithmetic, classes, exceptions, lists/dicts, `sys`/`os`,
all work without importing `natives` at all.
`natives.define_natives` (`natives/natives.odin:29`) additionally
registers `gfx`/`sound`/`physics`/`re`/`pickle`/`process`/
`colour_utils`/`inspect`, but `natives/gfx.odin` imports
`vendor:raylib` — since `natives` is one Odin package, importing it at
all links raylib into the host binary, regardless of which
`register_*` proc actually gets called. There's no finer-grained split
that isolates raylib from the rest of that package.

A host that wants to expose its own native functions or objects to Lox
should **not** add them inside odlox's `natives` package — it should
write its own file following the `Userdata_Object` recipe documented in
`natives/README.md` (a data struct, a `core.Userdata_Vtable` with
`free`/`invoke` and optional `mark`/`to_string`/`size`, and
`core.make_userdata_object` + `vm.gc_track` to construct one), importing
only `odlox:vm`/`odlox:core`. That recipe is already package-agnostic;
it doesn't require being inside odlox's own source tree.

### Calling a Lox function from the host and getting a return value

No high-level "call this Lox function by name and get a value back"
wrapper exists yet, but the mechanism to build one already exists
internally: `vm/foreach.odin:76-82`'s `call_closure_now`, used to invoke
`__iter__`/`__next__` callbacks (`foreach.odin:44-48`) and native
`toString` dispatch (`run.odin:268-280`). It works by pushing the
callee and arguments, calling it, then re-entering the dispatch loop
with `run(vm, .Current_Function)` (`vm/run.odin:77`) — a mode that runs
until the specific frame just pushed returns (`run.odin:454`'s
`vm.frame_count == start_frame - 1` check), handing back the return
value directly.

`call_closure_now` deliberately restricts itself to an
already-resolved `Closure_Object` and the closure-only `call()`
(`vm/call.odin:56`), which *always* pushes a new `Call_Frame`. A host
calling an arbitrary global by name needs the more general
`vm.call_value(vm, callee, arg_count) -> bool` (`call.odin:10`) instead,
since the callee could be a Lox-defined function (`.Closure`) or a
registered native/builtin (`.Native`) — and those two cases behave
differently: `.Closure`/`.Class`/`.Bound_Method` callees push a frame
via `call()` and need `run(.Current_Function)` to drive them; a plain
`.Native` callee resolves synchronously inline (`call.odin:19-24`,
calls the native function directly and collapses the result onto the
stack immediately) with **no** frame pushed. Calling `run()`
unconditionally after `call_value` would misinterpret whatever frame
happens to be active for the native case, or crash outright if
`vm.frame_count` is 0 (e.g. a host calling in before any script has
run). The general pattern, checking whether a frame actually got
pushed:

```odin
name_obj := core.intern_string(name)
callee, ok := core.env_get_var(v.environment, name_obj)   // core/environment.odin:85
if !ok { /* undefined global */ }

start_frame := v.frame_count
vm.push(v, callee)
for a in args { vm.push(v, a) }
if !vm.call_value(v, callee, len(args)) { /* error: v.error_msg set */ }

result: core.Value
if v.frame_count > start_frame {
    // Closure/Class/Bound_Method: a frame was pushed, drive it to completion
    _, result = vm.run(v, .Current_Function)
} else {
    // Native: already resolved synchronously, collapsed onto the stack
    result = vm.pop(v)
}
```

Marshaling the returned `core.Value` back to an Odin type is manual and
per-type (`core.as_int`/`as_float`/`as_string`/`string_get`/... in
`core/value.odin`/`core/obj_string.odin`) — there's no generic
Value-to-Odin conversion function, the same convention every native
function already follows on the way in (see `natives/README.md`).

### Caveats

- **Three process-wide, not per-VM, mutable globals**:
  `core.intern_table` (string interning, `core/obj_string.odin`),
  `vm.module_cache`/`vm.module_source_cache` (`vm/module.odin:28,39`,
  whose own doc comment says they're "shared by every VM in the
  process"), and `vm.bootstrap_cache`/`bootstrap_ready`
  (`vm/exceptions.odin:79`). Multiple sequential VMs in one process
  share these by design — harmless, and even relied on by module-import
  sub-VMs — but VM instances aren't isolated sandboxes: interned
  strings and module state persist for the life of the process, not the
  life of a `^VM`. Nothing here is thread-safe (see
  [No concurrency anywhere](#no-concurrency-anywhere)); one VM per OS
  thread, sequential multi-VM use within a single thread is fine.
- **Module resolution touches disk only if the embedded source actually
  `import`s something.** `vm/module.odin`'s `read_module_source`
  resolves via `$LOX_PATH/modules/<name>.lox` or a directory walk
  relative to `vm.root_script`'s directory — there's no VM field to
  override this, only the `LOX_PATH` env var. A host embedding synthetic
  (non-file-backed) Lox source whose scripts `import math`/`random`/etc.
  needs `LOX_PATH` set to odlox's `modules/` directory (or its own copy
  of it); a synthetic `script` label passed to `new_vm` has no real
  directory to walk.
