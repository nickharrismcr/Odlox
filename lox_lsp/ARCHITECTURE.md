# jslox architecture reference

`jslox` (VS Code extension id `lox-lsp`, upstream `fjakobs/jslox`) started as a TypeScript
reimplementation of **jlox**, the tree-walking interpreter from part II of Bob Nystrom's
_Crafting Interpreters_, bundled with a Language Server Protocol (LSP) server and VS Code
client that provide editor tooling for `.lox` files.

This fork (now `lox_lsp/`) has since had the tree-walking interpreter and its runtime object
model deleted (`Interpreter.ts`, `Environment.ts`, `LoxClass.ts`, `LoxFunction.ts`,
`LoxInstance.ts`, `Buildins.ts`, `Lox.ts`, `main.ts`, and their tests) — see §2. Nothing here
executes `.lox` code any more; it is LSP-only tooling (diagnostics, semantic tokens,
go-to-def, rename) on top of the Scanner/Parser/Resolver front end, which is all odlox scripts
actually need editor-side (script execution itself happens in odlox's own VM). This is a
from-scratch TS port, not vanilla jlox: it already carries a handful of non-book additions
(`break`/`continue`, no `for`-desugaring, unused-variable warnings, go-to-definition/rename
support baked into the resolver) — see §7.

This document exists to make the codebase legible before patching it to also understand
**odlox** syntax (the extended Lox dialect implemented in Odin at the root of this repo, see
`../docs/language-reference.html`). That migration (extending the Scanner/Parser/Resolver to
cover odlox's grammar on top of vanilla Lox) is complete — read `Token.ts`/`Scanner.ts`/`Parser.ts`
directly for the current grammar rather than a planning doc.

## 1. Repo layout

```
src/jslox/          the front end (scanner → parser → resolver); no runtime/interpreter here
  Token.ts             TokenType enum + Token class
  Scanner.ts            source text → Generator<Token>
  Expr.ts               Expr/Stmt AST node classes + Visitor<R> interface (GENERATED)
  astGenerator.ts        code-gen script that emits Expr.ts from a grammar table
  Parser.ts              Generator<Token> → Stmt[] (recursive descent, single lookahead)
  Resolver.ts             Visitor<void>: scope resolution + go-to-def/rename bookkeeping
  Error.ts                  ErrorReporter interface + RuntimeError
  PrettyPrinter.ts           Visitor<string>: s-expression printer (tests/debug only)
  *.test.ts                  ts-mocha unit tests per module

src/server/          the LSP server (consumes src/jslox/, never touches Interpreter.ts)
  LoxLspServer.ts        request handlers (definition, references, rename, semantic tokens...)
  LoxDocument.ts          per-document state + the analyze() pipeline
  WorkspaceIndex.ts       tracks a LoxDocument per file ever touched (open or import-reached),
                            resolves `from <module> import ...` across files
  ModuleResolver.ts       module name -> .lox file path on disk (mirrors odlox's own search order)
  SemanticTokenAnalyzer.ts  Visitor<void>: semantic tokens + DocumentSymbol tree
  server.ts               vscode-languageserver connection wiring, capability registration

src/extension.ts, src/lsp-client.ts   VS Code client bootstrap (activates, spawns server over IPC)
syntaxes/lox.tmLanguage.json          TextMate grammar (regex-based syntax highlighting)
language-configuration.json           bracket/comment/auto-close config
package.json                          VS Code `contributes` (language id, grammar, activation)
```

## 2. Pipelines

**LSP** (`LoxDocument.analyze()`, re-run in full on every keystroke, no debouncing, no cached
AST between runs): `Scanner → Parser → Resolver → SemanticTokenAnalyzer`. This is the only
pipeline that exists in this fork now.

There used to also be a **CLI / REPL** pipeline (`main.ts` → `Lox.ts`:
`Scanner → Parser → Resolver → Interpreter`, full execution) inherited from upstream jslox.
It has been deleted along with the tree-walking `Interpreter` and its runtime object model
(`LoxClass.ts`/`LoxFunction.ts`/`LoxInstance.ts`/`Environment.ts`/`Buildins.ts`) — none of it
was reachable from the LSP path to begin with (editor tooling only ever needed Scanner/Parser/
Resolver/SemanticTokenAnalyzer), so removing it doesn't change LSP behavior. Do not reintroduce
these files without an explicit reason to actually execute `.lox` code again — doing so properly
would mean rebuilding a runtime object model for all of odlox's extensions (modules, lists/dicts/
tuples, try/except, etc.), not just restoring the deleted jlox-era `Interpreter.ts`.

## 3. Token / keyword inventory (`Token.ts`, `Scanner.ts`)

The odlox migration is complete — lists/dicts/tuples, `foreach`/`in`, `try`/`except`/`raise`,
`import`/`from...import`, `const`, string interpolation, significant newlines, `?:`, compound
assignment, `%`, `[`/`]`, `INT`/`FLOAT` split, etc. are all implemented in `Scanner.ts`/`Parser.ts`.
Read those two files directly for the current token/keyword set rather than relying on a
description here, which would just go stale the next time either changes.

`and class else false for fun if nil or print return super this true var while` plus
non-standard `break`/`continue` are the vanilla-jlox-era keywords (Scanner.ts comments these
`// non standard`); §4 below shows the grammar odlox added on top (also stale in the same sense —
treat it as a rough map, not a spec).

Scanner mechanics: tokens are produced **lazily via a generator** (`function* scanTokens()`);
`Parser` pulls one token at a time (`tokens.next()`), so there is no token array to
backtrack/index into beyond the single `current`/`previous` lookahead the parser keeps.

## 4. Grammar (reconstructed from `Parser.ts`)

```
program        → declaration* EOF ;
declaration    → funDecl | classDecl | varDecl | statement ;
funDecl        → "fun" function ;
function       → IDENTIFIER "(" parameters? ")" block ;
classDecl      → "class" IDENTIFIER ( "<" IDENTIFIER )? "{" function* "}" ;
                 (methods have no leading "fun"; "init" is the constructor)
varDecl        → "var" IDENTIFIER ( "=" expression )? ";" ;   (no initializer ⇒ nil)

statement      → exprStmt | printStmt | block | ifStmt | whileStmt | forStmt
               | breakStmt | continueStmt | returnStmt ;
forStmt        → "for" "(" (varDecl|exprStmt|";") expression? ";" expression? ")" statement ;
                 (dedicated ForStmt node — NOT desugared to while, unlike book jlox,
                  so `continue` can still run the increment clause)
breakStmt      → "break" ";" ;      continueStmt → "continue" ";" ;   (non-standard)

expression     → assignment ;
assignment     → ( call "." )? IDENTIFIER "=" assignment | logic_or ;
logic_or       → logic_and ( "or" logic_and )* ;
logic_and      → equality ( "and" equality )* ;
equality       → comparison ( ("!="|"==") comparison )* ;
comparison     → term ( (">"|">="|"<"|"<=") term )* ;
term           → factor ( ("-"|"+") factor )* ;
factor         → unary ( ("/"|"*") unary )* ;
unary          → ("!"|"-") unary | call ;
call           → primary ( "(" arguments? ")" | "." IDENTIFIER )* ;
primary        → NUMBER | STRING | "true" | "false" | "nil" | "(" expression ")"
               | IDENTIFIER | "this" | "super" "." IDENTIFIER ;
```

All binary levels are left-associative; unary is right-associative via direct recursion.
Panic-mode recovery: a `ParseError` thrown mid-`declaration()` is caught and `synchronize()`
skips to the next statement boundary (past a `;` or right before `class fun var for if while
print return`).

## 5. AST / visitor mechanics — the key extension point

`Expr.ts` defines **both** `Expr` and `Stmt` node classes (no separate `Stmt.ts`) plus one
unified `Visitor<R>` interface with a `visitXxx` method per node. Every node is an immutable,
`readonly`-field value object; double dispatch via `node.visit(visitor) → visitor.visitNodeName(this)`.
(Node/method count is stale to quote here post-odlox-migration — count `visit` methods on
`Visitor<R>` in `Expr.ts` directly if it matters.)

`Expr.ts` is **generated**: `npm run lox:generate` runs `ts-node src/jslox/astGenerator.ts >
src/jslox/Expr.ts`, driven by a `grammar: Record<string, string[]>` table in
`astGenerator.ts` mapping `"ClassName ParentInterface"` → field list. **This table is the
single source of truth for node shapes**.

Because TypeScript is structurally typed, every class implementing `Visitor<R>` must handle
every method on the interface. **Three** concrete visitors exist now that `Interpreter` is
gone, and adding a node type to the grammar table means all three need a case:

1. `Resolver implements Visitor<void>` — scope resolution
2. `PrettyPrinter implements Visitor<string>` — s-expr printer, tests only
3. `../server/SemanticTokenAnalyzer.ts implements Visitor<void>` — semantic tokens + symbols

`Parser.ts` doesn't implement `Visitor` (it constructs nodes, doesn't walk them), but every
new node type needs a construction site here too.

