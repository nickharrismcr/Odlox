// Tracks a LoxDocument per file the server has ever needed to look at --
// not just documents open in an editor tab, which is all LoxLspServer knew
// about before this. Two kinds of entry:
//
//   - "open" documents: content comes from the live TextDocuments buffer
//     (unsaved edits win), kept current by LoxLspServer.onDidChangeContent.
//   - "disk" documents: content is read from the filesystem the first time
//     something imports them, cached, and only re-read when the file's
//     mtime changes.
//
// This is what makes `from module import name` resolvable at all when
// `module` isn't open in the editor -- resolveImport() is what Resolver
// (via LoxDocument) calls to look up another file's exports.
//
// Keyed by a case-normalized absolute fs path (not the raw URI string) so
// an open document and the same file reached via a resolved import path
// always land on one entry regardless of how each URI was cased/escaped.

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath, pathToFileURL } from "url";
import { TextDocument } from "vscode-languageserver-textdocument";
import { LoxDocument, ResolvedModule } from "./LoxDocument";
import { findAllLoxFiles, resolveModulePath } from "./ModuleResolver";

interface Entry {
    uri: string;
    document: LoxDocument;
    open: boolean;
    // Only meaningful for disk entries -- mtime at last read, used to decide
    // whether a cached analysis is still current.
    mtimeMs?: number;
}

