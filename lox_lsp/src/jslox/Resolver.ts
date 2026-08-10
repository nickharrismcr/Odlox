import {
    Assign,
    Binary,
    Block,
    BreakStmt,
    BreakpointStmt,
    Call,
    ClassStmt,
    ContinueStmt,
    DictLiteral,
    Expr,
    Expression,
    ForStmt,
    ForeachStmt,
    FunctionStmt,
    Get,
    Set,
    Grouping,
    IfStmt,
    ImportFromStmt,
    ImportStmt,
    IndexExpr,
    IndexSet,
    Lambda,
    Literal,
    ListLiteral,
    Logical,
    Param,
    PrintStmt,
    RaiseStmt,
    ReturnStmt,
    SliceExpr,
    SliceSet,
    Stmt,
    StrExpr,
    Ternary,
    TryStmt,
    TupleLiteral,
    Unary,
    UnpackStmt,
    Variable,
    VariableDeclaration,
    Visitor,
    WhileStmt,
    ThisExpr,
    SuperExpr,
} from "./Expr";
import { Token } from "./Token";
import { ErrorReporter, defaultErrorReporter } from "./Error";

export type FunctionType = "none" | "function" | "initializer" | "method";
export type ClassType = "none" | "class" | "subclass";

// A scope entry is `false` while a name has been declared but its initializer
// hasn't been resolved yet (catches `var a = a;`), or the declaring token
// (plus whether the binding is `const`) once fully defined. `crossModule` is
// set instead of a same-document declaring token being meaningful when the
// binding came from `from <module> import ...` and resolved to a real
// declaration in another file (see `moduleReferences` below) -- `token` is
// still populated in that case (the local import-site name token, or a
// placeholder for `import *`) so scope bookkeeping doesn't need a second
// optional field to check everywhere. `moduleNamespace` is set instead for a
// plain `import <module> [as alias]` binding -- unlike an arbitrary object,
// a module namespace's properties are exactly its exports, so `visitGet`
// uses this to resolve `<binding>.<name>` the same way a named import would,
// without treating every other property access as statically resolvable.
type ScopeEntry =
    | false
    | { token: Token; isConst: boolean; crossModule?: { moduleName: string; token: Token }; moduleNamespace?: string };

export class Resolver implements Visitor<void> {
    private scopes: Array<Map<string, ScopeEntry>> = [new Map()];
    readonly resolved: Map<Expr, number> = new Map();

    // map of variable name to list of tokens where it is used
    readonly definitions: Map<Token, Array<Token>> = new Map();

    // map of variable name to token where it is declared
    readonly references: Map<Token, Token> = new Map();

    readonly definitionType: Map<Token, "parameter" | "function" | "class" | "property"> = new Map();

    // Every module-scope (top-level) binding this file makes, by name --
    // what a `from <thisFile> import ...` elsewhere would see. Populated
    // alongside isGlobalDefinition in define(); LoxDocument hands this to
    // other documents' Resolver instances via resolveImport.
    readonly exports: Map<string, Token> = new Map();

    // reference token (in *this* document) -> the module it was imported
    // from plus its declaring token *in that module's own token stream*.
    // Kept separate from `references` (which assumes both ends live in this
    // document) -- LoxDocument resolves `moduleName` to a URI and merges
    // this into a URI-qualified map for the LSP layer.
    readonly moduleReferences: Map<Token, { moduleName: string; token: Token }> = new Map();

    // Whether each definition was declared at top-level (module) scope, set at
    // define() time. Used to skip the unused-variable warning for globals:
    // even though a Resolver instance can now see into another module's
    // exports (via resolveImport/moduleReferences above), it still only
    // analyzes *this* file's own body -- it has no way to know whether some
    // other, unanalyzed file imports a given module-level binding. Flagging
    // globals as unused would still produce real false positives (e.g.
    // collide.lox's functions, used only from entity_mgr.lox), so this stays
    // a blanket exemption rather than trying to use moduleReferences (which
    // only reflects documents the workspace happens to have indexed so far,
    // see WorkspaceIndex) as a source of truth for "is this really unused".
    // A genuinely local (function/block-scoped) unused variable is still
    // real, useful signal and stays flagged.
    private isGlobalDefinition: Map<Token, boolean> = new Map();