`Literal.value`'s type lives in `Expr.ts` — widen it there for any new literal kind. There is
no `LoxType`/runtime-value union any more (that was `Interpreter.ts`'s, now deleted); nothing
in this fork represents runtime values.

## 6. Resolver (`Resolver.ts`) — beyond book jlox

Single semantic-analysis pass between parse and interpret. `scopes: Array<Map<string, false |
Token>>` — stores the **declaring token** (not just a boolean) in each scope entry, which is
what powers IDE features absent from the book:

-   `resolved: Map<Expr, number>` — scope-distance map (fed an interpreter's O(1) lookups back
    when this fork had one; kept because `Resolver`'s scope-walking logic still produces it as a
    byproduct, unused downstream now)
-   `definitions: Map<Token, Token[]>` — declaration → every usage site (unused-var warnings, find-references)
-   `references: Map<Token, Token>` — usage → its declaration (go-to-definition), same-document only
-   `definitionType: Map<Token, "parameter"|"function"|"class"|"property">` — feeds semantic token coloring
-   `exports: Map<string, Token>` — every module-scope (top-level) binding this file makes, by
    name; what a `from <thisFile> import ...` elsewhere resolves against. Populated in `define()`
    alongside `isGlobalDefinition`.
-   `moduleReferences: Map<Token, {moduleName: string; token: Token}>` — usage → the module it was
    imported from plus its declaring token _in that module's own token stream_. Separate from
    `references` (which assumes both ends live in this document) since `Resolver` has no concept
    of files/URIs; `LoxDocument` resolves `moduleName` to a URI afterward, see §10.

The constructor's optional second argument, `resolveImport?: (moduleName: string) => Map<string,
Token> | undefined`, is how a `Resolver` instance reaches across files without knowing anything
about the filesystem. Both `import` forms use it, in `visitImportFromStmt`/`visitGet`:

-   `from x import a, b` / `from x import *` fetch `x`'s `exports` table and link the named (or,
    for `*`, every) import to its real declaring token via `ScopeEntry.crossModule`, instead of (as
    before) declaring them as if they were defined at the import statement itself. `*`-imported
    bindings bypass `declare()`/`define()` entirely (there's no local name token for one) and,
    deliberately, aren't added to `this.exports` either — a further `from thisFile import x` won't
    chase back through to the _original_ module. Re-export chains stop one hop short by design,
    not tracked further.
-   `import x [as y]` still binds `x`/`y` as a plain value via `declare()`/`define()` (so `x` itself
    behaves like any other variable — reassignable, shadowable, etc.), but `define()` also records
    which module it names via `ScopeEntry.moduleNamespace`. `visitGet` checks this when resolving
    `x.name`: unlike an arbitrary object's properties (genuinely dynamic, e.g. instance fields set
    from anywhere), a module namespace's properties are exactly its exports, so `x.name` resolves
    the same way a named import would, via the same `resolveImport` callback and `moduleReferences`
    map — just recorded at each `.name` access site instead of at the import statement. Only the
    direct case is handled (`get.object` a bare `Variable` known to be a namespace); a computed or
    chained object expression falls back to no resolution, same as any other property access.

Undefined `resolveImport` (the default, used by `lint-cli.ts` and `Resolver.test.ts`) means
imports still parse and declare locally as before, just without a real cross-file link —
single-file callers don't need to change.

Also tracks `currentClass`/`currentFunction`/`loopDepth` to validate `this`/`super`/`return`/
`break`/`continue` context, and emits a `warn()` for every declared-but-unused variable.

## 7. Deviations from vanilla jlox already present

1. `break`/`continue` are real tokens/statements validated by `Resolver`'s `loopDepth`
   tracking (§6); the book's `BreakException`/`ContinueException` were an `Interpreter`-side
   mechanism and no longer exist in this fork (§2) — nothing here executes them any more, they
   just need to parse/resolve correctly
2. `for` is a dedicated `ForStmt` node, not desugared to `while` (so a hypothetical interpreter
   could still run the increment on `continue` — moot now, but shapes the AST/Resolver either way)
3. Unused-variable warnings
4. Resolver scope maps store the declaring token, not a boolean — the whole IDE-feature layer
5. Scanner emits a lazy `Generator<Token>`, not an eager array

## 8. Built-ins

Removed along with the interpreter (§2) — `Buildins.ts` provided exactly one native
(`clock()`) to the tree-walker and had no LSP-side purpose.

## 9. Error model (`Error.ts`)

`ErrorReporter` interface: `error()` / `warn()` / `runtimeError()` — three severities, no
"info"/"hint", no error codes, no related-location support. `TokenPosition = {line, start,
end}` (absolute char offsets, Range-friendly for LSP). `silentErrorReporter` exists for
speculative parsing. `ParseError` is an internal control-flow exception, caught inside
`declaration()`. `RuntimeError` still exists as a class (the `ErrorReporter.runtimeError()`
signature and a couple of test mocks reference its type), but nothing in this fork throws or
catches one any more — that only happened inside the now-deleted `Interpreter`.

## 10. LSP server layer (`src/server/`)

**`LoxDocument.ts`** — per-document state: `diagnostics[]`, `hadError`, `definitions`,
`references`, `exports`, `moduleReferences`, `semanticTokens[]`, `documentSymbols?`. **No
cached AST** — `analyze()` reruns the whole pipeline from scratch every call and discards the
parsed `Stmt[]` once derived artifacts are extracted. One shared `ErrorReporter` closure across
scan/parse/resolve pushes `Diagnostic`s and sets `hadError`; `runtimeError` is a no-op (there is
no interpreter to run it). If parsing fails, `definitions`/`references` are **not cleared** —
they keep last-good values. No debouncing: every keystroke → full re-analyze.

`analyze()` optionally takes a `resolveImport(moduleName) => {uri, exports} | undefined`
callback (supplied by `WorkspaceIndex`, see below); it wraps this for `Resolver`, capturing
which URI each imported module name resolved to, then turns `Resolver.moduleReferences`
(moduleName-keyed, since `Resolver` itself has no filesystem/URI concept) into
`LoxDocument.moduleReferences` (URI-keyed, what the LSP layer builds `Location`s from). `exports`
is just `Resolver.exports` passed through unchanged — every module-scope binding this file
makes, by name, for some _other_ file's `resolveImport` call to consume.

**`ModuleResolver.ts`** — `resolveModulePath(moduleName, importingFilePath, workspaceRoot)`:
pure filesystem lookup, no LSP/document state. Approximates odlox's own module search order
(`src/vm/module.odin`'s `read_module_source`: `$LOX_PATH/modules/<name>.lox`, then alongside the
_entry script_, then a recursive search of the entry script's directory tree) as best it can
without a concept of "entry script" — substitutes the workspace root for both `LOX_PATH` and the
recursive-search base, and the importing file's own directory for "alongside the entry script".

**`WorkspaceIndex.ts`** — the thing that makes cross-file resolution possible at all: tracks a
`LoxDocument` per file the server has ever needed, not just files open in an editor tab. Two
kinds of entry, keyed by a case-normalized absolute fs path (not the raw URI string, which can
differ in casing/escaping depending on where it came from — see the exported `fileKey` helper):
"open" documents (content from the live `TextDocuments` buffer, kept current by
`LoxLspServer.onDidChangeContent`) and "disk" documents (read via `fs`, cached, re-read only when
mtime changes). `resolveImport(moduleName, fromUri)` is the callback `LoxDocument.analyze()`
consumes: resolves the module path via `ModuleResolver`, lazily analyzes that file if needed
(recursively wiring its own `resolveImport` the same way), and returns its `uri` + `exports`. A
`Set` of in-progress paths breaks circular imports (A imports B, B imports A) rather than
recursing forever. `allDocuments()` exposes everything indexed so far.

`resolveImport` alone only discovers documents by following import edges _forward_
(importer → imported) — opening the file a class is declared in never causes its importers to
be analyzed, since nothing there imports anything. `scanWorkspace()` is the other direction:
walks every `.lox` file under the workspace root (via `ModuleResolver.findAllLoxFiles`, same
skip-dirs/file-count bound as the recursive import search) and analyzes each one that isn't
already indexed or unchanged since its last read (still mtime-cached, so repeat calls are cheap).
`LoxLspServer` calls this before any reverse lookup (find-references, rename) — see below.

**`LoxLspServer.ts`** handlers, all synchronous (no live jslox calls except `analyze()`
itself, invoked through `WorkspaceIndex`): `onDidChangeContent` (only diagnostics push path),
`onDefinition`, `onReferences`, `onSemanticTokens`, `onDocumentSymbol`, `onRename`,
`onPrepareRename`, `onDocumentHighlight`. **No hover, no completion, no code actions, no
formatting** are implemented.

`onDefinition`/`onReferences`/`onRename` check `LoxDocument.references`/`definitions` (local,
same-document) first, then fall back to `moduleReferences` (cross-file). `onReferences`/`onRename`
also need the _reverse_ direction — every other file that imports the clicked declaration — so
they call `WorkspaceIndex.scanWorkspace()` first, then scan every document it holds for incoming
`moduleReferences` that point back at that declaration. This makes "find references" and
"rename" workspace-wide, not just reachable-via-currently-open-imports, at the cost of a full
directory walk (bounded, mtime-cached) on every call. There's still no invalidation of _other_
documents' `moduleReferences` when the file they point into is re-analyzed (edited) — those links
hold stale `Token` objects until whatever imported them is itself re-analyzed (which the next
`scanWorkspace()` call does, since edited files fail the mtime check). Consistent with
`LoxDocument`'s existing no-caching/no-debounce approach: correctness on the next request, not on
every intermediate keystroke.

**`extension.ts`/`lsp-client.ts`** — minimal: spawns `out/server/server.js` over IPC,
`documentSelector: [{scheme:"file", language:"lox"}]`. No client-only features.

**`package.json` contributes`**: one language (`id: "lox"`, extension `.lox"`), one grammar
(`scopeName: "source.lox"` → `syntaxes/lox.tmLanguage.json`). No commands/settings/snippets.

**`syntaxes/lox.tmLanguage.json`** — regex-only TextMate grammar, four repository rules:
`keywords` (control/operator/constant/storage scopes, all simple `\b...\b`), `numbers`
(`\b[0-9]+(?:.[0-9]+)?\b` — note the **unescaped `.`**, a pre-existing minor grammar bug),
`strings` (`"..."` with `\\.` escape scope, no interpolation), `comments` (`//` only). No
scopes at all for identifiers, general operators, or punctuation.

**`language-configuration.json`** — line comment `//`, bracket pairs `{} [] ()` (already
includes `[]` despite no bracket token existing in the grammar yet), matching auto-close pairs.
No folding markers, no indentation rules.

## 11. Known gaps worth knowing before touching this code

-   `LoxLspServer.onSemanticTokens` has a stray `console.log(token, typeId)` debug leftover
-   `LoxDocument.findAllFromPosition`'s inner loop doesn't `break` after a match (harmless, just wasted work)
-   `definitions`/`references` go stale (not cleared) on a failed reparse
