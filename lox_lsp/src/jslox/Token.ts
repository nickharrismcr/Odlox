/* eslint-disable @typescript-eslint/naming-convention */

export type TokenType =
    // Single-character tokens.
    | "LEFT_PAREN"
    | "RIGHT_PAREN"
    | "LEFT_BRACE"
    | "RIGHT_BRACE"
    | "LEFT_BRACKET"
    | "RIGHT_BRACKET"
    | "COMMA"
    | "DOT"
    | "MINUS"
    | "PLUS"
    | "SEMICOLON"
    | "SLASH"
    | "STAR"
    | "PERCENT"
    | "COLON"
    | "QUESTION"
    | "AMPERSAND"
    | "EOL"

    // One or two character tokens.
    | "BANG"
    | "BANG_EQUAL"
    | "EQUAL"
    | "EQUAL_EQUAL"
    | "GREATER"
    | "GREATER_EQUAL"
    | "LESS"
    | "LESS_EQUAL"
    | "PLUS_EQUAL"
    | "MINUS_EQUAL"
    | "STAR_EQUAL"
    | "SLASH_EQUAL"
    | "PERCENT_EQUAL"
    | "PLUS_PLUS"
    | "ARROW"

    // Literals
    | "IDENTIFIER"
    | "STRING"
    | "INT"
    | "FLOAT"

    // Keywords
    | "AND"
    | "CLASS"
    | "ELSE"
    | "FALSE"
    | "FUN"
    | "FOR"
    | "IF"
    | "NIL"
    | "OR"
    | "PRINT"
    | "RETURN"
    | "SUPER"
    | "THIS"
    | "TRUE"
    | "VAR"
    | "WHILE"
    | "EOF"
    | "BREAK"
    | "CONTINUE"
    | "CONST"
    | "STR"
    | "IMPORT"
    | "TRY"
    | "EXCEPT"
    | "AS"
    | "FINALLY"
    | "RAISE"
    | "FOREACH"
    | "IN"
    | "BREAKPOINT"
    | "STATIC"
    | "FROM";

export class Token {
    constructor(
        readonly type: TokenType,
        readonly lexeme: string,
        readonly literal: string | number | boolean | undefined,
        readonly line: number,
        readonly character: number,
        readonly start: number,
        readonly end: number
    ) {}

    toString(): string {
        return `${this.type} ${this.lexeme} ${this.literal || ""}`;
    }
}
