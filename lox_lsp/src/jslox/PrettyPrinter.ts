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
    Param,
    PrintStmt,
    RaiseStmt,
    ReturnStmt,
    Set,
    SliceExpr,
    SliceSet,
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
} from "./Expr";

export class PrettyPrinter implements Visitor<string> {
    visitSuperExpr(superexpr: SuperExpr): string {
        return `(super ${superexpr.method.lexeme})`;
    }

    visitThisExpr(thisexpr: ThisExpr): string {
        return "(this)";
    }

    visitSet(set: Set): string {
        return `(set ${set.object.visit(this)} ${set.name.lexeme} ${set.value.visit(this)})`;
    }

    visitGet(get: Get): string {
        return `(get ${get.object.visit(this)} ${get.name.lexeme})`;
    }

    visitClassStmt(classstmt: ClassStmt): string {
        const superclass = classstmt.superclass ? ` < ${classstmt.superclass.name.lexeme}` : "";
        const methods = classstmt.methods.map((method) => method.visit(this));
        const classVars = classstmt.classVars.map(
            (classVar) => `(static ${classVar.name.lexeme} ${classVar.initializer.visit(this)})`
        );
        return `(class ${classstmt.name.lexeme}${superclass} ${methods.concat(classVars).join(" ")})`;
    }

    visitReturnStmt(returnstmt: ReturnStmt): string {
        return `(return ${returnstmt.value?.visit(this) || ""})`;
    }

    visitLogical(logical: Logical): string {
        return `(logical ${logical.operator.lexeme} ${logical.left.visit(this)} ${logical.right.visit(this)})`;
    }

    visitBreakStmt(breakstmt: BreakStmt): string {
        return "(break)";
    }

    visitContinueStmt(continuestmt: ContinueStmt): string {
        return "(continue)";
    }

    visitIfStmt(ifstmt: IfStmt): string {
        return `(if ${ifstmt.condition.visit(this)} ${ifstmt.thenBranch.visit(this)} ${ifstmt.elseBranch?.visit(
            this
        )})`;
    }

    visitWhileStmt(whilestmt: WhileStmt): string {
        return `(while ${whilestmt.condition.visit(this)} ${whilestmt.body.visit(this)})`;
    }

    visitForStmt(forstmt: ForStmt): string {
        return `(for ${forstmt.initializer?.visit(this)} ${forstmt.condition?.visit(this)} ${forstmt.increment?.visit(
            this
        )} ${forstmt.body.visit(this)})`;
    }

    visitAssign(assign: Assign): string {
        return `(set ${assign.name.lexeme} ${assign.value.visit(this)})`;
    }

    visitVariable(variable: Variable): string {
        return variable.name.lexeme;
    }

    visitVariableDeclaration(variabledeclaration: VariableDeclaration): string {
        const kind = variabledeclaration.isConst ? "const" : "var";
        return `(${kind} ${variabledeclaration.name.lexeme} ${variabledeclaration.initializer.visit(this)})`;
    }

    visitFunctionStmt(functiondecl: FunctionStmt): string {
        const params = functiondecl.params.map((param) => this.paramString(param)).join(" ");
        const body = functiondecl.body.map((statement) => statement.visit(this)).join(" ");
        return `(fun ${functiondecl.name.lexeme} (${params}) (${body}))`;
    }

    visitLambda(lambda: Lambda): string {
        const params = lambda.params.map((param) => this.paramString(param)).join(" ");
        const body = lambda.body.map((statement) => statement.visit(this)).join(" ");
        return `(func (${params}) (${body}))`;
    }

    private paramString(param: Param): string {
        if (param.isVariadic) {
            return `*${param.name.lexeme}`;
        }
        if (param.defaultValue) {
            return `${param.name.lexeme}=${param.defaultValue.visit(this)}`;
        }
        return param.name.lexeme;
    }

    visitCall(call: Call): string {
        return `(call ${call.callee.visit(this)} ${call.args.map((arg) => arg.visit(this)).join(" ")})`;
    }

    visitBlock(block: Block): string {
        return `(block ${block.statements.map((statement) => statement.visit(this)).join(" ")})`;
    }

    visitExpression(expression: Expression): string {
        return expression.expression.visit(this);
    }