function keyFor(fsPath: string): string {
    const resolved = path.resolve(fsPath);
    // Windows fs paths are case-insensitive; normalize so "D:\..." and
    // "d:\..." (as URI-derived paths sometimes differ) hit the same entry.
    return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

// Local-file URIs only -- an untitled buffer or other non-file scheme has
// nothing on disk to key by, so it's simply not indexable for cross-file
// lookups (same as it not existing).
function uriToFsPath(uri: string): string | undefined {
    try {
        const parsed = new URL(uri);
        if (parsed.protocol !== "file:") {
            return undefined;
        }
        return fileURLToPath(uri);
    } catch {
        return undefined;
    }
}

// Exported so callers outside this file (LoxLspServer, comparing a
// client-supplied URI against a URI this index minted via
// pathToFileURL/resolveImport) can tell whether two URI strings name the
// same file without relying on them being byte-identical -- URIs for the
// same path can legitimately differ in drive-letter casing/escaping
// depending on where they came from.
export function fileKey(uri: string): string | undefined {
    const fsPath = uriToFsPath(uri);
    return fsPath && keyFor(fsPath);
}

export class WorkspaceIndex {
    private entries: Map<string, Entry> = new Map();
    // Paths currently mid-analyze, to break circular imports (A imports B,
    // B imports A) instead of recursing forever.
    private analyzing: Set<string> = new Set();

    // Mirrors the `lox.diagnostics.reportUnusedVariables` VS Code setting
    // (LoxLspServer pulls it and calls setReportUnusedVariables()). Applied
    // to every analyze() call, open or disk -- disk documents' diagnostics
    // are never surfaced anyway (only an open document's are published), so
    // this only actually changes what the user sees, but keeping one flag
    // for both avoids two analyze() code paths disagreeing with each other.
    private reportUnusedVariables = true;

    constructor(private workspaceRoot?: string) {}

    setWorkspaceRoot(workspaceRoot: string | undefined) {
        this.workspaceRoot = workspaceRoot;
    }

    setReportUnusedVariables(value: boolean) {
        this.reportUnusedVariables = value;
    }

    // Registers/updates the LoxDocument backing an open editor buffer and
    // (re)analyzes it, wiring resolveImport so its own imports can reach
    // into the rest of the workspace. Returns the analyzed document.
    analyzeOpen(uri: string, document: TextDocument): LoxDocument {
        const loxDocument = new LoxDocument(document);
        const fsPath = uriToFsPath(uri);
        if (fsPath) {
            this.entries.set(keyFor(fsPath), { uri, document: loxDocument, open: true });
        }
        loxDocument.analyze((moduleName) => this.resolveImport(moduleName, uri), this.reportUnusedVariables);
        return loxDocument;
    }

    // Called when an editor tab closes: the file is no longer guaranteed to
    // match what's on disk-less "open" wins, so drop the cached entry and
    // let the next resolveImport() that needs it re-read from disk.
    close(uri: string) {
        const fsPath = uriToFsPath(uri);
        if (fsPath) {
            this.entries.delete(keyFor(fsPath));
        }
    }

    // All documents this index currently has an analysis for -- open tabs
    // plus every disk module reached via an import so far, plus (once
    // scanWorkspace() has run) every .lox file under the workspace root.
    allDocuments(): Array<{ uri: string; document: LoxDocument }> {
        return [...this.entries.values()].map((e) => ({ uri: e.uri, document: e.document }));
    }

    // resolveImport() only discovers documents by following import edges
    // forward (importer -> imported); a declaration's own file never learns
    // about its importers that way. Cross-file find-references/rename need
    // the reverse direction, so before searching, they call this to analyze
    // every `.lox` file under the workspace root -- not just ones reached
    // via an open document's imports. Cheap on repeat calls: each file is
    // still mtime-cached by getOrAnalyzeFromDisk, so this only re-parses
    // files that changed since the last scan.
    scanWorkspace() {
        if (!this.workspaceRoot) {
            return;
        }
        for (const filePath of findAllLoxFiles(this.workspaceRoot)) {
            const uri = pathToFileURL(filePath).toString();
            this.getOrAnalyzeFromDisk(uri, filePath);
        }
    }

    // Fetches (analyzing from disk if necessary) the document for an
    // arbitrary URI -- used by the LSP layer to load the target document a
    // cross-file link points at, once it already has the URI in hand (e.g.
    // from ModuleReference.uri) rather than a module name to resolve.
    getDocument(uri: string): LoxDocument | undefined {
        const fsPath = uriToFsPath(uri);
        if (!fsPath) {
            return undefined;
        }
        return this.getOrAnalyzeFromDisk(uri, fsPath);
    }

    resolveImport(moduleName: string, fromUri: string): ResolvedModule | undefined {
        const fromPath = uriToFsPath(fromUri);
        if (!fromPath) {
            return undefined;
        }

        const modulePath = resolveModulePath(moduleName, fromPath, this.workspaceRoot);
        if (!modulePath) {
            return undefined;
        }

        const moduleUri = pathToFileURL(modulePath).toString();
        const document = this.getOrAnalyzeFromDisk(moduleUri, modulePath);
        return document && { uri: moduleUri, exports: document.exports };
    }

    private getOrAnalyzeFromDisk(uri: string, fsPath: string): LoxDocument | undefined {
        const key = keyFor(fsPath);

        const existing = this.entries.get(key);
        if (existing?.open) {
            return existing.document;
        }

        if (this.analyzing.has(key)) {
            // Circular import: return whatever's cached so far (possibly
            // nothing yet) rather than recursing.
            return existing?.document;
        }

        let mtimeMs: number;
        try {
            mtimeMs = fs.statSync(fsPath).mtimeMs;
        } catch {
            return undefined;
        }

        if (existing && existing.mtimeMs === mtimeMs) {
            return existing.document;
        }

        let content: string;
        try {
            content = fs.readFileSync(fsPath, "utf8");
        } catch {
            return undefined;
        }

        const textDocument = TextDocument.create(uri, "lox", 0, content);
        const loxDocument = new LoxDocument(textDocument);
        this.entries.set(key, { uri, document: loxDocument, open: false, mtimeMs });

        this.analyzing.add(key);
        try {
            loxDocument.analyze(
                (importedModuleName) => this.resolveImport(importedModuleName, uri),
                this.reportUnusedVariables
            );
        } finally {
            this.analyzing.delete(key);
        }

        return loxDocument;
    }
}
