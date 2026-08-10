import { ErrorReporter, defaultErrorReporter } from "./Error";
import {
    Assign,
    Binary,
    Block,
    BreakStmt,
    BreakpointStmt,
    Call,
    ClassStmt,
    ClassVarStmt,
    ContinueStmt,
    DictLiteral,
    ExceptClause,
    Expr,
    ForStmt,
    ForeachStmt,
    FunctionStmt,
    Get,
    Set,
    Grouping,
    IfStmt,
    ImportFromStmt,
    ImportName,
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
    WhileStmt,
    ThisExpr,
    SuperExpr,
} from "./Expr";
import { Token, TokenType } from "./Token";

export class ParseError extends Error {
    constructor(token: Token | undefined, message: string) {
        super(`[line ${token?.line || 0}] Error: ${message}`);
    }
}

// Statement-starting keywords synchronize() rallies to after a parse error.
// (A plain array, not a Set -- "Set" here would shadow the AST node class of
// the same name imported below.)
const STATEMENT_SYNC: ReadonlyArray<TokenType> = [
    "CLASS",
    "FUN",
    "VAR",
    "CONST",
    "FOR",
    "FOREACH",
    "IF",
    "WHILE",
    "PRINT",
    "RETURN",
    "TRY",
    "IMPORT",
    "FROM",
    "RAISE",
    "BREAKPOINT",
];

const COMPOUND_ASSIGN_OP: Partial<Record<TokenType, TokenType>> = {
    PLUS_EQUAL: "PLUS",
    MINUS_EQUAL: "MINUS",
    STAR_EQUAL: "STAR",
    SLASH_EQUAL: "SLASH",
    PERCENT_EQUAL: "PERCENT",
};

export class Parser {
    private current: Token | undefined = undefined;
    private previous: Token | undefined = undefined;
    private isAtEnd: boolean = false;
    // Tokens already pulled from the generator but not yet consumed as
    // `current` -- lets statement() look one token past `current` (needed to
    // detect the start of an `a, b = expr` unpacking assignment) without
    // requiring the generator to support rewinding.
    private lookaheadBuffer: Token[] = [];

    constructor(
        private readonly tokens: Generator<Token>,
        private readonly errorReporter: ErrorReporter = defaultErrorReporter
    ) {}

    parse(): Array<Stmt> | null {
        this.advance();
        if (this.isAtEnd) {
            return [];
        }

        const statements: Array<Stmt> = [];
        this.skipTerminators();
        while (!this.isAtEnd) {
            const declaration = this.declaration();
            if (declaration) {
                statements.push(declaration);
            }
            this.skipTerminators();
        }
        return statements;
    }

    parseExpression(): Expr | null {
        try {
            this.advance();
            const expr = this.expression();
            if (this.isAtEnd) {
                return expr;
            }

            return null;
        } catch (e) {
            if (e instanceof ParseError) {
                return null;
            } else {
                throw e;
            }
        }
    }

    private declaration(): Stmt | null {
        try {
            if (this.match("FUN")) {
                return this.functionDeclaration("function", false);
            } else if (this.match("CLASS")) {
                return this.classDeclaration();
            } else if (this.match("VAR")) {
                return this.varDeclaration(false);
            } else if (this.match("CONST")) {
                return this.varDeclaration(true);
            } else {
                return this.statement();
            }
        } catch (e) {
            if (e instanceof ParseError) {
                this.synchronize();
                return null;
            } else {
                throw e;
            }
        }
    }

