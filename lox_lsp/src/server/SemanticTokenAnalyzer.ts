import { DocumentSymbol, SymbolKind } from "vscode-languageserver";
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
    Expression,
    ForStmt,
    ForeachStmt,
    FunctionStmt,
    Get,
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
    PrintStmt,
    RaiseStmt,
    ReturnStmt,
    Set,
    SliceExpr,
    SliceSet,
    Stmt,
    StrExpr,
    SuperExpr,
    Ternary,
    ThisExpr,
    TryStmt,
    TupleLiteral,
    Unary,
    UnpackStmt,
    Variable,
    VariableDeclaration,
    Visitor,
    WhileStmt,
} from "../jslox/Expr";
import { Resolver } from "../jslox/Resolver";

export const TOKEN_LEGEND = ["class", "function", "variable", "parameter", "property"] as const;
export type TokenType = (typeof TOKEN_LEGEND)[number];

export const TOKEN_TO_ID = TOKEN_LEGEND.reduce((map, token, index) => {
    map[token] = index;
    return map;
}, {} as { [key: string]: number });

export interface SemanticToken {
    start: number;
    end: number;
    type: TokenType;
}

export class SemanticTokenAnalyzer implements Visitor<void> {
    public tokens: Array<SemanticToken> = [];
    public documentSymbols: Array<DocumentSymbol> = [];

    private resolver?: Resolver;
    private currentSymbol?: DocumentSymbol;

    analyze(statemens: Stmt[], resolver: Resolver) {
        this.resolver = resolver;
        this.tokens = [];
        this.documentSymbols = [];
        this.currentSymbol = undefined;

        for (const statement of statemens) {
            statement.visit(this);
        }

        return this.tokens;
    }

    visitAssign(assign: Assign): void {
        this.tokens.push({
            start: assign.name.start,
            end: assign.name.end,
            type: "variable",
        });
        assign.value.visit(this);
    }

    visitBinary(binary: Binary): void {
        binary.left.visit(this);
        binary.right.visit(this);
    }

    visitGrouping(grouping: Grouping): void {
        grouping.expression.visit(this);
    }

    visitLiteral(literal: Literal): void {}

    visitLogical(logical: Logical): void {
        logical.left.visit(this);
        logical.right.visit(this);
    }

    visitVariable(variable: Variable): void {
        let type: TokenType = "variable";

        if (this.resolver) {
            const def = this.resolver.references.get(variable.name);
            if (def) {
                type = this.resolver.definitionType.get(def) || "parameter";
            }
        }

        this.tokens.push({
            start: variable.name.start,
            end: variable.name.end,
            type,
        });
    }

    visitUnary(unary: Unary): void {
        unary.right.visit(this);
    }

    visitCall(call: Call): void {
        call.callee.visit(this);
        for (const argument of call.args) {
            argument.visit(this);
        }
    }

    visitExpression(expression: Expression): void {
        expression.expression.visit(this);
    }

    visitSuperExpr(superexpr: SuperExpr): void {}

    visitClassStmt(classstmt: ClassStmt): void {
        this.tokens.push({
            start: classstmt.name.start,
            end: classstmt.name.end,
            type: "class",
        });

        if (classstmt.superclass) {
            classstmt.superclass.visit(this);

            this.tokens.push({
                start: classstmt.superclass.name.start,
                end: classstmt.superclass.name.end,
                type: "class",
            });
        }

        const enclosingSymbol = this.startBlock({
            name: classstmt.name.lexeme,
            kind: SymbolKind.Class,
            range: {
                start: classstmt.name,
                end: classstmt.name,
            },
            selectionRange: {
                start: classstmt.name,
                end: classstmt.name,
            },
            children: [],
        });

        for (const method of classstmt.methods) {
            method.visit(this);
        }

        for (const classVar of classstmt.classVars) {
            this.tokens.push({
                start: classVar.name.start,
                end: classVar.name.end,
                type: "property",
            });
            classVar.initializer.visit(this);
        }

        this.endBlock(enclosingSymbol);
    }

    visitGet(get: Get): void {
        get.object.visit(this);
        this.tokens.push({
            start: get.name.start,
            end: get.name.end,
            type: "property",
        });
    }

    visitSet(set: Set): void {
        set.object.visit(this);
        this.tokens.push({
            start: set.name.start,
            end: set.name.end,
            type: "property",
        });

        set.value.visit(this);
    }

    visitThisExpr(thisexpr: ThisExpr): void {}

    visitFunctionStmt(functionstmt: FunctionStmt): void {
        const isMethod = this.currentSymbol?.kind === SymbolKind.Class;

        this.tokens.push({
            start: functionstmt.name.start,
            end: functionstmt.name.end,
            type: isMethod ? "property" : "function",
        });

        const enclosingSymbol = this.startBlock({
            name: functionstmt.name.lexeme,
            kind: isMethod ? SymbolKind.Method : SymbolKind.Function,
            range: {
                start: functionstmt.name,
                end: functionstmt.name,
            },
            selectionRange: {
                start: functionstmt.name,
                end: functionstmt.name,
            },
            children: [],
        });

        for (const param of functionstmt.params) {
            this.tokens.push({
                start: param.name.start,
                end: param.name.end,
                type: "parameter",
            });
            param.defaultValue?.visit(this);
        }
        functionstmt.body.forEach((stmt) => stmt.visit(this));

        this.endBlock(enclosingSymbol);
    }

