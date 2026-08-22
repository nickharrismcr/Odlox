import { Token } from "./Token";

export interface Expr {
    visit<R>(visitor: Visitor<R>): R;
}

export interface Stmt {
    visit<R>(visitor: Visitor<R>): R;
}

// A parsed (but never checked) type annotation -- `int`, `List[int]`,
// `int?` -- mirroring odlox's own Type_Expr (../../src/compiler/ast.odin)
// and its three annotation sites exactly: Param.typeAnnotation,
// VariableDeclaration.typeAnnotation, FunctionStmt/Lambda.returnType (see
// ../../docs/plans/optional-type-checking-implementation.md's Phase 1).
// Not part of the Visitor<R> dispatch (like Param/ExceptClause/ImportName
// below): nothing on this LSP-only front end consults an annotation's
// *meaning* yet, only its shape -- parsed purely so annotated scripts
// don't produce spurious diagnostics.
export interface TypeExpr {
    kind: "named" | "generic" | "nilable";
    name: Token; // meaningful for "named"/"generic" (the outer name) and "nilable" (delegates to inner's name)
    args: Array<TypeExpr>; // meaningful only for "generic"
    inner: TypeExpr | null; // meaningful only for "nilable"
}

// A function/lambda parameter: a plain name, one with a default value
// (`func f(x, y = 1)`), one with a type annotation (`func f(x: int)`),
// or the single trailing variadic parameter (`func f(*rest)`) -- a
// variadic parameter never carries a type annotation, matching odlox's
// own parse_function_decl (Type_Expr parsing isn't offered there either).
export interface Param {
    name: Token;
    defaultValue: Expr | null;
    isVariadic: boolean;
    typeAnnotation: TypeExpr | null;
}

// One `except Type as name { ... }` clause of a try statement.
export interface ExceptClause {
    exceptionType: Token;
    name: Token;
    block: Stmt;
}

// One `name [as alias]` binding in an `import` statement.
export interface ImportName {
    name: Token;
    alias: Token | null;
}

// One `static name = expr` class-variable declaration inside a class body.
// Only ever produced by classDeclaration()'s member loop, never appears in a
// general Stmt list, so -- like Param/ExceptClause/ImportName -- it doesn't
// implement Stmt/Expr and isn't part of the Visitor<R> dispatch.
export interface ClassVarStmt {
    name: Token;
    initializer: Expr;
}

export interface Visitor<R> {
    visitAssign(assign: Assign): R;
    visitBinary(binary: Binary): R;
    visitGrouping(grouping: Grouping): R;
    visitLiteral(literal: Literal): R;
    visitLogical(logical: Logical): R;
    visitVariable(variable: Variable): R;
    visitUnary(unary: Unary): R;
    visitCall(call: Call): R;
    visitGet(get: Get): R;
    visitSet(set: Set): R;
    visitSuperExpr(superexpr: SuperExpr): R;
    visitThisExpr(thisexpr: ThisExpr): R;
    visitStrExpr(strexpr: StrExpr): R;
    visitTernary(ternary: Ternary): R;
    visitListLiteral(listliteral: ListLiteral): R;
    visitDictLiteral(dictliteral: DictLiteral): R;
    visitTupleLiteral(tupleliteral: TupleLiteral): R;
    visitIndexExpr(indexexpr: IndexExpr): R;
    visitIndexSet(indexset: IndexSet): R;
    visitSliceExpr(sliceexpr: SliceExpr): R;
    visitSliceSet(sliceset: SliceSet): R;
    visitLambda(lambda: Lambda): R;
    visitExpression(expression: Expression): R;
    visitFunctionStmt(functionstmt: FunctionStmt): R;
    visitClassStmt(classstmt: ClassStmt): R;
    visitBreakStmt(breakstmt: BreakStmt): R;
    visitContinueStmt(continuestmt: ContinueStmt): R;
    visitIfStmt(ifstmt: IfStmt): R;
    visitBlock(block: Block): R;
    visitPrintStmt(printstmt: PrintStmt): R;
    visitReturnStmt(returnstmt: ReturnStmt): R;
    visitWhileStmt(whilestmt: WhileStmt): R;
    visitForStmt(forstmt: ForStmt): R;
    visitVariableDeclaration(variabledeclaration: VariableDeclaration): R;
    visitForeachStmt(foreachstmt: ForeachStmt): R;
    visitTryStmt(trystmt: TryStmt): R;
    visitRaiseStmt(raisestmt: RaiseStmt): R;
    visitImportStmt(importstmt: ImportStmt): R;
    visitImportFromStmt(importfromstmt: ImportFromStmt): R;
    visitBreakpointStmt(breakpointstmt: BreakpointStmt): R;
    visitUnpackStmt(unpackstmt: UnpackStmt): R;
}

export class Assign implements Expr {
    constructor(readonly name: Token, readonly value: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitAssign(this);
    }
}

export class Binary implements Expr {
    constructor(readonly left: Expr, readonly operator: Token, readonly right: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitBinary(this);
    }
}

export class Grouping implements Expr {
    constructor(readonly expression: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitGrouping(this);
    }
}

export class Literal implements Expr {
    constructor(readonly value: string | number | null | boolean) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitLiteral(this);
    }
}

export class Logical implements Expr {
    constructor(readonly left: Expr, readonly operator: Token, readonly right: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitLogical(this);
    }
}

export class Variable implements Expr {
    constructor(readonly name: Token) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitVariable(this);
    }
}

export class Unary implements Expr {
    constructor(readonly operator: Token, readonly right: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitUnary(this);
    }
}

export class Call implements Expr {
    constructor(readonly callee: Expr, readonly paren: Token, readonly args: Array<Expr>) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitCall(this);
    }
}