    private classDeclaration(): Stmt {
        const name = this.consume("IDENTIFIER", "Expect class name.");

        let superclass: Variable | null = null;
        if (this.match("LESS")) {
            this.consume("IDENTIFIER", "Expect superclass name.");
            superclass = new Variable(this.previous!);
        }

        this.match("EOL"); // allow EOL before class body
        this.consume("LEFT_BRACE", "Expect '{' before class body.");
        this.skipTerminators();

        const methods: Array<FunctionStmt> = [];
        const classVars: Array<ClassVarStmt> = [];
        while (!this.check("RIGHT_BRACE") && !this.isAtEnd) {
            const isStatic = this.match("STATIC");
            // `static name = expr` / `static name;` (no parens) is a class
            // variable; `static name(...)` (parens follow) is a static
            // method. Only static members can be class variables.
            if (isStatic && this.check("IDENTIFIER") && this.peekAhead(1).type !== "LEFT_PAREN") {
                classVars.push(this.classVarDeclaration());
            } else {
                methods.push(this.functionDeclaration("method", isStatic));
            }
            this.skipTerminators();
        }

        this.consume("RIGHT_BRACE", "Expect '}' after class body.");
        this.match("EOL"); // allow EOL after class body

        return new ClassStmt(name, superclass, methods, classVars);
    }

    private classVarDeclaration(): ClassVarStmt {
        const name = this.consume("IDENTIFIER", "Expect class variable name.");

        let initializer: Expr = new Literal(null);
        if (this.match("EQUAL")) {
            initializer = this.expression();
        }

        this.consumeTerminator("Expect terminator after class variable declaration.");
        return { name, initializer };
    }

    private functionDeclaration(kind: "function" | "method", isStatic: boolean): FunctionStmt {
        const name = this.consume("IDENTIFIER", `Expect ${kind} name.`);

        this.consume("LEFT_PAREN", `Expect '(' after ${kind} name.`);
        const parameters = this.parameterList();
        this.match("EOL"); // allow EOL after parameters

        this.consume("LEFT_BRACE", `Expect '{' before ${kind} body.`);
        const body = this.block();
        return new FunctionStmt(name, parameters, body, isStatic);
    }

    // Assumes the opening '(' has already been consumed; consumes through and
    // including the closing ')'. Shared by function/method declarations and
    // lambda expressions. Supports one default value per parameter (once seen,
    // every later parameter must also have one) and a single trailing `*rest`
    // variadic parameter.
    private parameterList(): Array<Param> {
        const parameters: Array<Param> = [];
        let seenDefault = false;
        if (!this.check("RIGHT_PAREN")) {
            do {
                if (parameters.length >= 255) {
                    this.error(this.current, "Cannot have more than 255 parameters.");
                    break;
                }
                if (this.match("STAR")) {
                    const name = this.consume("IDENTIFIER", "Expect parameter name after '*'.");
                    parameters.push({ name, defaultValue: null, isVariadic: true });
                    if (this.check("COMMA")) {
                        this.error(this.current, "'*rest' must be the last parameter.");
                    }
                    break;
                }
                const name = this.consume("IDENTIFIER", "Expect parameter name.");
                let defaultValue: Expr | null = null;
                if (this.match("EQUAL")) {
                    defaultValue = this.expression();
                    seenDefault = true;
                } else if (seenDefault) {
                    this.error(name, "Non-default parameter cannot follow a default parameter.");
                }
                parameters.push({ name, defaultValue, isVariadic: false });
            } while (this.match("COMMA"));
        }
        this.match("EOL"); // allow EOL after parameters
        this.consume("RIGHT_PAREN", "Expect ')' after parameters.");
        return parameters;
    }

    private varDeclaration(isConst: boolean): Stmt {
        const name = this.consume("IDENTIFIER", "Expect variable name.");

        let initializer: Expr | null = null;
        if (this.match("EQUAL")) {
            initializer = this.expression();
        } else if (isConst) {
            this.error(name, "Constants must be initialised.");
        }

        this.consumeTerminator("Expect terminator after variable declaration.");
        return new VariableDeclaration(name, initializer || new Literal(null), isConst);
    }

