/* --------------------------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * Licensed under the MIT License. See License.txt in the project root for license information.
 * ------------------------------------------------------------------------------------------ */
import {
    createConnection,
    TextDocuments,
    ProposedFeatures,
    InitializeParams,
    TextDocumentPositionParams,
    TextDocumentSyncKind,
    InitializeResult,
} from "vscode-languageserver/node";
import { fileURLToPath } from "url";

import { TextDocument } from "vscode-languageserver-textdocument";
import { LoxLspServer } from "./LoxLspServer";
import { TOKEN_LEGEND } from "./SemanticTokenAnalyzer";

// Best-effort: rootUri is deprecated in favor of workspaceFolders (which can
// hold more than one), but this server only ever resolves imports against a
// single root -- the first workspace folder, falling back to rootUri for
// older clients that don't send workspaceFolders at all.
function workspaceRootFrom(params: InitializeParams): string | undefined {
    const uri = params.workspaceFolders?.[0]?.uri ?? params.rootUri ?? undefined;
    if (!uri) {
        return undefined;
    }
    try {
        return fileURLToPath(uri);
    } catch {
        return undefined;
    }
}

// Create a connection for the server, using Node's IPC as a transport.
// Also include all preview / proposed LSP features.
const connection = createConnection(ProposedFeatures.all);

let hasConfigurationCapability = false;

// Pulls the current `lox.diagnostics.reportUnusedVariables` setting from the
// client (pull-based `workspace/configuration`, not push -- vscode-languageclient
// supports this by default, no client-side wiring needed beyond declaring the
// setting in package.json's contributes.configuration) and applies it.
async function refreshSettings(): Promise<void> {
    if (!hasConfigurationCapability) {
        return;
    }
    const reportUnusedVariables = await connection.workspace.getConfiguration({
        section: "lox.diagnostics.reportUnusedVariables",
    });
    loxServer.setReportUnusedVariables(reportUnusedVariables ?? true);
}

// Create a simple text document manager.
const documents: TextDocuments<TextDocument> = new TextDocuments(TextDocument);

const loxServer = new LoxLspServer(documents, (type, params) => {
    switch (type) {
        case "diagnostics":
            connection.sendDiagnostics(params);
            break;

        default:
            break;
    }
});

connection.onInitialize((params: InitializeParams) => {
    loxServer.setWorkspaceRoot(workspaceRootFrom(params));

    const capabilities = params.capabilities;
    hasConfigurationCapability = !!capabilities.workspace?.configuration;

    const hasSemanticTokensCapability = !!capabilities.textDocument?.semanticTokens?.requests?.full;
    const hasSymbolProviderCapability = !!capabilities.textDocument?.documentSymbol?.hierarchicalDocumentSymbolSupport;
    const hasRenameCapability = !!capabilities.textDocument?.rename?.prepareSupport;

    const result: InitializeResult = {
        capabilities: {
            textDocumentSync: TextDocumentSyncKind.Full,
            definitionProvider: true,
            referencesProvider: true,
        },
    };

    if (capabilities.textDocument?.documentHighlight) {
        result.capabilities.documentHighlightProvider = true;
    }

    if (hasRenameCapability) {
        result.capabilities.renameProvider = {
            prepareProvider: true,
        };
    }

    if (hasSymbolProviderCapability) {
        console.log(capabilities.textDocument?.semanticTokens);
        result.capabilities.documentSymbolProvider = true;
    }

    if (hasSemanticTokensCapability) {
        console.log(capabilities.textDocument?.semanticTokens);
        result.capabilities.semanticTokensProvider = {
            legend: {
                tokenTypes: TOKEN_LEGEND.concat(),
                tokenModifiers: [],
            },
            range: false,
            full: true,
        };
    }

    return result;
});

connection.onInitialized(() => {
    // refreshSettings() is an async round-trip to the client; it can lose
    // the race against the client's initial textDocument/didOpen for
    // whatever's already open, which would otherwise analyze with the
    // default (reportUnusedVariables: true) and never get corrected --
    // refreshOpenDiagnostics() re-analyzes with whatever the setting turned
    // out to be as soon as the pull actually completes.
    refreshSettings().then(() => loxServer.refreshOpenDiagnostics());
});

// Fired whenever the client's config changes, including this extension's
// own `lox.diagnostics.*` settings -- re-pull and republish diagnostics for
// every open document so a toggled setting takes effect immediately rather
// than waiting for the next edit.
connection.onDidChangeConfiguration(() => {
    refreshSettings().then(() => loxServer.refreshOpenDiagnostics());
});

connection.onPrepareRename((params: TextDocumentPositionParams) => {
    return loxServer.onPrepareRename(params.textDocument.uri, params.position);
});

connection.onRenameRequest((params) => {
    return loxServer.onRename(params.textDocument.uri, params.position, params.newName);
});

connection.onDefinition((params: TextDocumentPositionParams) => {
    return loxServer.onDefinition(params.textDocument.uri, params.position);
});

connection.onReferences((params: TextDocumentPositionParams) => {
    return loxServer.onReferences(params.textDocument.uri, params.position);
});

connection.onDocumentSymbol((params) => {
    return loxServer.onDocumentSymbol(params.textDocument.uri);
});

connection.onDocumentHighlight((params) => {
    return loxServer.onDocumentHighlight(params.textDocument.uri, params.position);
});

connection.languages.semanticTokens.on((params) => {
    return loxServer.onSemanticTokens(params.textDocument.uri);
});

documents.listen(connection);
connection.listen();
