# CLAUDE.md

Guidance for Claude Code when working in this repository (odlox: an Odin port of glox/jlox).

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