    private statement(): Stmt {
        // `a, b, c = expr` -- only ever valid as this unpacking form (glox has
        // no comma expression), so seeing IDENTIFIER "," here is unambiguous.
        if (this.check("IDENTIFIER") && this.peekAhead(1).type === "COMMA") {
            return this.unpackStatement();
        }

        if (this.match("PRINT")) {
            return this.printStatement();
        } else if (this.match("LEFT_BRACE")) {
            return new Block(this.block());
        } else if (this.match("IF")) {
            return this.ifStatement();
        } else if (this.match("WHILE")) {
            return this.whileStatement();
        } else if (this.match("FOR")) {
            return this.forStatement();
        } else if (this.match("FOREACH")) {
            return this.foreachStatement();
        } else if (this.match("TRY")) {
            return this.tryStatement();
        } else if (this.match("RAISE")) {
            return this.raiseStatement();
        } else if (this.match("IMPORT")) {
            return this.importStatement();
        } else if (this.match("FROM")) {
            return this.importFromStatement();
        } else if (this.match("BREAKPOINT")) {
            return this.breakpointStatement();
        } else if (this.match("BREAK")) {
            const token = this.previous!;
            this.consumeTerminator("Expect terminator after 'break'.");
            return new BreakStmt(token);
        } else if (this.match("CONTINUE")) {
            const token = this.previous!;
            this.consumeTerminator("Expect terminator after 'continue'.");
            return new ContinueStmt(token);
        } else if (this.match("RETURN")) {
            return this.returnStatement();
        }

        return this.expressionStatement();
    }

    private unpackStatement(): Stmt {
        const names: Array<Token> = [this.consume("IDENTIFIER", "Expect identifier.")];
        while (this.match("COMMA")) {
            names.push(this.consume("IDENTIFIER", "Expect identifier."));
        }
        this.consume("EQUAL", "Expect '=' after unpacking target list.");
        const value = this.expression();
        this.consumeTerminator("Expect terminator after unpacking assignment.");
        return new UnpackStmt(names, value);
    }

    // The parens around `[var] name in iterable` are optional, same
    // allowance as if/while/for above: `foreach x in list { ... }` and
    // `foreach (x in list) { ... }` both parse.
    private foreachStatement(): Stmt {
        const keyword = this.previous!;
        const hasParen = this.match("LEFT_PAREN");
        this.match("VAR"); // optional, and not otherwise meaningful here
        const name = this.consume("IDENTIFIER", "Expect loop variable name.");
        this.consume("IN", "Expect 'in' after foreach variable.");
        const iterable = this.expression();
        if (hasParen) {
            this.consume("RIGHT_PAREN", "Expect ')' after foreach clause.");
        }
        const body = this.statement();
        return new ForeachStmt(keyword, name, iterable, body);
    }

    // try { ... } [except Type as name { ... }]* [finally { ... }]
    // At least one `except` or `finally` is required (matching odlox's own
    // compiler/stmt.odin's try_except_statement) -- a bare `try { }` with
    // neither is rejected below with the same message odlox's own compiler
    // uses for that case.
    private tryStatement(): Stmt {
        this.match("EOL");
        this.consume("LEFT_BRACE", "Expect '{' after 'try'.");
        const block = new Block(this.block());

        const clauses: Array<ExceptClause> = [];
        while (this.match("EXCEPT")) {
            const exceptionType = this.consume("IDENTIFIER", "Expect exception type.");
            this.consume("AS", "Expect 'as'.");
            const name = this.consume("IDENTIFIER", "Expect exception variable name.");
            this.match("EOL");
            this.consume("LEFT_BRACE", "Expect '{' before except body.");
            const exceptBlock = new Block(this.block());
            clauses.push({ exceptionType, name, block: exceptBlock });
        }

        if (clauses.length === 0 && !this.check("FINALLY")) {
            this.error(this.current, "Expect 'except' or 'finally' after try block.");
        }

        let finallyBlock: Stmt | null = null;
        if (this.match("FINALLY")) {
            this.match("EOL");
            this.consume("LEFT_BRACE", "Expect '{' after 'finally'.");
            finallyBlock = new Block(this.block());
        }

        return new TryStmt(block, clauses, finallyBlock);
    }

