import {
    Definition,
    DefinitionLink,
    DocumentHighlight,
    DocumentHighlightKind,
    DocumentSymbol,
    HandlerResult,
    Location,
    Position,
    PublishDiagnosticsParams,
    Range,
    SemanticTokens,
    SemanticTokensBuilder,
    SymbolInformation,
    TextDocuments,
    TextEdit,
    WorkspaceEdit,
} from "vscode-languageserver";
import { TextDocument } from "vscode-languageserver-textdocument";
import { Token } from "../jslox/Token";
import { TOKEN_TO_ID } from "./SemanticTokenAnalyzer";
import { LoxDocument } from "./LoxDocument";
import { WorkspaceIndex, fileKey } from "./WorkspaceIndex";

type LspEventListner = ((type: "diagnostics", params: PublishDiagnosticsParams) => void) &
    ((type: "foo", params: any) => void);

function rangeOf(document: TextDocument, token: Token): Range {
    return {
        start: document.positionAt(token.start),
        end: document.positionAt(token.end),
    };
}

export class LoxLspServer {
    // Open editor tabs only -- kept for the common case (every request the
    // client sends carries the URI of a document it has open). Documents
    // reached only via an import (not open anywhere) live in workspaceIndex
    // but not here.
    loxDocuments: Map<string, LoxDocument> = new Map();
    private workspaceIndex: WorkspaceIndex;

    constructor(
        private documents: TextDocuments<TextDocument>,
        private listener: LspEventListner,
        workspaceRoot?: string
    ) {
        this.workspaceIndex = new WorkspaceIndex(workspaceRoot);

        this.documents.onDidChangeContent((change) => {
            this.onDidChangeContent(change.document.uri);
        });

        this.documents.onDidClose((event) => {
            this.loxDocuments.delete(event.document.uri);
            this.workspaceIndex.close(event.document.uri);
        });
    }

    setWorkspaceRoot(workspaceRoot: string | undefined) {
        this.workspaceIndex.setWorkspaceRoot(workspaceRoot);
    }

    setReportUnusedVariables(value: boolean) {
        this.workspaceIndex.setReportUnusedVariables(value);
    }

    // Re-analyzes every currently-open document and republishes its
    // diagnostics -- called after a setting that affects diagnostics (e.g.
    // reportUnusedVariables) changes, so open editors update immediately
    // instead of waiting for the next edit.
    refreshOpenDiagnostics() {
        for (const uri of this.loxDocuments.keys()) {
            this.onDidChangeContent(uri);
        }
    }

    onDidChangeContent(uri: string) {
        const document = this.documents.get(uri);
        if (!document) {
            return;
        }

        const loxDocument = this.workspaceIndex.analyzeOpen(uri, document);
        this.loxDocuments.set(uri, loxDocument);
        this.listener("diagnostics", {
            uri: uri,
            diagnostics: loxDocument.diagnostics,
        });
    }

    onDefinition(uri: string, position: Position): Definition | DefinitionLink[] | null {
        const loxDocument = this.loxDocuments.get(uri);
        if (!loxDocument) {
            return null;
        }

        const offset = loxDocument.document.offsetAt(position);
        for (const [reference, definition] of loxDocument.references) {
            if (reference.start <= offset && reference.end >= offset) {
                return {
                    uri: loxDocument.document.uri,
                    range: rangeOf(loxDocument.document, definition),
                };
            }
        }

        for (const [reference, link] of loxDocument.moduleReferences) {
            if (reference.start <= offset && reference.end >= offset) {
                const targetDocument = this.workspaceIndex.getDocument(link.uri);
                if (!targetDocument) {
                    return null;
                }
                return {
                    uri: link.uri,
                    range: rangeOf(targetDocument.document, link.token),
                };
            }
        }
        return null;
    }

    onReferences(uri: string, position: Position): HandlerResult<Location[] | null | undefined, void> {
        const loxDocument = this.loxDocuments.get(uri);
        if (!loxDocument) {
            return null;
        }

        const offset = loxDocument.document.offsetAt(position);

        for (const [definition, references] of loxDocument.definitions) {
            if (definition.start <= offset && definition.end >= offset) {
                const locations: Location[] = (references || []).map((reference) => ({
                    uri: loxDocument.document.uri,
                    range: rangeOf(loxDocument.document, reference),
                }));
                locations.push(...this.findIncomingModuleReferences(uri, definition));
                return locations;
            }
        }
        return null;
    }

    // Modules importing a symbol declared in `definitionUri` don't show up
    // in that document's own `definitions` map (that's local-usages only),
    // and resolveImport() only discovers documents by following imports
    // forward -- a declaration's own file never learns about its importers
    // that way. scanWorkspace() closes that gap by analyzing every .lox
    // file under the workspace root first (mtime-cached, so repeat calls
    // are cheap), so "find references"/"rename" on a class defined in a
    // file nothing else currently open imports still finds its usages.
    private findIncomingModuleReferenceEntries(
        definitionUri: string,
        definitionToken: Token
    ): Array<{ uri: string; document: LoxDocument; token: Token }> {
        this.workspaceIndex.scanWorkspace();

        const definitionKey = fileKey(definitionUri);
        const entries: Array<{ uri: string; document: LoxDocument; token: Token }> = [];
        for (const { uri: otherUri, document: otherDocument } of this.workspaceIndex.allDocuments()) {
            for (const [reference, link] of otherDocument.moduleReferences) {
                if (link.token === definitionToken && fileKey(link.uri) === definitionKey) {
                    entries.push({ uri: otherUri, document: otherDocument, token: reference });
                }
            }
        }
        return entries;
    }

