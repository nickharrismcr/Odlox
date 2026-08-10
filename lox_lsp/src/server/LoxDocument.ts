import { Diagnostic, DiagnosticSeverity, DocumentSymbol, Position } from "vscode-languageserver";
import { TextDocument } from "vscode-languageserver-textdocument";
import { ErrorReporter } from "../jslox/Error";
import { Scanner } from "../jslox/Scanner";
import { Parser } from "../jslox/Parser";
import { Resolver } from "../jslox/Resolver";
import { Token } from "../jslox/Token";
import { SemanticToken, SemanticTokenAnalyzer } from "./SemanticTokenAnalyzer";

// What resolveImport(moduleName) returns: the resolved module's own URI
// (so the LSP layer can build a Location without re-resolving the module
// path) plus its export table (name -> declaring token in its own token
// stream, handed straight to Resolver).
export interface ResolvedModule {
    uri: string;
    exports: Map<string, Token>;
}

// A reference in this document that resolved to a declaration in another
// document (via `from <module> import ...`), already URI-qualified.
export interface ModuleReference {
    uri: string;
    token: Token;
}

export class LoxDocument {
    public diagnostics: Diagnostic[] = [];
    public hadError: boolean = false;
    public definitions: Map<Token, Token[]> = new Map();
    public references: Map<Token, Token> = new Map();
    public semanticTokens: SemanticToken[] = [];
    public documentSymbols?: DocumentSymbol[];

    // Every module-scope binding this file makes, by name -- what a
    // `from <this file> import ...` elsewhere resolves against.
    public exports: Map<string, Token> = new Map();

    // Reference tokens (in this document) that resolved to a declaration in
    // another document, keyed the same way `references` is.
    public moduleReferences: Map<Token, ModuleReference> = new Map();

    constructor(public document: TextDocument) {}

    // resolveImport looks up another module's exports by name, given the
    // module name written in an `import`/`from ... import` statement here.
    // Supplied by the workspace index; undefined in single-file contexts
    // (imports still parse and declare locally, they just don't link to a
    // real cross-file declaration -- see Resolver's own resolveImport param).
    analyze(resolveImport?: (moduleName: string) => ResolvedModule | undefined) {
        const source = this.document.getText();

        this.diagnostics = [];
        this.semanticTokens = [];

        this.hadError = false;
        const reporter: ErrorReporter = {
            error: (token: Token, message: string) => {
                this.hadError = true;
                const diagnostic: Diagnostic = {
                    severity: DiagnosticSeverity.Error,
                    range: {
                        start: this.document.positionAt(token.start),
                        end: this.document.positionAt(token.end),
                    },
                    message: message,
                    source: "Lox",
                };
                this.diagnostics.push(diagnostic);
            },
            warn: (token: Token, message: string) => {
                const diagnostic: Diagnostic = {
                    severity: DiagnosticSeverity.Warning,
                    range: {
                        start: this.document.positionAt(token.start),
                        end: this.document.positionAt(token.end),
                    },
                    message: message,
                    source: "Lox",
                };
                this.diagnostics.push(diagnostic);
            },
            runtimeError: function (): void {},
        };

        const tokens = new Scanner(source, reporter).scanTokens();
        const parser = new Parser(tokens, reporter);

        const statements = parser.parse();
        if (!statements || this.hadError) {
            return;
        }

        // Resolver only deals in module names; remember which URI each one
        // resolved to so moduleReferences (built below from Resolver's
        // moduleName-keyed output) can be turned into URI-qualified links.
        const moduleUris = new Map<string, string>();
        const resolver = new Resolver(
            reporter,
            resolveImport &&
                ((moduleName) => {
                    const resolved = resolveImport(moduleName);
                    if (!resolved) {
                        return undefined;
                    }
                    moduleUris.set(moduleName, resolved.uri);
                    return resolved.exports;
                })
        );
        resolver.resolve(statements);

        if (statements && !this.hadError) {
            const analyzer = new SemanticTokenAnalyzer();
            analyzer.analyze(statements, resolver);
            this.semanticTokens = analyzer.tokens;
            this.documentSymbols = analyzer.documentSymbols;
        }

        this.definitions = resolver.definitions;
        this.references = resolver.references;
        this.exports = resolver.exports;

        this.moduleReferences = new Map();
        for (const [refToken, link] of resolver.moduleReferences) {
            const uri = moduleUris.get(link.moduleName);
            if (uri) {
                this.moduleReferences.set(refToken, { uri, token: link.token });
            }
        }
    }

    findAllFromPosition(position: Position): Token[] {
        const offset = this.document.offsetAt(position);
        let definition: Token | undefined = undefined;
        for (const [def, references] of this.definitions) {
            if (def.start <= offset && def.end >= offset) {
                definition = def;
                break;
            }

            for (const reference of references || []) {
                if (reference.start <= offset && reference.end >= offset) {
                    definition = def;
                    break;
                }
            }
        }
        if (!definition) {
            return [];
        }

        return [definition, ...(this.definitions.get(definition) || [])];
    }
}
