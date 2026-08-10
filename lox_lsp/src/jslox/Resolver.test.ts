import * as assert from "assert";
import { Parser } from "./Parser";
import { Scanner } from "./Scanner";
import { Resolver } from "./Resolver";
import { TokenPosition } from "./Error";

describe("Resolver", () => {
    it("should resolve local variables", () => {
        const parser = new Parser(new Scanner("var a; print a;").scanTokens());
        const program = parser.parse();

        assert.ok(program !== null);
        const resolver = new Resolver();
        resolver.resolve(program);

        assert.equal([...resolver.references.entries()].length, 1);
        assert.equal([...resolver.definitions.entries()].length, 1);

        for (const [reference, definition] of resolver.references) {
            assert.equal(reference.lexeme, "a");
            assert.equal(definition.lexeme, "a");

            assert.ok(resolver.definitions.has(definition));
        }
    });

    it("should give an error on re-defined local variables", () => {
        // Redeclaring a *local* is an error; redeclaring a *global* is legal
        // in glox (matches declareVariable() in src/compiler/compile.go,
        // which only checks locals -- e.g. re-importing an already-imported
        // module, or a script re-declaring the same top-level global, are
        // both valid glox), so this needs a block to actually be local.
        const parser = new Parser(new Scanner("{ var a; var a; }").scanTokens());
        const program = parser.parse();

        assert.ok(program !== null);

        let called = false;
        const resolver = new Resolver({
            error: (token: TokenPosition, message: string) => {
                called = true;
                assert.equal(message, "Variable with this name already declared in this scope.");
            },
            warn: () => {},
            runtimeError: () => {},
        });
        resolver.resolve(program);
        assert.ok(called);
    });

    it("should allow re-defined global variables", () => {
        const parser = new Parser(new Scanner("var a; var a;").scanTokens());
        const program = parser.parse();

        assert.ok(program !== null);

        let called = false;
        const resolver = new Resolver({
            error: () => {
                called = true;
            },
            warn: () => {},
            runtimeError: () => {},
        });
        resolver.resolve(program);
        assert.ok(!called);
    });

    it("should give an error on top level return", () => {
        const parser = new Parser(new Scanner("return 12;").scanTokens());
        const program = parser.parse();

        assert.ok(program !== null);

        let called = false;
        const resolver = new Resolver({
            error: (token: TokenPosition, message: string) => {
                called = true;
                assert.equal(message, "Cannot return from top-level code.");
            },
            warn: () => {},
            runtimeError: () => {},
        });
        resolver.resolve(program);
        assert.ok(called);
    });

    it("should give an error on top level break", () => {
        const parser = new Parser(new Scanner("break;").scanTokens());
        const program = parser.parse();

        assert.ok(program !== null);

        let called = false;
        const resolver = new Resolver({
            error: (token: TokenPosition, message: string) => {
                called = true;
                assert.equal(message, "Cannot break from top-level code.");
            },
            warn: () => {},
            runtimeError: () => {},
        });
        resolver.resolve(program);
        assert.ok(called);
    });

    it("should not report errors or warnings for class variable declarations", () => {
        const parser = new Parser(
            new Scanner("class Foo { static count = 0; init() { Foo.count = Foo.count + 1; } }").scanTokens()
        );
        const program = parser.parse();

        assert.ok(program !== null);

        let called = false;
        const resolver = new Resolver({
            error: () => {
                called = true;
            },
            warn: () => {
                called = true;
            },
            runtimeError: () => {},
        });
        resolver.resolve(program);
        assert.ok(!called);
    });

    it("should give a warning if a local variable is never used", () => {
        // Only *local* unused variables are flagged -- see isGlobalDefinition
        // in Resolver.ts for why globals are exempt (the Resolver only ever
        // sees one file, so a global used only from another module that
        // imports this one would otherwise be a false positive).
        const parser = new Parser(new Scanner("{ var a; }").scanTokens());
        const program = parser.parse();

        assert.ok(program !== null);

        let called = false;
        const resolver = new Resolver({
            error: () => {},
            warn: (token: TokenPosition, message: string) => {
                called = true;
                assert.equal(message, "Variable 'a' is declared but never used.");
            },
            runtimeError: () => {},
        });
        resolver.resolve(program);
        assert.ok(called);
    });

    it("should not warn about unused variables when reportUnusedVariables is false", () => {
        const parser = new Parser(new Scanner("{ var a; }").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        let called = false;
        const resolver = new Resolver(
            { error: () => {}, warn: () => (called = true), runtimeError: () => {} },
            undefined,
            false
        );
        resolver.resolve(program);
        assert.ok(!called);
    });

    it("should record every module-scope binding in exports", () => {
        const parser = new Parser(new Scanner("func greet() {} var count = 1; { var local = 2; }").scanTokens());
        const program = parser.parse();

        assert.ok(program !== null);
        const resolver = new Resolver();
        resolver.resolve(program);

        assert.deepEqual([...resolver.exports.keys()].sort(), ["count", "greet"]);
    });

    it("should link a named `from module import x` to the real declaration via resolveImport", () => {
        const parser = new Parser(new Scanner("from other import greet; greet();").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        const otherModuleParser = new Parser(new Scanner("func greet() {}").scanTokens());
        const otherProgram = otherModuleParser.parse();
        assert.ok(otherProgram !== null);
        const otherResolver = new Resolver();
        otherResolver.resolve(otherProgram);

        const resolver = new Resolver(undefined, (moduleName) => {
            assert.equal(moduleName, "other");
            return otherResolver.exports;
        });
        resolver.resolve(program);

        // The call site resolves cross-module, not locally.
        assert.equal(resolver.references.size, 0);
        assert.equal(resolver.moduleReferences.size, 1);

        const [[reference, link]] = [...resolver.moduleReferences.entries()];
        assert.equal(reference.lexeme, "greet");
        assert.equal(link.moduleName, "other");
        assert.equal(link.token, otherResolver.exports.get("greet"));
    });

    it("should link every name from `from module import *` to the module's exports", () => {
        const parser = new Parser(new Scanner("from other import *; greet(); helper();").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        const otherModuleParser = new Parser(new Scanner("func greet() {} func helper() {}").scanTokens());
        const otherProgram = otherModuleParser.parse();
        assert.ok(otherProgram !== null);
        const otherResolver = new Resolver();
        otherResolver.resolve(otherProgram);

        const resolver = new Resolver(undefined, () => otherResolver.exports);
        resolver.resolve(program);

        assert.equal(resolver.moduleReferences.size, 2);
        const names = [...resolver.moduleReferences.keys()].map((t) => t.lexeme).sort();
        assert.deepEqual(names, ["greet", "helper"]);
    });

    it("should not misdeclare an assignment to a star-imported name as a new global", () => {
        // A bare `name = expr` at global scope implicitly declares `name` if
        // it isn't visible anywhere yet (see visitAssign). A star-imported
        // name must count as visible so this doesn't shadow the real import.
        const parser = new Parser(new Scanner("from other import *; greet = 1;").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        const otherModuleParser = new Parser(new Scanner("var greet = 0;").scanTokens());
        const otherProgram = otherModuleParser.parse();
        assert.ok(otherProgram !== null);
        const otherResolver = new Resolver();
        otherResolver.resolve(otherProgram);

        const resolver = new Resolver(undefined, () => otherResolver.exports);
        resolver.resolve(program);

        assert.equal(resolver.exports.has("greet"), false);
        assert.equal(resolver.moduleReferences.size, 1);
    });

    it("should link `import module; module.name` (namespace-style access) to the real declaration", () => {
        // The `import x` (as opposed to `from x import y`) style: `config`
        // is bound as a plain local, and `config.Config` is a Get on it.
        // Unlike an arbitrary object's property, a module namespace's
        // properties are exactly its exports, so this should resolve
        // statically the same way a named import would.
        const parser = new Parser(new Scanner("import config; config.Config();").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        const configModuleParser = new Parser(new Scanner("class Config {}").scanTokens());
        const configProgram = configModuleParser.parse();
        assert.ok(configProgram !== null);
        const configResolver = new Resolver();
        configResolver.resolve(configProgram);

        const resolver = new Resolver(undefined, (moduleName) => {
            assert.equal(moduleName, "config");
            return configResolver.exports;
        });
        resolver.resolve(program);

        assert.equal(resolver.moduleReferences.size, 1);
        const [[reference, link]] = [...resolver.moduleReferences.entries()];
        assert.equal(reference.lexeme, "Config");
        assert.equal(link.moduleName, "config");
        assert.equal(link.token, configResolver.exports.get("Config"));
    });

    it("resolves `module.name` through an aliased `import module as alias`", () => {
        const parser = new Parser(new Scanner("import config as cfg; cfg.Config();").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        const configModuleParser = new Parser(new Scanner("class Config {}").scanTokens());
        const configProgram = configModuleParser.parse();
        assert.ok(configProgram !== null);
        const configResolver = new Resolver();
        configResolver.resolve(configProgram);

        const resolver = new Resolver(undefined, () => configResolver.exports);
        resolver.resolve(program);

        assert.equal(resolver.moduleReferences.size, 1);
        const [[, link]] = [...resolver.moduleReferences.entries()];
        assert.equal(link.token, configResolver.exports.get("Config"));
    });

    it("does not treat an ordinary object's property access as module-namespace-resolvable", () => {
        const parser = new Parser(new Scanner("class Foo { bar() {} } var f = Foo(); f.bar();").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        const resolver = new Resolver(undefined, () => {
            throw new Error("resolveImport should not be called for a non-module variable");
        });
        resolver.resolve(program);

        assert.equal(resolver.moduleReferences.size, 0);
    });

    it("should still declare imports locally when the module can't be resolved", () => {
        const parser = new Parser(new Scanner("from missing import thing; thing();").scanTokens());
        const program = parser.parse();
        assert.ok(program !== null);

        const resolver = new Resolver(undefined, () => undefined);
        resolver.resolve(program);

        assert.equal(resolver.moduleReferences.size, 0);
        assert.equal(resolver.references.size, 1);
    });
});
