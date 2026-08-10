// Locates the .lox file an `import`/`from ... import` statement refers to,
// approximating odlox's own module search order (src/vm/module.odin's
// read_module_source): `$LOX_PATH/modules/<name>.lox`, then alongside the
// *entry script*, then a recursive search of the entry script's directory
// tree. The LSP has no single "entry script" (any open file could be a
// module or an entry point), so this substitutes the workspace root for
// LOX_PATH and for the recursive-search base, and the importing file's own
// directory for "alongside the entry script".

import * as fs from "fs";
import * as path from "path";

const SKIP_DIRS = new Set(["node_modules", ".git", "out", "__loxcache__"]);
const MAX_FILES_VISITED = 20000;

function tryReadDir(dir: string): fs.Dirent[] {
    try {
        return fs.readdirSync(dir, { withFileTypes: true });
    } catch {
        return [];
    }
}

// Depth-first search for a file literally named `filename` under `root`,
// skipping the directories above. Bounded by MAX_FILES_VISITED so a
// misconfigured workspace root (e.g. accidentally the whole d:\odin tree)
// can't make every import resolution walk an unbounded filesystem.
function findRecursive(root: string, filename: string): string | undefined {
    let visited = 0;
    const stack = [root];

    while (stack.length > 0) {
        const dir = stack.pop()!;
        for (const entry of tryReadDir(dir)) {
            if (visited++ > MAX_FILES_VISITED) {
                return undefined;
            }
            if (entry.isDirectory()) {
                if (!SKIP_DIRS.has(entry.name)) {
                    stack.push(path.join(dir, entry.name));
                }
            } else if (entry.isFile() && entry.name === filename) {
                return path.join(dir, entry.name);
            }
        }
    }
    return undefined;
}

// Every `.lox` file under `root`, skipping the directories above. Used to
// seed the workspace index for cross-file find-references/rename, which
// otherwise can only see documents reached via resolveImport (i.e.
// something already open imported them) -- clicking "find references" on a
// declaration in the file that *defines* it, with none of its importers
// open, would otherwise find nothing outside that file. Same
// MAX_FILES_VISITED bound as findRecursive, for the same reason.
export function findAllLoxFiles(root: string): string[] {
    let visited = 0;
    const results: string[] = [];
    const stack = [root];

    while (stack.length > 0) {
        const dir = stack.pop()!;
        for (const entry of tryReadDir(dir)) {
            if (visited++ > MAX_FILES_VISITED) {
                return results;
            }
            if (entry.isDirectory()) {
                if (!SKIP_DIRS.has(entry.name)) {
                    stack.push(path.join(dir, entry.name));
                }
            } else if (entry.isFile() && entry.name.endsWith(".lox")) {
                results.push(path.join(dir, entry.name));
            }
        }
    }
    return results;
}

function isFile(candidate: string): boolean {
    try {
        return fs.statSync(candidate).isFile();
    } catch {
        return false;
    }
}

export function resolveModulePath(
    moduleName: string,
    importingFilePath: string,
    workspaceRoot: string | undefined
): string | undefined {
    const filename = `${moduleName}.lox`;

    if (workspaceRoot) {
        const modulesCandidate = path.join(workspaceRoot, "modules", filename);
        if (isFile(modulesCandidate)) {
            return modulesCandidate;
        }
    }

    const alongside = path.join(path.dirname(importingFilePath), filename);
    if (isFile(alongside)) {
        return alongside;
    }

    if (workspaceRoot) {
        return findRecursive(workspaceRoot, filename);
    }

    return undefined;
}
