package main

// CLI entry point. Currently just enough to exercise the scanner
// (Phase 1) end to end: `odlox --print-tokens <file>` tokenizes a file
// and dumps the token stream. The REPL/compile/run flags described in
// ROADMAP.md's Phase 4 land once the compiler and VM exist to back them.

import "core:fmt"
import "core:os"

import "compiler"

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
	}

	switch args[0] {
	case "--print-tokens":
		if len(args) != 2 {
			usage()
		}
		print_tokens_for_file(args[1])
	case:
		usage()
	}
}

print_tokens_for_file :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("odlox: could not read %q: %v", path, err)
		os.exit(1)
	}
	defer delete(data)

	s := compiler.tokenize(string(data))
	defer compiler.destroy_scanner(&s)
	compiler.print_tokens(&s)
}

usage :: proc() {
	fmt.eprintln("Usage: odlox --print-tokens <file>")
	os.exit(1)
}
