# odlox

An Odin port of [glox](https://github.com/nickharrismcr/glox) — a bytecode
interpreter for a Lox-derived language (from *Crafting Interpreters*),
extended with lists/dicts/tuples/slices, exceptions, module imports,
closures, classes, `foreach`/`range`, integer arithmetic, string
interpolation, native `vec2`/`vec3`/`vec4` types, and Raylib bindings.

Ported from the `experimental/gc-odin-port-basis` branch, which added a
Go-side mark-and-sweep GC specifically to serve as this port's design
blueprint.

No code exists yet — this repository currently holds only the planning
documents:

- **[`ROADMAP.md`](ROADMAP.md)** — the phased build order (scanner →
  compiler → VM/GC → native/stdlib → performance) and the running todo
  list. Start here for "what to build next."
- **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — the full design
  record: package layout, value/object representation, garbage collector
  design, calling convention, and — throughout — where and why this port
  deliberately does something Go's version couldn't. Start here for "why
  is it shaped this way" when modifying anything later.

## Scope

Threads (`thread.*`/`sync.*`) are permanently out of scope; the VM does
not need to be thread-safe. Raylib/graphics natives, `pickle`/`regexp`/
`process` modules, and the `.lxc` bytecode cache are later, lower-priority
phases layered on top of a working core interpreter — see `ROADMAP.md` for
the exact phase breakdown.