    private raiseStatement(): Stmt {
        const keyword = this.previous!;
        const expr = this.expression();
        this.consumeTerminator("Expect terminator after 'raise' expression.");
        return new RaiseStmt(keyword, expr);
    }

    // import name [as alias] [, name [as alias]]*
    private importStatement(): Stmt {
        const names: Array<ImportName> = [];
        do {
            const name = this.consume("IDENTIFIER", "Expect module name.");
            let alias: Token | null = null;
            if (this.match("AS")) {
                alias = this.consume("IDENTIFIER", "Expect alias name.");
            }
            names.push({ name, alias });
        } while (this.match("COMMA"));
        this.consumeTerminator("Expect terminator after import statement.");
        return new ImportStmt(names);
    }

    // from name import a, b, c   |   from name import *
    private importFromStatement(): Stmt {
        const module = this.consume("IDENTIFIER", "Expect module name.");
        this.consume("IMPORT", "Expect 'import' after module name.");

        if (this.match("STAR")) {
            this.consumeTerminator("Expect terminator after import statement.");
            return new ImportFromStmt(module, [], true);
        }

        const names: Array<Token> = [this.consume("IDENTIFIER", "Expect imported name.")];
        while (this.match("COMMA")) {
            names.push(this.consume("IDENTIFIER", "Expect imported name."));
        }
        this.consumeTerminator("Expect terminator after import statement.");
        return new ImportFromStmt(module, names, false);
    }

    private breakpointStatement(): Stmt {
        const keyword = this.previous!;
        this.consumeTerminator("Expect terminator after 'breakpoint'.");
        return new BreakpointStmt(keyword);
    }

    private returnStatement(): Stmt {
        const keyword = this.previous;
        let value: Expr | null = null;
        if (!this.check("SEMICOLON") && !this.check("RIGHT_BRACE") && !this.isAtEnd) {
            value = this.expression();
        }

        this.consumeTerminator("Expect terminator after return value.");
        return new ReturnStmt(keyword!, value);
    }

    // The condition's wrapping parens are optional: `if cond { ... }` and
    // `if (cond) { ... }` both parse. When a leading '(' is present, the
    // matching ')' is required so a parenthesized sub-expression that's
    // only *part* of a larger condition (`if (a + b) > 0 ...`) isn't
    // misread as the whole condition. This is more lenient than real
    // glox's own parser (which requires the parens unconditionally) --
    // a deliberate jslox-side allowance, not a port of anything.
    private ifStatement(): Stmt {
        const hasParen = this.match("LEFT_PAREN");
        const condition = this.expression();
        if (hasParen) {
            this.consume("RIGHT_PAREN", "Expect ')' after if condition.");
        }

        const thenBranch = this.statement();
        let elseBranch: Stmt | undefined;

        if (this.match("ELSE")) {
            elseBranch = this.statement();
        }

        return new IfStmt(condition, thenBranch, elseBranch || null);
    }

    // The condition's wrapping parens are optional, same allowance as
    // ifStatement above: `while cond { ... }` and `while (cond) { ... }`
    // both parse.
    private whileStatement(): Stmt {
        const hasParen = this.match("LEFT_PAREN");
        const condition = this.expression();
        if (hasParen) {
            this.consume("RIGHT_PAREN", "Expect ')' after while condition.");
        }

        const body = this.statement();

        return new WhileStmt(condition, body);
    }

