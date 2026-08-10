# Lox LSP

A VS Code Language Server extension for `.lox` files, providing editor tooling for **odlox**, the
extended Lox dialect used throughout this repository (see `../docs/language-reference.html`).

## What it does

Live diagnostics (parse errors, unused-variable warnings) plus:

-   Semantic syntax highlighting
-   Go to definition
-   Find references
-   Rename symbol
-   Go to symbol / document outline
-   Highlight document (all references to the symbol under the cursor, scoped to the open file)

Go to definition, find references, and rename all resolve across files: a symbol brought in via
`import module` / `from module import name` links back to its real declaration in the module
that defines it, not just the local import statement. See `ARCHITECTURE.md` §6/§10 for how.

It does not execute `.lox` code — odlox scripts run on odlox's own VM (`odin build .` /
`bin/odlox.exe` at the repo root). This extension only ever analyzes source text.

## What it's based on

A fork of [`fjakobs/jslox`](https://github.com/fjakobs/jslox), itself a TypeScript
reimplementation of **jlox**, the tree-walking interpreter from part II of Bob Nystrom's
[_Crafting Interpreters_](https://craftinginterpreters.com/), bundled with an LSP server. This
fork has since:

-   deleted jlox's tree-walking interpreter and runtime object model entirely — nothing here
    executes code, only the Scanner → Parser → Resolver front end an editor needs
-   extended that front end to understand odlox's grammar (modules/`import`, lists/dicts/tuples,
    `try`/`except`/`raise`, `foreach`, string interpolation, significant newlines, and more)
-   added cross-module resolution on top of jslox's original single-file-only Resolver

See `ARCHITECTURE.md` for the full breakdown of what changed and why.

## Installing

There's no marketplace listing — install a locally built `.vsix`:

1. **Bump the version** in `package.json` (e.g. `0.0.12` → `0.0.13`). VS Code treats installing a
   `.vsix` at an already-installed version number as a no-op, so this step is required every time
   for a rebuilt extension to actually take effect.
2. **Package it**:
    ```bash
    npm install
    npm run package
    ```
    This runs `vsce package` and produces `lox-lsp-<version>.vsix` in this directory.
3. **Install the `.vsix`** — in VS Code: Extensions view → `...` menu → **Install from VSIX...**,
   or from the command line:
    ```bash
    code --install-extension lox-lsp-<version>.vsix
    ```
4. **Reload the window** (Ctrl+Shift+P → **Developer: Reload Window**) to activate the new build.
   Recompiling (`npm run compile`) alone does not update an already-installed extension — only a
   version-bumped reinstall does.

## Development

`npm run lox:test` runs the unit test suite (`ts-mocha`); `npm run compile` type-checks and
builds `out/`. See `ARCHITECTURE.md` for the codebase layout and design notes, and
`d:\odin\odlox\CLAUDE.md` for how this extension is used to lint `.lox` scripts elsewhere in this
repository.
