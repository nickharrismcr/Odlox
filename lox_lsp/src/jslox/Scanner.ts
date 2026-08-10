import { ErrorReporter, defaultErrorReporter } from "./Error";
import { Token, TokenType } from "./Token";

// A Map, not a plain object: a plain `{}` literal inherits Object.prototype
// members (toString, constructor, valueOf, hasOwnProperty, ...), so
// `keywords["toString"]` would silently return the inherited *function*
// instead of undefined for any script defining a method/identifier with one
// of those names -- a real bug this surfaced against a class defining
// `toString()` (glox's `str()`-coercion convention encourages exactly that).
const keywords: Map<string, TokenType> = new Map([
    ["and", "AND"],
    ["class", "CLASS"],
    ["else", "ELSE"],
    ["false", "FALSE"],
    ["for", "FOR"],
    ["fun", "FUN"],
    ["func", "FUN"], // glox accepts both spellings
    ["if", "IF"],
    ["nil", "NIL"],
    ["or", "OR"],
    ["print", "PRINT"],
    ["return", "RETURN"],
    ["super", "SUPER"],
    ["this", "THIS"],
    ["true", "TRUE"],
    ["var", "VAR"],
    ["while", "WHILE"],
    ["break", "BREAK"], // non standard
    ["continue", "CONTINUE"], // non standard
    ["const", "CONST"],
    ["str", "STR"],
    ["import", "IMPORT"],
    ["try", "TRY"],
    ["except", "EXCEPT"],
    ["as", "AS"],
    ["finally", "FINALLY"],
    ["raise", "RAISE"],
    ["foreach", "FOREACH"],
    ["in", "IN"],
    ["breakpoint", "BREAKPOINT"],
    ["static", "STATIC"],
    ["from", "FROM"],
]);

// A newline is only a real statement terminator (EOL) when the previous token
// couldn't sensibly end a statement -- e.g. right after "(" or "," a newline is
// just a line-continuation. Mirrors glox's own scanner (SkipEOL in
// ../../../src/compiler/scanner.go) exactly, so the two stay in sync.
const EOL_SUPPRESSED_AFTER: ReadonlySet<TokenType> = new Set<TokenType>([
    "LEFT_BRACE",
    "LEFT_PAREN",
    "LEFT_BRACKET",
    "COMMA",
    "SEMICOLON",
    "COLON",
    "EOL",
    "QUESTION",
    "EQUAL",
    "MINUS",
    "PLUS",
    "SLASH",
    "PERCENT",
]);

// One piece of an interpolated string literal: either a run of literal text
// (isExpr false) or an embedded ${ ... } expression already tokenised into
// toks (isExpr true).
interface InterpSegment {
    isExpr: boolean;
    text?: string;
    toks?: Token[];
}

export class Scanner {
    private start = 0;
    private current = 0;
    private line = 1;
    private character = 0;
    private lastTokenType: TokenType | null = null;

    constructor(private readonly source: string, readonly errorReporter: ErrorReporter = defaultErrorReporter) {}

    *scanTokens(): Generator<Token> {
        while (!this.isAtEnd()) {
            this.start = this.current;
            for (const tok of this.scanToken()) {
                this.lastTokenType = tok.type;
                yield tok;
            }
        }

        yield new Token("EOF", "", undefined, this.line, this.character, this.start, this.current);
    }

    private isAtEnd(): boolean {
        return this.current >= this.source.length;
    }