    // The parens wrapping the three for-clauses are optional (same
    // allowance as if/while above): `for i = 0; i < 10; i = i + 1 { ... }`
    // and `for (i = 0; i < 10; i = i + 1) { ... }` both parse. When parens
    // are omitted, the (also-omittable) increment clause's end is detected
    // by checking for the body's opening '{' instead of ')' -- mirrors
    // odlox's own compiler/stmt.odin for_statement's has_paren/has_increment
    // handling exactly.
    private forStatement(): Stmt {
        const hasParen = this.match("LEFT_PAREN");
        let initializer: Stmt | null = null;
        if (this.match("SEMICOLON")) {
            initializer = null;
        } else if (this.match("VAR")) {
            initializer = this.varDeclaration(false);
        } else {
            initializer = this.expressionStatement();
        }

        let condition: Expr | null = null;
        if (!this.check("SEMICOLON")) {
            condition = this.expression();
        }
        this.consume("SEMICOLON", "Expect ';' after loop condition.");

        let increment: Expr | null = null;
        const hasIncrement = hasParen ? !this.check("RIGHT_PAREN") : !this.check("LEFT_BRACE");
        if (hasIncrement) {
            increment = this.expression();
        }
        if (hasParen) {
            this.consume("RIGHT_PAREN", "Expect ')' after for clauses.");
        }
        this.match("EOL"); // allow EOL before the loop body (C-style for only)

        let body = this.statement();

        return new ForStmt(initializer, condition, increment, body);
    }

    // Parses declarations up to and including the closing '}', but does NOT
    // consume any EOL right after it. Used for lambda bodies: consuming that
    // EOL would swallow the terminator of the *enclosing* statement (e.g.
    // `var f = func(){...}`, where the EOL after '}' ends the `var` statement).
    private blockBody(): Array<Stmt> {
        const statements: Array<Stmt> = [];
        this.skipTerminators();

        while (!this.check("RIGHT_BRACE") && !this.isAtEnd) {
            const declaration = this.declaration();
            if (declaration) {
                statements.push(declaration);
            }
            this.skipTerminators();
        }

        this.consume("RIGHT_BRACE", "Expect '}' after block.");
        return statements;
    }

    // Statement-position block: a bare `{...}` or a named function/method
    // body. Unlike blockBody(), also swallows one trailing EOL after '}' --
    // needed for e.g. `if (x) {\n...\n}\nelse {\n...\n}` to see the `else`.
    private block(): Array<Stmt> {
        const statements = this.blockBody();
        this.match("EOL");
        return statements;
    }

    private printStatement(): Stmt {
        const value = this.expression();
        this.consumeTerminator("Expect terminator after value.");
        return new PrintStmt(value);
    }

    private expressionStatement(): Stmt {
        const expr = this.expression();
        this.consumeTerminator("Expect terminator after expression.");
        return expr;
    }

    private expression(): Expr {
        return this.assignment();
    }

    private assignment(): Expr {
        const expr = this.conditional();

        if (this.match("EQUAL")) {
            const equals = this.previous;
            const value = this.assignment();

            if (expr instanceof Variable) {
                return new Assign(expr.name, value);
            } else if (expr instanceof Get) {
                return new Set(expr.object, expr.name, value);
            } else if (expr instanceof IndexExpr) {
                return new IndexSet(expr.object, expr.bracket, expr.index, value);
            } else if (expr instanceof SliceExpr) {
                return new SliceSet(expr.object, expr.bracket, expr.from, expr.to, value);
            }

            this.error(equals, "Invalid assignment target.");
            return expr;
        }

        if (this.matchCompoundAssign()) {
            const opToken = this.previous!;
            const binOp = this.compoundBinaryOperator(opToken);
            const value = this.assignment();

            // glox only supports compound assignment on plain names and
            // '.property' -- never on index/slice targets.
            if (expr instanceof Variable) {
                return new Assign(expr.name, new Binary(expr, binOp, value));
            } else if (expr instanceof Get) {
                return new Set(expr.object, expr.name, new Binary(expr, binOp, value));
            }

            this.error(opToken, "Invalid assignment target.");
            return expr;
        }

        return expr;
    }

    private matchCompoundAssign(): boolean {
        return this.match("PLUS_EQUAL", "MINUS_EQUAL", "STAR_EQUAL", "SLASH_EQUAL", "PERCENT_EQUAL");
    }

    private compoundBinaryOperator(opToken: Token): Token {
        const type = COMPOUND_ASSIGN_OP[opToken.type]!;
        return new Token(type, opToken.lexeme, undefined, opToken.line, opToken.character, opToken.start, opToken.end);
    }