export class Get implements Expr {
    constructor(readonly object: Expr, readonly name: Token) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitGet(this);
    }
}

export class Set implements Expr {
    constructor(readonly object: Expr, readonly name: Token, readonly value: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitSet(this);
    }
}

export class SuperExpr implements Expr {
    constructor(readonly keyword: Token, readonly method: Token) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitSuperExpr(this);
    }
}

export class ThisExpr implements Expr {
    constructor(readonly keyword: Token) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitThisExpr(this);
    }
}

export class StrExpr implements Expr {
    constructor(readonly keyword: Token, readonly expression: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitStrExpr(this);
    }
}

export class Ternary implements Expr {
    constructor(readonly condition: Expr, readonly thenBranch: Expr, readonly elseBranch: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitTernary(this);
    }
}

export class ListLiteral implements Expr {
    constructor(readonly bracket: Token, readonly elements: Array<Expr>) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitListLiteral(this);
    }
}

export class DictLiteral implements Expr {
    constructor(readonly brace: Token, readonly keys: Array<Expr>, readonly values: Array<Expr>) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitDictLiteral(this);
    }
}

export class TupleLiteral implements Expr {
    constructor(readonly paren: Token, readonly elements: Array<Expr>) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitTupleLiteral(this);
    }
}

export class IndexExpr implements Expr {
    constructor(readonly object: Expr, readonly bracket: Token, readonly index: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitIndexExpr(this);
    }
}

export class IndexSet implements Expr {
    constructor(readonly object: Expr, readonly bracket: Token, readonly index: Expr, readonly value: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitIndexSet(this);
    }
}

export class SliceExpr implements Expr {
    constructor(readonly object: Expr, readonly bracket: Token, readonly from: Expr | null, readonly to: Expr | null) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitSliceExpr(this);
    }
}

export class SliceSet implements Expr {
    constructor(
        readonly object: Expr,
        readonly bracket: Token,
        readonly from: Expr | null,
        readonly to: Expr | null,
        readonly value: Expr
    ) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitSliceSet(this);
    }
}

export class Lambda implements Expr {
    constructor(
        readonly keyword: Token,
        readonly params: Array<Param>,
        readonly body: Array<Stmt>,
        readonly returnType: TypeExpr | null
    ) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitLambda(this);
    }
}

export class Expression implements Stmt {
    constructor(readonly expression: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitExpression(this);
    }
}

export class FunctionStmt implements Stmt {
    constructor(
        readonly name: Token,
        readonly params: Array<Param>,
        readonly body: Array<Stmt>,
        readonly isStatic: boolean,
        readonly returnType: TypeExpr | null
    ) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitFunctionStmt(this);
    }
}

export class ClassStmt implements Stmt {
    constructor(
        readonly name: Token,
        readonly superclass: Variable | null,
        readonly methods: Array<FunctionStmt>,
        readonly classVars: Array<ClassVarStmt>
    ) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitClassStmt(this);
    }
}

export class BreakStmt implements Stmt {
    constructor(readonly keyword: Token) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitBreakStmt(this);
    }
}

export class ContinueStmt implements Stmt {
    constructor(readonly keyword: Token) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitContinueStmt(this);
    }
}

export class IfStmt implements Stmt {
    constructor(readonly condition: Expr, readonly thenBranch: Stmt, readonly elseBranch: Stmt | null) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitIfStmt(this);
    }
}

export class Block implements Stmt {
    constructor(readonly statements: Array<Stmt>) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitBlock(this);
    }
}

export class PrintStmt implements Stmt {
    constructor(readonly expression: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitPrintStmt(this);
    }
}

export class ReturnStmt implements Stmt {
    constructor(readonly keyword: Token, readonly value: Expr | null) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitReturnStmt(this);
    }
}

export class WhileStmt implements Stmt {
    constructor(readonly condition: Expr, readonly body: Stmt) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitWhileStmt(this);
    }
}

export class ForStmt implements Stmt {
    constructor(
        readonly initializer: Stmt | null,
        readonly condition: Expr | null,
        readonly increment: Expr | null,
        readonly body: Stmt
    ) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitForStmt(this);
    }
}

export class VariableDeclaration implements Stmt {
    constructor(
        readonly name: Token,
        readonly initializer: Expr,
        readonly isConst: boolean,
        readonly typeAnnotation: TypeExpr | null
    ) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitVariableDeclaration(this);
    }
}

export class ForeachStmt implements Stmt {
    constructor(readonly keyword: Token, readonly name: Token, readonly iterable: Expr, readonly body: Stmt) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitForeachStmt(this);
    }
}

export class TryStmt implements Stmt {
    constructor(readonly block: Stmt, readonly clauses: Array<ExceptClause>, readonly finallyBlock: Stmt | null) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitTryStmt(this);
    }
}

export class RaiseStmt implements Stmt {
    constructor(readonly keyword: Token, readonly expression: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitRaiseStmt(this);
    }
}

export class ImportStmt implements Stmt {
    constructor(readonly names: Array<ImportName>) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitImportStmt(this);
    }
}

export class ImportFromStmt implements Stmt {
    constructor(readonly module: Token, readonly names: Array<Token>, readonly isStar: boolean) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitImportFromStmt(this);
    }
}

export class BreakpointStmt implements Stmt {
    constructor(readonly keyword: Token) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitBreakpointStmt(this);
    }
}

export class UnpackStmt implements Stmt {
    constructor(readonly names: Array<Token>, readonly value: Expr) {}

    visit<R>(visitor: Visitor<R>): R {
        return visitor.visitUnpackStmt(this);
    }
}
