import { Parser } from "./Parser";
import * as assert from "assert";
import { Scanner } from "./Scanner";
import { PrettyPrinter } from "./PrettyPrinter";
import { RuntimeError, TokenPosition } from "./Error";

describe("Parser", () => {
    it("should be able to parse a single expression", () => {
        const parser = new Parser(new Scanner("1 + 2").scanTokens(), {
            error: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Error: ${message}`);
            },
            warn: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Warning: ${message}`);
            },
            runtimeError: (error: RuntimeError) => {
                assert.fail(error.message);
            },
        });
        const program = parser.parseExpression();

        assert.ok(program !== null);
        const pretty = program.visit(new PrettyPrinter());

        assert.equal(pretty, "(+ 1 2)");
    });

    it("should be able to parse a single expression with grouping", () => {
        const parser = new Parser(new Scanner("(1 + 2 * 6) - 13").scanTokens(), {
            error: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Error: ${message}`);
            },
            warn: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Warning: ${message}`);
            },
            runtimeError: (error: RuntimeError) => {
                assert.fail(error.message);
            },
        });
        const program = parser.parseExpression();

        assert.ok(program !== null);
        const pretty = program.visit(new PrettyPrinter());

        assert.equal(pretty, "(- ((+ 1 (* 2 6))) 13)");
    });

    it("should be able to parse multiple statement expressions", () => {
        const parser = new Parser(new Scanner("1 + 2; 3 * 4;").scanTokens(), {
            error: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Error: ${message}`);
            },
            warn: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Warning: ${message}`);
            },
            runtimeError: (error: RuntimeError) => {
                assert.fail(error.message);
            },
        });
        const program = parser.parse();

        assert.ok(program !== null);
        const pretty = program.map((stmt) => stmt.visit(new PrettyPrinter()));

        assert.deepEqual(pretty, ["(+ 1 2)", "(* 3 4)"]);
    });

    it("should parse variable declarations", () => {
        const parser = new Parser(new Scanner("var a = 1; print a;").scanTokens(), {
            error: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Error: ${message}`);
            },
            warn: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Warning: ${message}`);
            },
            runtimeError: (error: RuntimeError) => {
                assert.fail(error.message);
            },
        });
        const program = parser.parse();

        assert.ok(program !== null);
        const pretty = program.map((stmt) => stmt.visit(new PrettyPrinter()));

        assert.deepEqual(pretty, ["(var a 1)", "(print a)"]);
    });

    it("should parse class variables alongside static methods", () => {
        // `static name = expr` (no parens) is a class variable; `static
        // name(...)` (parens) is a static method -- disambiguated by
        // lookahead past the identifier.
        const parser = new Parser(
            new Scanner("class Foo { static square(x) { return x * x; } static count = 0; }").scanTokens(),
            {
                error: (token: TokenPosition, message: string) => {
                    assert.fail(`[line ${token.line}] Error: ${message}`);
                },
                warn: (token: TokenPosition, message: string) => {
                    assert.fail(`[line ${token.line}] Warning: ${message}`);
                },
                runtimeError: (error: RuntimeError) => {
                    assert.fail(error.message);
                },
            }
        );
        const program = parser.parse();

        assert.ok(program !== null);
        const pretty = program.map((stmt) => stmt.visit(new PrettyPrinter()));

        assert.deepEqual(pretty, ["(class Foo (fun square (x) ((return (* x x)))) (static count 0))"]);
    });

    // Optional type annotations, Phase 1 (grammar surface): annotations at
    // all three sites (param, var decl, return type), plus generic and
    // nilable forms, parse without error and are silently ignored --
    // PrettyPrinter renders them (mirroring surface syntax) purely so this
    // test can assert they actually attached, not to imply anything
    // downstream consults them yet.
    it("should parse type annotations at all three sites without error", () => {
        const parser = new Parser(
            new Scanner("var a: int = 1\nfunc add(x: int, y: List[int] = [1]) -> string? { return x }").scanTokens(),
            {
                error: (token: TokenPosition, message: string) => {
                    assert.fail(`[line ${token.line}] Error: ${message}`);
                },
                warn: (token: TokenPosition, message: string) => {
                    assert.fail(`[line ${token.line}] Warning: ${message}`);
                },
                runtimeError: (error: RuntimeError) => {
                    assert.fail(error.message);
                },
            }
        );
        const program = parser.parse();

        assert.ok(program !== null);
        const pretty = program.map((stmt) => stmt.visit(new PrettyPrinter()));

        assert.deepEqual(pretty, ["(var a:int 1)", "(fun add (x:int y:List[int]=(list 1)) ->string? ((return x)))"]);
    });

    it("should parse a nilable var decl with no initializer as its own complete statement", () => {
        // Regression test, at the parser level, for the same EOL-suppression
        // bug Scanner.test.ts's "should keep the EOL..." test covers: a
        // nilable annotation ending a var decl (no initializer) must
        // terminate before the next statement, not swallow it.
        const parser = new Parser(new Scanner("var c: string?\nvar d = 1").scanTokens(), {
            error: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Error: ${message}`);
            },
            warn: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Warning: ${message}`);
            },
            runtimeError: (error: RuntimeError) => {
                assert.fail(error.message);
            },
        });
        const program = parser.parse();

        assert.ok(program !== null);
        assert.equal(program.length, 2, "expected two separate statements");
        const pretty = program.map((stmt) => stmt.visit(new PrettyPrinter()));
        assert.deepEqual(pretty, ["(var c:string? nil)", "(var d 1)"]);
    });

    it("should default a class variable with no initializer to nil", () => {
        const parser = new Parser(new Scanner("class Foo { static label; }").scanTokens(), {
            error: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Error: ${message}`);
            },
            warn: (token: TokenPosition, message: string) => {
                assert.fail(`[line ${token.line}] Warning: ${message}`);
            },
            runtimeError: (error: RuntimeError) => {
                assert.fail(error.message);
            },
        });
        const program = parser.parse();

        assert.ok(program !== null);
        const pretty = program.map((stmt) => stmt.visit(new PrettyPrinter()));

        assert.deepEqual(pretty, ["(class Foo (static label nil))"]);
    });
});