    // '?:' -- binds looser than 'or'/'and' but tighter than '=' (glox's own
    // precedence table puts PREC_CONDITIONAL directly above PREC_ASSIGNMENT).
    private conditional(): Expr {
        const expr = this.or();

        if (this.match("QUESTION")) {
            const thenBranch = this.conditional();
            this.consume("COLON", "Expect ':' after '?' branch of conditional expression.");
            const elseBranch = this.conditional();
            return new Ternary(expr, thenBranch, elseBranch);
        }

        return expr;
    }

    private or(): Expr {
        let expr = this.and();

        while (this.match("OR")) {
            const operator = this.previous;
            const right = this.and();
            expr = new Logical(expr, operator!, right);
        }

        return expr;
    }

    private and(): Expr {
        let expr = this.equality();

        while (this.match("AND")) {
            const operator = this.previous;
            const right = this.equality();
            expr = new Logical(expr, operator!, right);
        }

        return expr;
    }

    private equality(): Expr {
        let expr = this.comparison();

        while (this.match("BANG_EQUAL", "EQUAL_EQUAL", "IN")) {
            const operator = this.previous;
            const right = this.comparison();
            expr = new Binary(expr, operator!, right);
        }

        return expr;
    }

    private comparison(): Expr {
        let expr = this.term();

        while (this.match("GREATER", "GREATER_EQUAL", "LESS", "LESS_EQUAL")) {
            const operator = this.previous;
            const right = this.term();
            expr = new Binary(expr, operator!, right);
        }

        return expr;
    }

    // '+', '-', and glox's non-standard '++' (vector/list add) and '&'
    // (string concat) all share this precedence level.
    private term(): Expr {
        let expr = this.factor();

        while (this.match("MINUS", "PLUS", "PLUS_PLUS", "AMPERSAND")) {
            const operator = this.previous;
            const right = this.factor();
            expr = new Binary(expr, operator!, right);
        }

        return expr;
    }

    private factor(): Expr {
        let expr = this.unary();

        while (this.match("SLASH", "STAR", "PERCENT")) {
            const operator = this.previous;
            const right = this.unary();
            expr = new Binary(expr, operator!, right);
        }

        return expr;
    }

    private unary(): Expr {
        if (this.match("BANG", "MINUS")) {
            const operator = this.previous;
            const right = this.unary();
            return new Unary(operator!, right);
        }

        return this.call();
    }

    private call(): Expr {
        let expr = this.primary();

        while (true) {
            if (this.match("LEFT_PAREN")) {
                expr = this.finishCall(expr);
            } else if (this.match("DOT")) {
                const name = this.consume("IDENTIFIER", "Expect property name after '.'.");
                expr = new Get(expr, name!);
            } else if (this.match("LEFT_BRACKET")) {
                expr = this.finishIndexOrSlice(expr);
            } else {
                break;
            }
        }

        return expr;
    }

    // Dispatches on whether a ':' shows up before the closing ']', at either
    // the very start (`x[:b]`) or after the first bound (`x[a:b]`), to decide
    // between a plain index and a slice. No step syntax (`x[a:b:c]`) exists in
    // glox, so this never looks for a second ':'.
    private finishIndexOrSlice(object: Expr): Expr {
        const bracket = this.previous!;

        if (this.match("COLON")) {
            let to: Expr | null = null;
            if (!this.check("RIGHT_BRACKET")) {
                to = this.expression();
            }
            this.consume("RIGHT_BRACKET", "Expect ']' after slice.");
            return new SliceExpr(object, bracket, null, to);
        }

        const first = this.expression();

        if (this.match("COLON")) {
            let to: Expr | null = null;
            if (!this.check("RIGHT_BRACKET")) {
                to = this.expression();
            }
            this.consume("RIGHT_BRACKET", "Expect ']' after slice.");
            return new SliceExpr(object, bracket, first, to);
        }

        this.consume("RIGHT_BRACKET", "Expect ']' after index.");
        return new IndexExpr(object, bracket, first);
    }