    private *scanToken(): Generator<Token> {
        const c = this.advance();
        switch (c) {
            case "(":
                yield this.makeToken("LEFT_PAREN");
                break;
            case ")":
                yield this.makeToken("RIGHT_PAREN");
                break;
            case "{":
                yield this.makeToken("LEFT_BRACE");
                break;
            case "}":
                yield this.makeToken("RIGHT_BRACE");
                break;
            case "[":
                yield this.makeToken("LEFT_BRACKET");
                break;
            case "]":
                yield this.makeToken("RIGHT_BRACKET");
                break;
            case ",":
                yield this.makeToken("COMMA");
                break;
            case ".":
                yield this.makeToken("DOT");
                break;
            case ":":
                yield this.makeToken("COLON");
                break;
            case "?":
                yield this.makeToken("QUESTION");
                break;
            case "&":
                yield this.makeToken("AMPERSAND");
                break;
            case "-":
                yield this.makeToken(this.match("=") ? "MINUS_EQUAL" : "MINUS");
                break;
            case "+":
                if (this.match("=")) {
                    yield this.makeToken("PLUS_EQUAL");
                } else if (this.match("+")) {
                    yield this.makeToken("PLUS_PLUS");
                } else {
                    yield this.makeToken("PLUS");
                }
                break;
            case ";":
                yield this.makeToken("SEMICOLON");
                break;
            case "*":
                yield this.makeToken(this.match("=") ? "STAR_EQUAL" : "STAR");
                break;
            case "%":
                yield this.makeToken(this.match("=") ? "PERCENT_EQUAL" : "PERCENT");
                break;
            case "!":
                yield this.makeToken(this.match("=") ? "BANG_EQUAL" : "BANG");
                break;
            case "=":
                yield this.makeToken(this.match("=") ? "EQUAL_EQUAL" : "EQUAL");
                break;
            case "<":
                yield this.makeToken(this.match("=") ? "LESS_EQUAL" : "LESS");
                break;
            case ">":
                yield this.makeToken(this.match("=") ? "GREATER_EQUAL" : "GREATER");
                break;
            case "/":
                if (this.match("/")) {
                    while (this.peek() !== "\n" && !this.isAtEnd()) {
                        this.advance();
                    }
                } else if (this.match("=")) {
                    yield this.makeToken("SLASH_EQUAL");
                } else {
                    yield this.makeToken("SLASH");
                }
                break;

            case " ":
            case "\r":
            case "\t":
                break;

            case "\n":
                if (this.lastTokenType !== null && !EOL_SUPPRESSED_AFTER.has(this.lastTokenType)) {
                    yield this.makeToken("EOL");
                }
                this.line++;
                this.character = 0;
                break;

            case '"':
            case "'":
                yield* this.string(c);
                break;

            default:
                if (this.isDigit(c)) {
                    yield* this.number();
                } else if (this.isAlpha(c)) {
                    yield* this.identifier();
                } else {
                    this.errorReporter.error(
                        {
                            line: this.line,
                            start: this.current,
                            end: this.current + 1,
                        },
                        "Unexpected character."
                    );
                }
                break;
        }
    }

    private advance() {
        this.character++;
        return this.source.charAt(this.current++);
    }

    private peek(): string {
        if (this.isAtEnd()) {
            return "\0";
        }
        return this.source.charAt(this.current);
    }

    private peekNext(): string {
        if (this.current + 1 >= this.source.length) {
            return "\0";
        }

        return this.source.charAt(this.current + 1);
    }

    private match(expected: string): boolean {
        if (this.isAtEnd()) {
            return false;
        }
        if (this.source.charAt(this.current) !== expected) {
            return false;
        }

        this.character++;
        this.current++;
        return true;
    }

    private isDigit(c: string): boolean {
        return c.charCodeAt(0) >= "0".charCodeAt(0) && c.charCodeAt(0) <= "9".charCodeAt(0);
    }

    private isAlpha(c: string): boolean {
        return (
            (c.charCodeAt(0) >= "a".charCodeAt(0) && c.charCodeAt(0) <= "z".charCodeAt(0)) ||
            (c.charCodeAt(0) >= "A".charCodeAt(0) && c.charCodeAt(0) <= "Z".charCodeAt(0)) ||
            c === "_"
        );
    }

    private isAlphaNumeric(c: string): boolean {
        return this.isAlpha(c) || this.isDigit(c);
    }

    // Handles both plain strings and ${...}/$$ interpolation, matching glox's
    // scanner exactly (see ../../../src/compiler/scanner.go's `string`): a
    // string with interpolation is desugared here, at scan time, into a
    // synthetic token stream `( lit1 & str( <expr tokens> ) & lit2 & ... )` so
    // the parser never needs to know interpolation exists. `which` is the
    // opening/closing delimiter, `"` or `'`.
    private *string(which: string): Generator<Token> {
        let lit = "";
        let hadEscape = false;
        let hasInterp = false;
        const segments: InterpSegment[] = [];

        while (this.peek() !== which && !this.isAtEnd()) {
            const c = this.peek();
            if (c === "$" && this.peekNext() === "$") {
                hadEscape = true;
                this.advance();
                this.advance();
                lit += "$";
                continue;
            }
            if (c === "$" && this.peekNext() === "{") {
                hasInterp = true;
                segments.push({ isExpr: false, text: lit });
                lit = "";
                this.advance(); // $
                this.advance(); // {
                const exprStart = this.current;
                const exprSrc = this.scanInterpExpr();
                if (exprSrc === null) {
                    this.errorReporter.error(
                        { line: this.line, start: this.current, end: this.current + 1 },
                        "Unterminated interpolation."
                    );
                    return;
                }
                if (exprSrc.trim() === "") {
                    this.errorReporter.error(
                        { line: this.line, start: this.current, end: this.current + 1 },
                        "Empty interpolation expression."
                    );
                    return;
                }
                segments.push({ isExpr: true, toks: this.scanInterpTokens(exprSrc, exprStart) });
                continue;
            }
            if (c === "\n") {
                this.line++;
                this.character = 0;
            }
            lit += c;
            this.advance();
        }

        if (this.isAtEnd()) {
            this.errorReporter.error(
                {
                    line: this.line,
                    start: this.current,
                    end: this.current + 1,
                },
                "Unterminated string."
            );
            return;
        }

        // The closing quote
        this.advance();

        if (!hasInterp) {
            if (!hadEscape) {
                // Fast path: no interpolation and no escapes -- keep the exact
                // original lexeme/position.
                const value = this.source.substring(this.start + 1, this.current - 1);
                yield this.makeToken("STRING", value);
            } else {
                yield this.makeToken("STRING", lit);
            }
            return;
        }

        segments.push({ isExpr: false, text: lit });

        const out: Token[] = [this.synthToken("LEFT_PAREN", "(")];
        let first = true;
        const amp = () => {
            if (!first) {
                out.push(this.synthToken("AMPERSAND", "&"));
            }
            first = false;
        };
        for (const seg of segments) {
            if (seg.isExpr) {
                amp();
                out.push(this.synthToken("STR", "str"), this.synthToken("LEFT_PAREN", "("));
                out.push(...seg.toks!);
                out.push(this.synthToken("RIGHT_PAREN", ")"));
            } else if (seg.text) {
                amp();
                out.push(this.synthStringToken(seg.text));
            }
        }
        out.push(this.synthToken("RIGHT_PAREN", ")"));

        for (const t of out) {
            yield t;
        }
    }