    private currentClass: ClassType = "none";
    private currentFunction: FunctionType = "none";
    private loopDepth = 0;

    constructor(
        private errorReporter: ErrorReporter = defaultErrorReporter,
        // Looks up another module's exports by name (LoxDocument wires this
        // to the workspace index). Undefined in single-file contexts
        // (lint-cli.ts, tests) -- imports still parse/declare fine, they
        // just can't link to a real cross-file declaration.
        private resolveImport?: (moduleName: string) => Map<string, Token> | undefined
    ) {}

    resolve(statements: Array<Stmt>) {
        for (const statement of statements) {
            statement.visit(this);
        }
        for (const [name, tokens] of this.definitions) {
            if (tokens.length === 0 && !this.isGlobalDefinition.get(name)) {
                this.errorReporter.warn(name, `Variable '${name.lexeme}' is declared but never used.`);
            }
        }
    }

    visitAssign(assign: Assign) {
        assign.value.visit(this);
        // glox auto-declares a bare `name = expr` if `name` isn't visible
        // anywhere yet, rather than treating it as an error (matches
        // declareVariable()'s implicit-global behavior in glox's own
        // src/compiler/compile.go). glox itself only allows this at
        // bare-statement level; here it applies to any Assign, a deliberate,
        // documented simplification -- jslox's Parser (unlike glox's
        // single-pass compiler) has no cheap way to know whether an Assign
        // came from a bare statement or a nested expression.
        if (!this.isVisible(assign.name.lexeme)) {
            this.declare(assign.name);
            this.define(assign.name);
        } else if (this.isConst(assign.name.lexeme)) {
            this.errorReporter.error(assign.name, `Cannot assign to constant '${assign.name.lexeme}'.`);
        }
        this.resolveLocal(assign, assign.name);
    }

    visitBinary(binary: Binary) {
        binary.left.visit(this);
        binary.right.visit(this);
    }

    visitGrouping(grouping: Grouping) {
        grouping.expression.visit(this);
    }

    visitLiteral(literal: Literal) {}

    visitLogical(logical: Logical) {
        logical.left.visit(this);
        logical.right.visit(this);
    }

    visitVariable(variable: Variable) {
        if (this.scopes.length !== 0) {
            const scope = this.scopes[this.scopes.length - 1];
            if (scope.has(variable.name.lexeme) && !scope.get(variable.name.lexeme)) {
                this.errorReporter.error(variable.name, "Cannot read local variable in its own initializer.");
            }
        }

        this.resolveLocal(variable, variable.name);
    }

    visitUnary(unary: Unary) {
        unary.right.visit(this);
    }

    visitGet(get: Get): void {
        get.object.visit(this);

        if (get.object instanceof Variable) {
            const moduleName = this.resolveModuleNamespace(get.object.name.lexeme);
            const declToken = moduleName ? this.resolveImport?.(moduleName)?.get(get.name.lexeme) : undefined;
            if (moduleName && declToken) {
                this.moduleReferences.set(get.name, { moduleName, token: declToken });
            }
        }
    }

    visitSet(set: Set): void {
        set.value.visit(this);
        set.object.visit(this);
    }

    visitCall(call: Call) {
        call.callee.visit(this);
        call.args.forEach((arg) => arg.visit(this));
    }

    visitExpression(expression: Expression) {
        expression.expression.visit(this);
    }

    visitSuperExpr(superexpr: SuperExpr): void {
        if (this.currentClass === "none") {
            this.errorReporter.error(superexpr.keyword, "Cannot use 'super' outside of a class.");
        } else if (this.currentClass !== "subclass") {
            this.errorReporter.error(superexpr.keyword, "Cannot use 'super' in a class with no superclass.");
        }

        this.resolveLocal(superexpr, superexpr.keyword);
    }