    private finishCall(callee: Expr): Expr {
        const args: Array<Expr> = [];
        if (!this.check("RIGHT_PAREN")) {
            do {
                if (args.length >= 255) {
                    this.error(this.current, "Cannot have more than 255 arguments.");
                    break;
                }
                args.push(this.expression());
            } while (this.match("COMMA"));
        }
        this.match("EOL"); // allow EOL after arguments

        const paren = this.consume("RIGHT_PAREN", "Expect ')' after arguments.");

        return new Call(callee, paren, args);
    }

    private primary(): Expr {
        if (this.match("FALSE")) {
            return new Literal(false);
        }

        if (this.match("TRUE")) {
            return new Literal(true);
        }

        if (this.match("NIL")) {
            return new Literal(null);
        }

        if (this.match("INT", "FLOAT", "STRING")) {
            return new Literal(this.previous!.literal!);
        }

        if (this.match("IDENTIFIER")) {
            return new Variable(this.previous!);
        }

        if (this.match("LEFT_BRACKET")) {
            return this.listLiteral();
        }

        if (this.match("LEFT_BRACE")) {
            return this.dictLiteral();
        }

        if (this.match("STR")) {
            return this.strExpr();
        }

        if (this.match("FUN")) {
            return this.lambda();
        }

        if (this.match("LEFT_PAREN")) {
            return this.groupingOrTuple();
        }

        if (this.match("THIS")) {
            return new ThisExpr(this.previous!);
        }

        if (this.match("SUPER")) {
            const keyword = this.previous;
            this.consume("DOT", "Expect '.' after 'super'.");

            const method = this.consume("IDENTIFIER", "Expect superclass method name.");
            return new SuperExpr(keyword!, method!);
        }

        throw this.error(this.current!, "Expect expression.");
    }

    // [ e, e, ... ]  -- assumes '[' already consumed.
    private listLiteral(): Expr {
        const bracket = this.previous!;
        const elements: Array<Expr> = [];
        if (!this.check("RIGHT_BRACKET")) {
            do {
                elements.push(this.expression());
            } while (this.match("COMMA"));
        }
        this.match("EOL"); // allow EOL after list elements
        this.consume("RIGHT_BRACKET", "Expect ']' after list elements.");
        return new ListLiteral(bracket, elements);
    }

    // { k: v, k: v, ... } -- assumes '{' already consumed. Only reachable in
    // expression position; a '{' at statement position is always a block (see
    // statement()), so no lookahead is needed to disambiguate.
    private dictLiteral(): Expr {
        const brace = this.previous!;
        const keys: Array<Expr> = [];
        const values: Array<Expr> = [];
        if (!this.check("RIGHT_BRACE")) {
            do {
                keys.push(this.expression());
                this.consume("COLON", "Expect ':' after dict key.");
                values.push(this.expression());
            } while (this.match("COMMA"));
        }
        this.match("EOL"); // allow EOL after dict entries
        this.consume("RIGHT_BRACE", "Expect '}' after dict entries.");
        return new DictLiteral(brace, keys, values);
    }

    // str(expr) -- a dedicated builtin-syntax keyword in glox (matched purely
    // by the STR token), not an ordinary call to an identifier named `str`.
    private strExpr(): Expr {
        const keyword = this.previous!;
        this.consume("LEFT_PAREN", "Expect '(' after 'str'.");
        const expr = this.expression();
        this.consume("RIGHT_PAREN", "Expect ')' after 'str' expression.");
        return new StrExpr(keyword, expr);
    }

    // func (params) { body } used as a value, e.g. `var f = func(x) { ... }`.
    private lambda(): Expr {
        const keyword = this.previous!;
        this.consume("LEFT_PAREN", "Expect '(' after 'func'.");
        const params = this.parameterList();
        this.match("EOL"); // allow EOL after parameters
        this.consume("LEFT_BRACE", "Expect '{' before lambda body.");
        const body = this.blockBody();
        return new Lambda(keyword, params, body);
    }