    visitPrintStmt(print: PrintStmt): string {
        return `(print ${print.expression.visit(this)})`;
    }

    visitBinary(binary: Binary): string {
        return `(${binary.operator.lexeme} ${binary.left.visit(this)} ${binary.right.visit(this)})`;
    }

    visitGrouping(grouping: Grouping): string {
        return `(${grouping.expression.visit(this)})`;
    }

    visitLiteral(literal: Literal): string {
        return literal?.value?.toString() || "nil";
    }

    visitUnary(unary: Unary): string {
        return `(${unary.operator.lexeme} ${unary.right.visit(this)})`;
    }

    visitTernary(ternary: Ternary): string {
        return `(?: ${ternary.condition.visit(this)} ${ternary.thenBranch.visit(this)} ${ternary.elseBranch.visit(
            this
        )})`;
    }

    visitListLiteral(listliteral: ListLiteral): string {
        return `(list ${listliteral.elements.map((element) => element.visit(this)).join(" ")})`;
    }

    visitDictLiteral(dictliteral: DictLiteral): string {
        const pairs = dictliteral.keys.map((key, i) => `(${key.visit(this)} ${dictliteral.values[i].visit(this)})`);
        return `(dict ${pairs.join(" ")})`;
    }

    visitTupleLiteral(tupleliteral: TupleLiteral): string {
        return `(tuple ${tupleliteral.elements.map((element) => element.visit(this)).join(" ")})`;
    }

    visitIndexExpr(indexexpr: IndexExpr): string {
        return `(index ${indexexpr.object.visit(this)} ${indexexpr.index.visit(this)})`;
    }

    visitIndexSet(indexset: IndexSet): string {
        return `(index-set ${indexset.object.visit(this)} ${indexset.index.visit(this)} ${indexset.value.visit(
            this
        )})`;
    }

    visitSliceExpr(sliceexpr: SliceExpr): string {
        return `(slice ${sliceexpr.object.visit(this)} ${sliceexpr.from?.visit(this) ?? "nil"} ${
            sliceexpr.to?.visit(this) ?? "nil"
        })`;
    }

    visitSliceSet(sliceset: SliceSet): string {
        return `(slice-set ${sliceset.object.visit(this)} ${sliceset.from?.visit(this) ?? "nil"} ${
            sliceset.to?.visit(this) ?? "nil"
        } ${sliceset.value.visit(this)})`;
    }

    visitStrExpr(strexpr: StrExpr): string {
        return `(str ${strexpr.expression.visit(this)})`;
    }

    visitForeachStmt(foreachstmt: ForeachStmt): string {
        return `(foreach ${foreachstmt.name.lexeme} ${foreachstmt.iterable.visit(this)} ${foreachstmt.body.visit(
            this
        )})`;
    }

    visitTryStmt(trystmt: TryStmt): string {
        const clauses = trystmt.clauses.map(
            (clause) => `(except ${clause.exceptionType.lexeme} ${clause.name.lexeme} ${clause.block.visit(this)})`
        );
        const finallyPart = trystmt.finallyBlock ? ` (finally ${trystmt.finallyBlock.visit(this)})` : "";
        return `(try ${trystmt.block.visit(this)} ${clauses.join(" ")}${finallyPart})`;
    }

    visitRaiseStmt(raisestmt: RaiseStmt): string {
        return `(raise ${raisestmt.expression.visit(this)})`;
    }

    visitImportStmt(importstmt: ImportStmt): string {
        const names = importstmt.names.map((n) => (n.alias ? `${n.name.lexeme} as ${n.alias.lexeme}` : n.name.lexeme));
        return `(import ${names.join(" ")})`;
    }

    visitImportFromStmt(importfromstmt: ImportFromStmt): string {
        const names = importfromstmt.isStar ? "*" : importfromstmt.names.map((n) => n.lexeme).join(" ");
        return `(from ${importfromstmt.module.lexeme} import ${names})`;
    }

    visitBreakpointStmt(breakpointstmt: BreakpointStmt): string {
        return "(breakpoint)";
    }

    visitUnpackStmt(unpackstmt: UnpackStmt): string {
        return `(unpack (${unpackstmt.names.map((n) => n.lexeme).join(" ")}) ${unpackstmt.value.visit(this)})`;
    }
}
