import * as assert from "assert";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { pathToFileURL } from "url";
import { TextDocument } from "vscode-languageserver-textdocument";
import { WorkspaceIndex } from "./WorkspaceIndex";

// End-to-end coverage for the piece that makes cross-module go-to-definition
// possible at all: resolving `from <module> import <name>` against a real
// file on disk that isn't open in any editor, through the same
// WorkspaceIndex/LoxDocument/Resolver path the LSP server uses.
describe("WorkspaceIndex", () => {
    let root: string;

    beforeEach(() => {
        root = fs.mkdtempSync(path.join(os.tmpdir(), "lox-lsp-workspace-"));
    });

    afterEach(() => {
        fs.rmSync(root, { recursive: true, force: true });
    });

    function writeFile(relativePath: string, content: string): string {
        const fullPath = path.join(root, relativePath);
        fs.mkdirSync(path.dirname(fullPath), { recursive: true });
        fs.writeFileSync(fullPath, content);
        return fullPath;
    }

    function openDocument(index: WorkspaceIndex, fullPath: string, content: string) {
        const uri = pathToFileURL(fullPath).toString();
        const document = TextDocument.create(uri, "lox", 1, content);
        return { uri, loxDocument: index.analyzeOpen(uri, document) };
    }

    it("resolves `from module import name` to the module's real declaration on disk", () => {
        const modulePath = writeFile(path.join("modules", "mathutil.lox"), "func square(x) {\n    return x * x;\n}\n");
        writeFile("main.lox", "from mathutil import square;\nsquare(2);\n");

        const index = new WorkspaceIndex(root);
        const { loxDocument } = openDocument(
            index,
            path.join(root, "main.lox"),
            "from mathutil import square;\nsquare(2);\n"
        );

        assert.equal(loxDocument.hadError, false);
        assert.equal(loxDocument.moduleReferences.size, 1); // the `square(2)` call site

        const expectedModuleUri = pathToFileURL(modulePath).toString();
        for (const [reference, link] of loxDocument.moduleReferences) {
            assert.equal(reference.lexeme, "square");
            assert.equal(link.uri, expectedModuleUri);
        }

        const moduleDocument = index.getDocument(expectedModuleUri);
        assert.ok(moduleDocument);
        const [, someLink] = [...loxDocument.moduleReferences.entries()][0];
        assert.equal(someLink.token.lexeme, "square");
        assert.ok(moduleDocument!.exports.has("square"));
        assert.equal(moduleDocument!.exports.get("square"), someLink.token);
    });

    it("resolves `import module; module.name()` (namespace-style access) same as a named import", () => {
        // Mirrors lox_examples/defender: config.lox declares `class Config`,
        // main.lox does `import config` then calls `config.Config()` --
        // no `from ... import` anywhere. This is the more common import
        // style in odlox's own .lox codebase, and unlike a named import,
        // there's no reference token at the import statement itself to
        // link -- the link only exists at each `config.Config` access.
        const configPath = writeFile(path.join("modules", "config.lox"), "class Config {\n    init() {}\n}\n");
        const source = "import config\ncfg = config.Config()\n";
        const mainPath = writeFile("main.lox", source);

        const index = new WorkspaceIndex(root);
        const { loxDocument } = openDocument(index, mainPath, source);

        assert.equal(loxDocument.hadError, false);
        assert.equal(loxDocument.moduleReferences.size, 1);

        const [[reference, link]] = [...loxDocument.moduleReferences.entries()];
        assert.equal(reference.lexeme, "Config");
        assert.equal(link.uri, pathToFileURL(configPath).toString());

        const configDocument = index.getDocument(link.uri);
        assert.equal(link.token, configDocument!.exports.get("Config"));
    });

    it("prefers <workspaceRoot>/modules/<name>.lox over a same-named file alongside the importer", () => {
        writeFile(path.join("modules", "shared.lox"), 'var which = "modules-dir";\n');
        writeFile("shared.lox", 'var which = "alongside";\n');
        const source = "from shared import which;\nwhich;\n";
        const mainPath = writeFile("main.lox", source);

        const index = new WorkspaceIndex(root);
        const { loxDocument } = openDocument(index, mainPath, source);

        const [[, link]] = [...loxDocument.moduleReferences.entries()];
        const resolvedSource = fs.readFileSync(path.join(root, "modules", "shared.lox"), "utf8");
        assert.ok(resolvedSource.includes("modules-dir"));
        assert.equal(link.uri, pathToFileURL(path.join(root, "modules", "shared.lox")).toString());
    });

    it("falls back to a file alongside the importer when nothing matches under modules/", () => {
        const modulePath = writeFile("helper.lox", "func assist() {}\n");
        const mainPath = writeFile("main.lox", "from helper import assist;\nassist();\n");

        const index = new WorkspaceIndex(root);
        const { loxDocument } = openDocument(index, mainPath, "from helper import assist;\nassist();\n");

        assert.equal(loxDocument.moduleReferences.size, 1);
        const [[, link]] = [...loxDocument.moduleReferences.entries()];
        assert.equal(link.uri, pathToFileURL(modulePath).toString());
    });

    it("re-reads a disk module after it changes on disk (mtime-invalidated cache)", () => {
        const modulePath = writeFile(path.join("modules", "counter.lox"), "func first() {}\n");
        const source = "from counter import first;\nfirst();\n";
        const mainPath = writeFile("main.lox", source);

        const index = new WorkspaceIndex(root);

        const firstOpen = openDocument(index, mainPath, source);
        assert.equal(firstOpen.loxDocument.moduleReferences.size, 1);

        // Bump mtime forward so the cache treats this as a real change even
        // on filesystems with coarse mtime resolution.
        fs.writeFileSync(modulePath, "func first() {}\nfunc second() {}\n");
        const bumped = new Date(Date.now() + 5000);
        fs.utimesSync(modulePath, bumped, bumped);

        const moduleUri = pathToFileURL(modulePath).toString();
        const reloaded = index.getDocument(moduleUri);
        assert.ok(reloaded!.exports.has("second"));
    });

    it("declares imported names locally (without a cross-module link) when the module can't be found", () => {
        const mainPath = writeFile("main.lox", "from nowhere import thing;\nthing();\n");

        const index = new WorkspaceIndex(root);
        const { loxDocument } = openDocument(index, mainPath, "from nowhere import thing;\nthing();\n");

        assert.equal(loxDocument.moduleReferences.size, 0);
        assert.equal(loxDocument.references.size, 1);
    });

    it("scanWorkspace() discovers importers that were never opened, so find-references can reach them", () => {
        // Opening only the file a class is *declared* in (the common "find
        // all references" starting point) never triggers resolveImport
        // for any of its importers -- imports are only discovered by
        // following them forward from something already open. Regression
        // test for that gap.
        const configPath = writeFile(path.join("modules", "config.lox"), "class Config {\n    init() {}\n}\n");
        const usagePath = writeFile("game.lox", "from config import Config;\nConfig();\n");

        const index = new WorkspaceIndex(root);
        const { loxDocument: configDocument } = openDocument(index, configPath, fs.readFileSync(configPath, "utf8"));

        // Before scanning, game.lox has never been touched.
        assert.equal(
            index.allDocuments().some((d) => d.uri === pathToFileURL(usagePath).toString()),
            false
        );

        index.scanWorkspace();

        const gameEntry = index.allDocuments().find((d) => d.uri === pathToFileURL(usagePath).toString());
        assert.ok(gameEntry);
        assert.equal(gameEntry!.document.moduleReferences.size, 1);

        const [[, link]] = [...gameEntry!.document.moduleReferences.entries()];
        assert.equal(link.uri, pathToFileURL(configPath).toString());
        assert.equal(link.token, configDocument.exports.get("Config"));
    });
});
