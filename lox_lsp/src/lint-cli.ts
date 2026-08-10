// lint-cli.ts: batch, non-interactive driver for the same
// Scanner -> Parser -> Resolver pipeline the LSP server's LoxDocument
// runs per-file on save (see src/server/LoxDocument.ts). Lets many .lox
// files be checked from the command line in one pass instead of opening
// each one in an editor with the extension installed.
//
// Usage: npx ts-node src/lint-cli.ts <file1.lox> [file2.lox ...]
// Exit code is the number of files that had at least one error.

import * as fs from "fs";
import { Scanner } from "./jslox/Scanner";
import { Parser } from "./jslox/Parser";
import { Resolver } from "./jslox/Resolver";
import { ErrorReporter, TokenPosition } from "./jslox/Error";

function lintFile(path: string): boolean {
    const source = fs.readFileSync(path, "utf8");
    let hadError = false;

    const reporter: ErrorReporter = {
        error: (token: TokenPosition, message: string) => {
            hadError = true;
            console.log(`${path}:${token.line}: error: ${message}`);
        },
        warn: (token: TokenPosition, message: string) => {
            console.log(`${path}:${token.line}: warning: ${message}`);
        },
        runtimeError: () => {},
    };

    const scanner = new Scanner(source, reporter);
    const parser = new Parser(scanner.scanTokens(), reporter);
    const statements = parser.parse();

    if (!statements || hadError) {
        return hadError;
    }

    const resolver = new Resolver(reporter);
    resolver.resolve(statements);

    return hadError;
}

const files = process.argv.slice(2);
if (files.length === 0) {
    console.error("usage: lint-cli.ts <file1.lox> [file2.lox ...]");
    process.exit(1);
}

let failCount = 0;
for (const file of files) {
    try {
        if (lintFile(file)) {
            failCount += 1;
        }
    } catch (e) {
        console.log(`${file}: exception: ${(e as Error).message}`);
        failCount += 1;
    }
}

console.error(`\n${failCount} of ${files.length} files had errors/warnings.`);
process.exit(failCount > 0 ? 1 : 0);