    visitClassStmt(classstmt: ClassStmt): void {
        const enclosingClass = this.currentClass;
        this.currentClass = "class";

        this.declare(classstmt.name);
        this.define(classstmt.name);
        if (classstmt.superclass !== null) {
            this.currentClass = "subclass";
            if (classstmt.name.lexeme === classstmt.superclass.name.lexeme) {
                this.errorReporter.error(classstmt.superclass.name, "A class cannot inherit from itself.");
            }
            classstmt.superclass.visit(this);
        }

        if (classstmt.superclass !== null) {
            this.beginScope();
            this.scopes[this.scopes.length - 1].set("super", { token: classstmt.superclass.name, isConst: false });
        }

        this.beginScope();
        this.scopes[this.scopes.length - 1].set("this", { token: classstmt.name, isConst: false });

        classstmt.methods.forEach((method) => {
            this.definitionType.set(method.name, "property");
            let declaration: FunctionType = "method";
            if (method.name.lexeme === "init") {
                declaration = "initializer";
            }
            this.resolveFunctionBody(method.params, method.body, declaration);
        });

        classstmt.classVars.forEach((classVar) => {
            this.definitionType.set(classVar.name, "property");
            classVar.initializer.visit(this);
        });

        this.endScope();

        if (classstmt.superclass !== null) {
            this.endScope();
        }

        this.definitionType.set(classstmt.name, "class");
        this.currentClass = enclosingClass;
    }

    visitThisExpr(thisexpr: ThisExpr): void {
        if (this.currentClass === "none") {
            this.errorReporter.error(thisexpr.keyword, "Cannot use 'this' outside of a class.");
            return;
        }
        this.resolveLocal(thisexpr, thisexpr.keyword);
    }

    visitFunctionStmt(functionstmt: FunctionStmt) {
        this.declare(functionstmt.name);
        this.define(functionstmt.name);
        this.definitionType.set(functionstmt.name, "function");

        this.resolveFunctionBody(functionstmt.params, functionstmt.body, "function");
    }

    visitLambda(lambda: Lambda) {
        this.resolveFunctionBody(lambda.params, lambda.body, "function");
    }

    visitBreakStmt(breakstmt: BreakStmt) {
        if (this.loopDepth === 0) {
            this.errorReporter.error(breakstmt.keyword, "Cannot break from top-level code.");
        }
    }

    visitContinueStmt(continuestmt: ContinueStmt) {
        if (this.loopDepth === 0) {
            this.errorReporter.error(continuestmt.keyword, "Cannot continue from top-level code.");
        }
    }

    visitIfStmt(ifstmt: IfStmt) {
        ifstmt.condition.visit(this);
        ifstmt.thenBranch.visit(this);
        ifstmt.elseBranch?.visit(this);
    }

    visitBlock(block: Block) {
        this.beginScope();
        block.statements.forEach((statement) => statement.visit(this));
        this.endScope();
    }
    visitPrintStmt(printstmt: PrintStmt) {
        printstmt.expression.visit(this);
    }

    visitReturnStmt(returnstmt: ReturnStmt) {
        if (this.currentFunction === "none") {
            this.errorReporter.error(returnstmt.keyword, "Cannot return from top-level code.");
        }
        if (returnstmt.value !== null && this.currentFunction === "initializer") {
            this.errorReporter.error(returnstmt.keyword, "Cannot return a value from an initializer.");
        }
        returnstmt.value?.visit(this);
    }

    visitWhileStmt(whilestmt: WhileStmt) {
        whilestmt.condition.visit(this);
        this.loopDepth++;
        whilestmt.body.visit(this);
        this.loopDepth--;
    }

    visitForStmt(forstmt: ForStmt) {
        this.beginScope();
        forstmt.initializer?.visit(this);
        forstmt.condition?.visit(this);
        forstmt.increment?.visit(this);
        this.loopDepth++;
        forstmt.body.visit(this);
        this.loopDepth--;
        this.endScope();
    }