    // Consumes source from just after "${" through the matching "}" (tracking
    // brace depth and skipping nested string literals so their braces/quotes
    // don't interfere), returning the expression source between the braces, or
    // null if the string/EOF ends first.
    private scanInterpExpr(): string | null {
        const start = this.current;
        let depth = 1;
        while (!this.isAtEnd()) {
            const c = this.peek();
            if (c === '"' || c === "'") {
                this.advance(); // opening quote
                while (!this.isAtEnd() && this.peek() !== c) {
                    if (this.peek() === "\n") {
                        this.line++;
                        this.character = 0;
                    }
                    this.advance();
                }
                if (this.isAtEnd()) {
                    return null;
                }
                this.advance(); // closing quote
                continue;
            }
            if (c === "{") {
                depth++;
                this.advance();
                continue;
            }
            if (c === "}") {
                depth--;
                if (depth === 0) {
                    const expr = this.source.substring(start, this.current);
                    this.advance(); // consume closing }
                    return expr;
                }
                this.advance();
                continue;
            }
            if (c === "\n") {
                this.line++;
                this.character = 0;
            }
            this.advance();
        }
        return null;
    }

    // Tokenises an interpolated expression's source with a fresh sub-scanner,
    // strips the trailing EOL/EOF, and shifts every token's start/end back into
    // absolute offsets in the ORIGINAL source (baseOffset is where exprSrc
    // began) -- getting this wrong would silently break hover/go-to-def/rename
    // for anything written inside ${...}.
    private scanInterpTokens(exprSrc: string, baseOffset: number): Token[] {
        const sub = new Scanner(exprSrc, this.errorReporter);
        const toks = [...sub.scanTokens()];
        while (toks.length > 0 && (toks[toks.length - 1].type === "EOF" || toks[toks.length - 1].type === "EOL")) {
            toks.pop();
        }
        return toks.map(
            (t) => new Token(t.type, t.lexeme, t.literal, this.line, this.character, t.start + baseOffset, t.end + baseOffset)
        );
    }

    private synthToken(type: TokenType, lexeme: string): Token {
        return new Token(type, lexeme, undefined, this.line, this.character, this.current, this.current);
    }

    private synthStringToken(content: string): Token {
        return new Token("STRING", `${content}`, content, this.line, this.character, this.current, this.current);
    }

    private *identifier(): Generator<Token> {
        while (this.isAlphaNumeric(this.peek())) {
            this.advance();
        }

        const text = this.source.substring(this.start, this.current);
        yield this.makeToken(keywords.get(text) ?? "IDENTIFIER");
    }

    private *number(): Generator<Token> {
        while (this.isDigit(this.peek())) {
            this.advance();
        }

        if (this.peek() === "." && this.isDigit(this.peekNext())) {
            this.advance();

            while (this.isDigit(this.peek())) {
                this.advance();
            }

            yield this.makeToken("FLOAT", parseFloat(this.source.substring(this.start, this.current)));
            return;
        }

        yield this.makeToken("INT", parseInt(this.source.substring(this.start, this.current), 10));
    }

    private makeToken(type: TokenType, literal?: string | number | boolean): Token {
        const text = this.source.substring(this.start, this.current);
        return new Token(type, text, literal, this.line, this.character, this.start, this.current);
    }
}