    visitBreakStmt(breakstmt: BreakStmt): void {}
    visitContinueStmt(continuestmt: ContinueStmt): void {}

    visitLambda(lambda: Lambda): void {
        for (const param of lambda.params) {
            this.tokens.push({
                start: param.name.start,
                end: param.name.end,
                type: "parameter",
            });
            param.defaultValue?.visit(this);
        }
        lambda.body.forEach((stmt) => stmt.visit(this));
    }

    visitTernary(ternary: Ternary): void {
        ternary.condition.visit(this);
        ternary.thenBranch.visit(this);
        ternary.elseBranch.visit(this);
    }

    visitListLiteral(listliteral: ListLiteral): void {
        listliteral.elements.forEach((element) => element.visit(this));
    }

    visitDictLiteral(dictliteral: DictLiteral): void {
        dictliteral.keys.forEach((key) => key.visit(this));
        dictliteral.values.forEach((value) => value.visit(this));
    }

    visitTupleLiteral(tupleliteral: TupleLiteral): void {
        tupleliteral.elements.forEach((element) => element.visit(this));
    }

    visitIndexExpr(indexexpr: IndexExpr): void {
        indexexpr.object.visit(this);
        indexexpr.index.visit(this);
    }

    visitIndexSet(indexset: IndexSet): void {
        indexset.object.visit(this);
        indexset.index.visit(this);
        indexset.value.visit(this);
    }

    visitSliceExpr(sliceexpr: SliceExpr): void {
        sliceexpr.object.visit(this);
        sliceexpr.from?.visit(this);
        sliceexpr.to?.visit(this);
    }

    visitSliceSet(sliceset: SliceSet): void {
        sliceset.object.visit(this);
        sliceset.from?.visit(this);
        sliceset.to?.visit(this);
        sliceset.value.visit(this);
    }

    visitStrExpr(strexpr: StrExpr): void {
        strexpr.expression.visit(this);
    }

    visitForeachStmt(foreachstmt: ForeachStmt): void {
        foreachstmt.iterable.visit(this);
        this.tokens.push({
            start: foreachstmt.name.start,
            end: foreachstmt.name.end,
            type: "parameter",
        });
        foreachstmt.body.visit(this);
    }

    visitTryStmt(trystmt: TryStmt): void {
        trystmt.block.visit(this);
        for (const clause of trystmt.clauses) {
            this.tokens.push({
                start: clause.exceptionType.start,
                end: clause.exceptionType.end,
                type: "class",
            });
            this.tokens.push({
                start: clause.name.start,
                end: clause.name.end,
                type: "variable",
            });
            clause.block.visit(this);
        }
        trystmt.finallyBlock?.visit(this);
    }

    visitRaiseStmt(raisestmt: RaiseStmt): void {
        raisestmt.expression.visit(this);
    }

    visitImportStmt(importstmt: ImportStmt): void {
        for (const imp of importstmt.names) {
            const bound = imp.alias ?? imp.name;
            this.tokens.push({
                start: bound.start,
                end: bound.end,
                type: "variable",
            });
        }
    }

    visitImportFromStmt(importfromstmt: ImportFromStmt): void {
        if (importfromstmt.isStar) {
            return;
        }
        for (const name of importfromstmt.names) {
            this.tokens.push({
                start: name.start,
                end: name.end,
                type: "variable",
            });
        }
    }

    visitBreakpointStmt(breakpointstmt: BreakpointStmt): void {}

    visitUnpackStmt(unpackstmt: UnpackStmt): void {
        for (const name of unpackstmt.names) {
            this.tokens.push({
                start: name.start,
                end: name.end,
                type: "variable",
            });
        }
        unpackstmt.value.visit(this);
    }

    visitIfStmt(ifstmt: IfStmt): void {
        ifstmt.condition.visit(this);
        ifstmt.thenBranch.visit(this);
        ifstmt.elseBranch?.visit(this);
    }

    visitBlock(block: Block): void {
        block.statements.forEach((stmt) => stmt.visit(this));
    }

    visitPrintStmt(printstmt: PrintStmt): void {
        printstmt.expression.visit(this);
    }

    visitReturnStmt(returnstmt: ReturnStmt): void {
        returnstmt.value?.visit(this);
    }

    visitWhileStmt(whilestmt: WhileStmt): void {
        whilestmt.condition.visit(this);
        whilestmt.body.visit(this);
    }

    visitForStmt(forstmt: ForStmt): void {
        forstmt.initializer?.visit(this);
        forstmt.condition?.visit(this);
        forstmt.increment?.visit(this);
        forstmt.body.visit(this);
    }

    visitVariableDeclaration(variabledeclaration: VariableDeclaration): void {
        this.tokens.push({
            start: variabledeclaration.name.start,
            end: variabledeclaration.name.end,
            type: "variable",
        });
        variabledeclaration.initializer?.visit(this);
    }

    private startBlock(newSymbol: DocumentSymbol) {
        const enclosingSymbol = this.currentSymbol;
        this.currentSymbol = newSymbol;

        return enclosingSymbol;
    }

    private endBlock(enclosingSymbol: DocumentSymbol | undefined) {
        if (this.currentSymbol) {
            if (enclosingSymbol) {
                enclosingSymbol.children?.push(this.currentSymbol);
            } else {
                this.documentSymbols.push(this.currentSymbol);
            }
        }
        this.currentSymbol = enclosingSymbol;
    }
}