    private findIncomingModuleReferences(definitionUri: string, definitionToken: Token): Location[] {
        return this.findIncomingModuleReferenceEntries(definitionUri, definitionToken).map(
            ({ uri, document, token }) => ({
                uri,
                range: rangeOf(document.document, token),
            })
        );
    }

    onSemanticTokens(uri: string): HandlerResult<SemanticTokens, void> {
        const loxDocument = this.loxDocuments.get(uri);
        if (!loxDocument || !loxDocument.semanticTokens) {
            return { data: [] };
        }

        const builder = new SemanticTokensBuilder();
        for (const token of loxDocument.semanticTokens) {
            const { line, character } = loxDocument.document.positionAt(token.start);
            const length = token.end - token.start;
            const typeId = TOKEN_TO_ID[token.type];

            console.log(token, typeId);
            builder.push(line, character, length, typeId, 0);
        }

        return builder.build();
    }

    onDocumentSymbol(uri: string): HandlerResult<SymbolInformation[] | DocumentSymbol[] | null | undefined, void> {
        const loxDocument = this.loxDocuments.get(uri);
        if (!loxDocument || !loxDocument.documentSymbols) {
            return [];
        }

        return loxDocument.documentSymbols;
    }

    onRename(uri: string, position: Position, newName: string): HandlerResult<WorkspaceEdit | null | undefined, void> {
        const loxDocument = this.loxDocuments.get(uri);
        if (!loxDocument || !loxDocument.definitions) {
            return null;
        }

        const targets = this.collectRenameTargets(uri, loxDocument, position);
        if (targets.length === 0) {
            return null;
        }

        const changes: Record<string, TextEdit[]> = {};
        for (const target of targets) {
            const targetDocument = this.getDocumentByUri(target.uri);
            if (!targetDocument) {
                continue;
            }
            (changes[target.uri] ??= []).push({
                range: rangeOf(targetDocument.document, target.token),
                newText: newName,
            });
        }

        return { changes };
    }

    // Resolves the full rename set for whatever's at `position`: the
    // declaration (wherever it lives) plus every local and cross-file
    // reference to it. Same best-effort scope as findIncomingModuleReferences
    // -- only documents the workspace index has already touched are found.
    private collectRenameTargets(
        uri: string,
        loxDocument: LoxDocument,
        position: Position
    ): Array<{ uri: string; token: Token }> {
        const offset = loxDocument.document.offsetAt(position);

        for (const [reference, link] of loxDocument.moduleReferences) {
            if (reference.start <= offset && reference.end >= offset) {
                const targetDocument = this.workspaceIndex.getDocument(link.uri);
                if (!targetDocument) {
                    return [{ uri, token: reference }];
                }
                return this.gatherAllReferencesTo(link.uri, targetDocument, link.token);
            }
        }

        const localTokens = loxDocument.findAllFromPosition(position);
        if (localTokens.length === 0) {
            return [];
        }
        return this.gatherAllReferencesTo(uri, loxDocument, localTokens[0]);
    }

    private gatherAllReferencesTo(
        definitionUri: string,
        definitionDocument: LoxDocument,
        definitionToken: Token
    ): Array<{ uri: string; token: Token }> {
        const results: Array<{ uri: string; token: Token }> = [{ uri: definitionUri, token: definitionToken }];
        for (const reference of definitionDocument.definitions.get(definitionToken) || []) {
            results.push({ uri: definitionUri, token: reference });
        }
        for (const entry of this.findIncomingModuleReferenceEntries(definitionUri, definitionToken)) {
            results.push({ uri: entry.uri, token: entry.token });
        }
        return results;
    }

    private getDocumentByUri(uri: string): LoxDocument | undefined {
        return this.loxDocuments.get(uri) ?? this.workspaceIndex.getDocument(uri);
    }

    onPrepareRename(
        uri: string,
        position: Position
    ): HandlerResult<
        Range | { range: Range; placeholder: string } | { defaultBehavior: boolean } | null | undefined,
        void
    > {
        const loxDocument = this.loxDocuments.get(uri);
        if (!loxDocument || !loxDocument.definitions) {
            return null;
        }

        const offset = loxDocument.document.offsetAt(position);
        for (const definition of loxDocument.definitions.keys()) {
            if (definition.start <= offset && definition.end >= offset) {
                return {
                    range: rangeOf(loxDocument.document, definition),
                    placeholder: definition.lexeme,
                };
            }
            for (const reference of loxDocument.definitions.get(definition) || []) {
                if (reference.start <= offset && reference.end >= offset) {
                    return {
                        range: rangeOf(loxDocument.document, reference),
                        placeholder: reference.lexeme,
                    };
                }
            }
        }
        for (const reference of loxDocument.moduleReferences.keys()) {
            if (reference.start <= offset && reference.end >= offset) {
                return {
                    range: rangeOf(loxDocument.document, reference),
                    placeholder: reference.lexeme,
                };
            }
        }
        return null;
    }

    onDocumentHighlight(uri: string, position: Position): HandlerResult<DocumentHighlight[] | null | undefined, void> {
        const loxDocument = this.loxDocuments.get(uri);
        if (!loxDocument || !loxDocument.definitions) {
            return null;
        }

        const symbols = loxDocument.findAllFromPosition(position);
        if (!symbols.length) {
            return null;
        }

        return symbols.map((symbol) => {
            return {
                range: {
                    start: loxDocument.document.positionAt(symbol.start),
                    end: loxDocument.document.positionAt(symbol.end),
                },
                kind: DocumentHighlightKind.Text,
            };
        });
    }
}
