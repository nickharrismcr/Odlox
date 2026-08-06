# CLAUDE.md

Guidance for Claude Code when working in this repository (odlox: an Odin port of glox/jlox).

## Doc/comment style: neutral and technical

README.md, ARCHITECTURE.md, doc comments, commit messages: describe what the code does and why,
in plain technical language. Avoid:
- Value judgements about the work itself (e.g. calling a result "honest", "clean", "elegant",
  "solid") -- state the fact the adjective was standing in for instead.
- Assurances of honesty/trustworthiness ("to be fair", "honestly", "the real bottleneck is") --
  the reader isn't questioning good faith; framing it that way implies they should.
- Chatty asides, hedging, or first-person commentary on the writing itself.

State the finding directly. "The object-heavy end of the suite is the honest bottleneck" ->
"The object-heavy end of the suite is dominated by one cost." "Genuinely hard target to beat" ->
"a difficult target to beat." The information content is identical; only the editorializing is
removed.

## Linting `.lox` scripts with the jslox LSP

There's no linter built into odlox itself (`--compile-only` only catches parse errors, not
unused-variable/scope-style warnings). A separate reference project, **jslox**
(`d:\go\glox\jslox`), implements a real Lox Language Server (Scanner -> Parser -> Resolver,
`src/server/LoxDocument.ts`) and is the extension that produces live diagnostics when editing a
`.lox` file in this editor. To batch-lint many files from the command line instead of opening each
one, use `d:\go\glox\jslox\src\lint-cli.ts` (a small standalone driver added there that runs the
same Scanner/Parser/Resolver pipeline `LoxDocument` runs per-file, printing `path:line: error:
...` / `path:line: warning: ...`):

```bash
cd /d/go/glox/jslox
npx ts-node src/lint-cli.ts <file1.lox> <file2.lox> ...
```

**Windows command-line length limit**: passing more than ~30-40 files at once fails with "The
command line is too long." Chunk the file list (e.g. `split -l 30`) and invoke per chunk rather
than passing the whole codebase in one call.

### Known false-positive classes -- don't chase these as real bugs

Running this linter across odlox's full `.lox` codebase (lox_examples/, modules/,
tests/new_tests/lox/) turns up one remaining category of noise that is **not** a real problem:

**"Variable 'X' is declared but never used" is unreliable when X shadows an outer-scope
variable of the same name.** Verified via a minimal repro:
```
win = 1
class Foo {
    draw(win) {
        print win
    }
}
```
jslox's Resolver reports the `win` parameter as unused even though it's referenced in the
body -- the reference resolves to the wrong declaration when a name is shadowed. Confirmed
on a real case in `lox_examples/3d_shapes_mem_shader.lox` (`draw(win)`, `win` used inside).
Treat every "declared but never used" warning as a *lead to check by hand*, not something to
mechanically fix (e.g. by renaming) -- many of the rest are also legitimate intentional
patterns (`except Exception as e { ... }` not touching `e`, a loop counter kept only for
iteration), not bugs. (This shadowing bug is still open in jslox as of `lox-lsp-0.0.7` -- not
yet fixed the way the bare-finally gap below was.)

Given this, a lint pass that reports zero *unexpected* errors (i.e. nothing outside the class
above, and outside deliberately-invalid negative-test fixtures like
`tests/new_tests/lox/break_outside_loop.lox`) means the codebase is clean -- there's nothing left
to "fix."

**Previously false-flagged, now fixed upstream in jslox (`lox-lsp-0.0.7`)**:
`try { ... } finally { ... }` with no `except` clause used to report
`Expect 'except'.` / `Expect expression.` -- jslox's Parser predated odlox adding bare
try/finally support (see `tests/new_tests/lox/finally_bare.lox`'s own header comment:
"previously a parse error..."). Fixed in jslox's `Parser.ts`/`Resolver.ts`/`Expr.ts` (`TryStmt`
gained a `finallyBlock` field); if this reappears, the installed extension version has
regressed or reverted, not the script.

## Lox syntax gotcha: trailing commas

Verified directly against odlox's own compiler (`--compile-only`):

- **Allowed**: a trailing comma after the last item in a list `[1, 2, 3,]` or dict
  `{"a": 1, "b": 2,}` literal, including across multiple lines.
- **A syntax error**: a trailing comma in a function **parameter list**
  (`func f(a, b,) { ... }` -- "Expect parameter name.") or a **call argument list**
  (`f(1, 2,)` -- "Expect expression.").

This has tripped Claude up more than once when writing multi-line Lox calls -- Odin's own
composite-literal convention idiomatically keeps a trailing comma on the last element, and that
habit doesn't carry over to Lox function calls/parameter lists. When writing a multi-line
`some_call(\n    a,\n    b,\n)`-shaped call or `func f(\n    a,\n    b,\n)`-shaped definition,
drop the comma after the last argument/parameter.

## Performance: avoid per-frame/per-cell allocation in graphics scripts targeting 60fps

odlox's GC is mark-sweep. Allocating inside a loop that runs every frame (or every cell, every
frame) creates continuous churn the collector must periodically sweep, which shows up as
occasional multi-hundred-ms stalls -- not steadily lower fps, a stall. This is independent of the
debug-vs-release build gap (bounds-checking/`-o:speed`): it happens in `--release` builds too,
since it's heap pressure, not instruction overhead.

**When writing or editing a `.lox` script targeting real-time (60fps-class) rendering, allocate
every per-frame working buffer once, up front, and write into it in place every frame --
never allocate a new list/float_array/dict inside a loop that runs every frame or every cell.**
Concretely:
- A function that builds and returns a fresh collection each call (e.g. a per-row or per-cell
  scratch buffer) should instead take an `out` parameter and write into that, with the buffer
  itself allocated once at startup as a module-level variable.
- Where more than one buffer role is needed at once (e.g. a rolling prev/curr/next window), use a
  small *fixed* pool of buffer objects rotated by reference reassignment (swap which variable
  points at which buffer) -- never grow the pool or allocate a replacement per iteration.
- A larger intermediate result needed once per frame/generation (a derived grid, an indicator
  array) should be one of a small set of preallocated buffers passed in, not freshly constructed
  on every call.

Real case: `lox_examples/game_of_life.lox` was allocating a fresh `cols`-length list every grid
row, every generation, for every ruleset (`horiz_sum_of`), plus a fresh grid-sized `float_array`
per call in `state_indicator`/`neighbour_count_array` (up to 8 such allocations per generation for
the QuadLife ruleset) -- this produced occasional multi-hundred-ms stalls, roughly once per
ruleset. Fixed by preallocating a small fixed set of row/grid buffers once at startup
(`ROW_BUF_A/B/C`, `IND_BUF_1..4`, `COUNT_BUF_1..4`) and writing into them every generation instead;
allocation from this machinery is now zero regardless of ruleset.