    visitVariableDeclaration(variabledeclaration: VariableDeclaration) {
        this.declare(variabledeclaration.name);
        if (variabledeclaration.initializer !== null) {
            variabledeclaration.initializer.visit(this);
        }
        this.define(variabledeclaration.name, variabledeclaration.isConst);
    }

    visitTernary(ternary: Ternary) {
        ternary.condition.visit(this);
        ternary.thenBranch.visit(this);
        ternary.elseBranch.visit(this);
    }

    visitListLiteral(listliteral: ListLiteral) {
        listliteral.elements.forEach((element) => element.visit(this));
    }

    visitDictLiteral(dictliteral: DictLiteral) {
        dictliteral.keys.forEach((key) => key.visit(this));
        dictliteral.values.forEach((value) => value.visit(this));
    }

    visitTupleLiteral(tupleliteral: TupleLiteral) {
        tupleliteral.elements.forEach((element) => element.visit(this));
    }

    visitIndexExpr(indexexpr: IndexExpr) {
        indexexpr.object.visit(this);
        indexexpr.index.visit(this);
    }

    visitIndexSet(indexset: IndexSet) {
        indexset.object.visit(this);
        indexset.index.visit(this);
        indexset.value.visit(this);
    }

    visitSliceExpr(sliceexpr: SliceExpr) {
        sliceexpr.object.visit(this);
        sliceexpr.from?.visit(this);
        sliceexpr.to?.visit(this);
    }

    visitSliceSet(sliceset: SliceSet) {
        sliceset.object.visit(this);
        sliceset.from?.visit(this);
        sliceset.to?.visit(this);
        sliceset.value.visit(this);
    }

    visitStrExpr(strexpr: StrExpr) {
        strexpr.expression.visit(this);
    }

    visitForeachStmt(foreachstmt: ForeachStmt) {
        foreachstmt.iterable.visit(this);
        this.beginScope();
        this.declare(foreachstmt.name);
        this.define(foreachstmt.name);
        this.definitionType.set(foreachstmt.name, "parameter");
        this.loopDepth++;
        foreachstmt.body.visit(this);
        this.loopDepth--;
        this.endScope();
    }

    visitTryStmt(trystmt: TryStmt) {
        trystmt.block.visit(this);
        trystmt.clauses.forEach((clause) => {
            this.beginScope();
            this.declare(clause.name);
            this.define(clause.name);
            clause.block.visit(this);
            this.endScope();
        });
        trystmt.finallyBlock?.visit(this);
    }

    visitRaiseStmt(raisestmt: RaiseStmt) {
        raisestmt.expression.visit(this);
    }

    visitImportStmt(importstmt: ImportStmt) {
        importstmt.names.forEach((imp) => {
            const bound = imp.alias ?? imp.name;
            this.declare(bound);
            this.define(bound, false, undefined, imp.name.lexeme);
        });
    }

    visitImportFromStmt(importfromstmt: ImportFromStmt) {
        const moduleName = importfromstmt.module.lexeme;
        const moduleExports = this.resolveImport?.(moduleName);

        if (importfromstmt.isStar) {
            if (!moduleExports) {
                // module couldn't be resolved -- nothing statically known to declare
                return;
            }
            const scope = this.scopes[this.scopes.length - 1];
            moduleExports.forEach((declToken, exportedName) => {
                // Not routed through declare()/define(): there's no local
                // name token for a `*`-imported binding, and (deliberately,
                // to keep re-export chains out of scope, see ARCHITECTURE.md
                // §6) these aren't added to this.exports, so a further
                // `from thisFile import x` won't transitively resolve to the
                // original module.
                scope.set(exportedName, {
                    token: declToken,
                    isConst: false,
                    crossModule: { moduleName, token: declToken },
                });
            });
            return;
        }

        importfromstmt.names.forEach((name) => {
            const declToken = moduleExports?.get(name.lexeme);
            this.declare(name);
            this.define(name, false, declToken ? { moduleName, token: declToken } : undefined);
        });
    }