    // '(' expr ')' is a grouping; '(' expr (, expr)+ ')' is a tuple literal --
    // there's no trailing-comma singleton-tuple syntax, matching glox.
    private groupingOrTuple(): Expr {
        const paren = this.previous!;
        const first = this.expression();

        if (this.match("COMMA")) {
            const elements: Array<Expr> = [first];
            do {
                elements.push(this.expression());
            } while (this.match("COMMA"));
            this.consume("RIGHT_PAREN", "Expect ')' after tuple elements.");
            return new TupleLiteral(paren, elements);
        }

        this.consume("RIGHT_PAREN", "Expect ')' after expression.");
        return new Grouping(first);
    }

    private synchronize(): void {
        this.advance();

        while (!this.isAtEnd) {
            if (this.previous?.type === "SEMICOLON" || this.previous?.type === "EOL") {
                return;
            }

            if (this.current && STATEMENT_SYNC.includes(this.current.type)) {
                return;
            }

            this.advance();
        }
    }

    // Consumes a statement terminator: ';' or a real EOL (check() treats them
    // as equivalent) are consumed; a '}' or EOF is an *implicit* terminator
    // and is left in place for the caller (block()/script end) to consume --
    // this is what lets one-line braced blocks like `if (x) { print 1 }`
    // parse without a trailing ';'. Mirrors glox's consumeStatementEnd exactly.
    private consumeTerminator(message: string): void {
        if (this.match("SEMICOLON")) {
            return;
        }
        if (this.isAtEnd || this.check("RIGHT_BRACE")) {
            return;
        }
        throw this.error(this.current!, message);
    }

    // Consumes any run of ';'/EOL tokens -- used between declarations (blank
    // lines, or a mix of blank lines and explicit ';') so they don't need to
    // be parsed as (empty) statements themselves.
    private skipTerminators(): void {
        while (this.match("SEMICOLON")) {
            // consumed (also matches EOL, see check())
        }
    }

    private match(...types: TokenType[]): boolean {
        for (const type of types) {
            if (this.check(type)) {
                this.advance();
                return true;
            }
        }

        return false;
    }

    private advance(): Token {
        this.previous = this.current;
        if (this.lookaheadBuffer.length > 0) {
            this.current = this.lookaheadBuffer.shift();
        } else {
            const next = this.tokens.next();
            this.current = next.value;
        }

        if (this.current === undefined || this.current.type === "EOF") {
            this.isAtEnd = true;
        }

        return this.previous!;
    }

    // Token `n` positions past `current` (n=1 is the token right after
    // `current`), pulling from the underlying generator into
    // `lookaheadBuffer` as needed without disturbing `current`/`previous`.
    private peekAhead(n: number): Token {
        while (this.lookaheadBuffer.length < n) {
            const next = this.tokens.next();
            if (next.done) {
                const line = this.current?.line ?? 0;
                this.lookaheadBuffer.push(new Token("EOF", "", undefined, line, 0, 0, 0));
            } else {
                this.lookaheadBuffer.push(next.value);
            }
        }
        return this.lookaheadBuffer[n - 1];
    }

    // Mirrors glox's own check() exactly: checking for SEMICOLON also accepts a
    // real EOL, since both terminate a statement (optional semicolons).
    private check(type: TokenType): boolean {
        if (this.isAtEnd) {
            return false;
        }

        return this.current?.type === type || (type === "SEMICOLON" && this.current?.type === "EOL");
    }

    private consume(type: TokenType, message: string): Token {
        if (this.check(type)) {
            return this.advance();
        }

        throw this.error(this.current!, message);
    }

    private error(token: Token | undefined, message: string): ParseError {
        this.errorReporter.error(
            token || {
                line: 0,
                start: 0,
                end: 0,
            },
            message
        );
        return new ParseError(token, message);
    }
}
