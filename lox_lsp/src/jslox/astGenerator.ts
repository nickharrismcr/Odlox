/* eslint-disable @typescript-eslint/naming-convention */
const grammar: Record<string, Array<string>> = {
    "Assign Expr": ["Token name", "Expr value"],
    "Binary Expr": ["Expr left", "Token operator", "Expr right"],
    "Grouping Expr": ["Expr expression"],
    "Literal Expr": ["string|number|null|boolean value"],
    "Logical Expr": ["Expr left", "Token operator", "Expr right"],
    "Variable Expr": ["Token name"],
    "Unary Expr": ["Token operator", "Expr right"],
    "Call Expr": ["Expr callee", "Token paren", "Array<Expr> args"],
    "Get Expr": ["Expr object", "Token name"],
    "Set Expr": ["Expr object", "Token name", "Expr value"],
    "SuperExpr Expr": ["Token keyword", "Token method"],
    "ThisExpr Expr": ["Token keyword"],
    "StrExpr Expr": ["Token keyword", "Expr expression"],
    "Ternary Expr": ["Expr condition", "Expr thenBranch", "Expr elseBranch"],
    "ListLiteral Expr": ["Token bracket", "Array<Expr> elements"],
    "DictLiteral Expr": ["Token brace", "Array<Expr> keys", "Array<Expr> values"],
    "TupleLiteral Expr": ["Token paren", "Array<Expr> elements"],
    "IndexExpr Expr": ["Expr object", "Token bracket", "Expr index"],
    "IndexSet Expr": ["Expr object", "Token bracket", "Expr index", "Expr value"],
    "SliceExpr Expr": ["Expr object", "Token bracket", "Expr|null from", "Expr|null to"],
    "SliceSet Expr": ["Expr object", "Token bracket", "Expr|null from", "Expr|null to", "Expr value"],
    "Lambda Expr": ["Token keyword", "Array<Param> params", "Array<Stmt> body", "TypeExpr|null returnType"],

    "Expression Stmt": ["Expr expression"],
    "FunctionStmt Stmt": [
        "Token name",
        "Array<Param> params",
        "Array<Stmt> body",
        "boolean isStatic",
        "TypeExpr|null returnType",
    ],
    "ClassStmt Stmt": [
        "Token name",
        "Variable|null superclass",
        "Array<FunctionStmt> methods",
        "Array<ClassVarStmt> classVars",
    ],
    "BreakStmt Stmt": ["Token keyword"],
    "ContinueStmt Stmt": ["Token keyword"],
    "IfStmt Stmt": ["Expr condition", "Stmt thenBranch", "Stmt|null elseBranch"],
    "Block Stmt": ["Array<Stmt> statements"],
    "PrintStmt Stmt": ["Expr expression"],
    "ReturnStmt Stmt": ["Token keyword", "Expr|null value"],
    "WhileStmt Stmt": ["Expr condition", "Stmt body"],
    "ForStmt Stmt": ["Stmt|null initializer", "Expr|null condition", "Expr|null increment", "Stmt body"],
    "VariableDeclaration Stmt": ["Token name", "Expr initializer", "boolean isConst", "TypeExpr|null typeAnnotation"],
    "ForeachStmt Stmt": ["Token keyword", "Token name", "Expr iterable", "Stmt body"],
    "TryStmt Stmt": ["Stmt block", "Array<ExceptClause> clauses", "Stmt|null finallyBlock"],
    "RaiseStmt Stmt": ["Token keyword", "Expr expression"],
    "ImportStmt Stmt": ["Array<ImportName> names"],
    "ImportFromStmt Stmt": ["Token module", "Array<Token> names", "boolean isStar"],
    "BreakpointStmt Stmt": ["Token keyword"],
    "UnpackStmt Stmt": ["Array<Token> names", "Expr value"],
};

const header = `import { Token } from "./Token";

export interface Expr {
    visit<R>(visitor: Visitor<R>): R;
}

export interface Stmt {
    visit<R>(visitor: Visitor<R>): R;
}

// A parsed (but never checked) type annotation -- \`int\`, \`List[int]\`,
// \`int?\` -- mirroring odlox's own Type_Expr (../../src/compiler/ast.odin)
// and its three annotation sites exactly: Param.typeAnnotation,
// VariableDeclaration.typeAnnotation, FunctionStmt/Lambda.returnType (see
// ../../docs/plans/done/optional-type-checking-implementation.md). Not part of
// the Visitor<R> dispatch (like Param/ExceptClause/ImportName below):
// nothing on this LSP-only front end consults an annotation's *meaning*,
// only its shape -- parsed purely so annotated scripts don't produce
// spurious diagnostics.
export interface TypeExpr {
    kind: "named" | "generic" | "nilable";
    name: Token; // meaningful for "named"/"generic" (the outer name) and "nilable" (delegates to inner's name)
    args: Array<TypeExpr>; // meaningful only for "generic"
    inner: TypeExpr | null; // meaningful only for "nilable"
}

// A function/lambda parameter: a plain name, one with a default value
// (\`func f(x, y = 1)\`), one with a type annotation (\`func f(x: int)\`),
// or the single trailing variadic parameter (\`func f(*rest)\`) -- a
// variadic parameter never carries a type annotation, matching odlox's
// own parse_function_decl (Type_Expr parsing isn't offered there either).
export interface Param {
    name: Token;
    defaultValue: Expr | null;
    isVariadic: boolean;
    typeAnnotation: TypeExpr | null;
}

// One \`except Type as name { ... }\` clause of a try statement.
export interface ExceptClause {
    exceptionType: Token;
    name: Token;
    block: Stmt;
}

// One \`name [as alias]\` binding in an \`import\` statement.
export interface ImportName {
    name: Token;
    alias: Token | null;
}

// One \`static name = expr\` class-variable declaration inside a class body.
// Only ever produced by classDeclaration()'s member loop, never appears in a
// general Stmt list, so -- like Param/ExceptClause/ImportName -- it doesn't
// implement Stmt/Expr and isn't part of the Visitor<R> dispatch.
export interface ClassVarStmt {
    name: Token;
    initializer: Expr;
}

`;

function getClassSource(className: string, parent: string, fields: Array<string>) {
    fields = fields.map((f) => {
        const [type, name] = f.split(" ");
        return `readonly ${name}: ${type}`;
    });

    return `export class ${className} implements ${parent} {
    constructor(${fields.join(", ")}) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visit${className}(this);
    }
}

`;
}

function getVisitorSource(classNames: Array<string>) {
    return `export interface Visitor<R> {
${classNames.map((c) => `    visit${c}(${c.toLowerCase()}: ${c}): R;`).join("\n")}
}

`;
}

async function main() {
    let source = header;

    const classes = Object.keys(grammar).map((g) => g.split(" "));

    source += getVisitorSource(classes.map((c) => c[0]));

    for (const cls of classes) {
        const fields = grammar[`${cls[0]} ${cls[1]}`];
        if (!fields) {
            return;
        }
        source += getClassSource(cls[0], cls[1], fields!);
    }

    console.log(source);
}

if (require.main === module) {
    main();
}