    visitBreakpointStmt(breakpointstmt: BreakpointStmt) {}

    visitUnpackStmt(unpackstmt: UnpackStmt) {
        unpackstmt.value.visit(this);
        unpackstmt.names.forEach((name) => {
            if (!this.isVisible(name.lexeme)) {
                this.declare(name);
                this.define(name);
            } else if (this.isConst(name.lexeme)) {
                this.errorReporter.error(name, `Cannot assign to constant '${name.lexeme}'.`);
            }
            this.resolveLocal(unpackstmt, name);
        });
    }

    private beginScope() {
        this.scopes.push(new Map<string, ScopeEntry>());
    }

    private endScope() {
        this.scopes.pop();
    }

    private declare(name: Token) {
        if (this.scopes.length === 0) {
            return;
        }
        if (this.scopes.length === 1) {
            // Global scope: redeclaration is always allowed (matches glox's
            // own declareVariable(), which only checks locals -- e.g.
            // re-importing an already-imported module, or a script that
            // declares the same global twice, are both legal glox).
            return;
        }

        const scope = this.scopes[this.scopes.length - 1];
        if (scope.has(name.lexeme)) {
            this.errorReporter.error(name, "Variable with this name already declared in this scope.");
        }

        scope.set(name.lexeme, false);
    }

    private define(
        name: Token,
        isConst: boolean = false,
        crossModule?: { moduleName: string; token: Token },
        moduleNamespace?: string
    ) {
        this.scopes[this.scopes.length - 1].set(name.lexeme, { token: name, isConst, crossModule, moduleNamespace });
        this.definitions.set(name, []);
        this.isGlobalDefinition.set(name, this.scopes.length === 1);
        if (this.scopes.length === 1) {
            this.exports.set(name.lexeme, name);
        }
    }

    // Same scope-walking order as resolveLocal/isVisible/isConst -- returns
    // the module name a plain `import <module> [as alias]` binding refers
    // to, or undefined if `lexeme` isn't one (a normal variable, a named
    // import, or not declared at all).
    private resolveModuleNamespace(lexeme: string): string | undefined {
        for (let i = 0; i < this.scopes.length; i++) {
            const entry = this.scopes[i].get(lexeme);
            if (entry !== undefined) {
                return entry !== false ? entry.moduleNamespace : undefined;
            }
        }
        return undefined;
    }

    // Whether `lexeme` is declared in any currently-visible scope -- used to
    // decide whether a bare assignment should implicitly declare it.
    private isVisible(lexeme: string): boolean {
        for (let i = 0; i < this.scopes.length; i++) {
            if (this.scopes[i].has(lexeme)) {
                return true;
            }
        }
        return false;
    }

    private isConst(lexeme: string): boolean {
        for (let i = 0; i < this.scopes.length; i++) {
            const entry = this.scopes[i].get(lexeme);
            if (entry !== undefined) {
                return entry !== false && entry.isConst;
            }
        }
        return false;
    }

    private resolveFunctionBody(params: Array<Param>, body: Array<Stmt>, functionType: FunctionType) {
        const enclosingFunction = this.currentFunction;
        this.currentFunction = functionType;

        this.beginScope();
        params.forEach((param) => {
            this.declare(param.name);
            this.define(param.name);
            this.definitionType.set(param.name, "parameter");
            param.defaultValue?.visit(this);
        });
        body.forEach((statement) => statement.visit(this));
        this.endScope();

        this.currentFunction = enclosingFunction;
    }

    private resolveLocal(expr: Expr, name: Token) {
        for (let i = 0; i < this.scopes.length; i++) {
            const entry = this.scopes[i].get(name.lexeme);
            if (entry !== undefined) {
                this.resolved.set(expr, this.scopes.length - 1 - i);

                if (entry !== false) {
                    if (entry.crossModule) {
                        this.moduleReferences.set(name, entry.crossModule);
                    } else {
                        this.definitions.get(entry.token)?.push(name);
                        this.references.set(name, entry.token);
                    }
                }
                return;
            }
        }
    }
}
