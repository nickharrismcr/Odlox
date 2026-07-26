package main

// CLI entry point: file execution, REPL, and the standalone
// `--print-tokens` scanner smoke test kept from Phase 1.

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strings"

import "compiler"
import "vm"

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
	case "--repl":
		repl()
	case "-h", "--help":
		usage()
	case:
		run_file(args[0])
	}
}

run_file :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("odlox: could not read %q: %v", path, err)
		os.exit(1)
	}
	defer delete(data)

	vm_instance := vm.new_vm(path)
	status, result := vm.interpret(vm_instance, string(data))
	switch status {
	case .Compile_Error:
		os.exit(65)
	case .Runtime_Error:
		fmt.eprintln(vm_instance.error_msg)
		os.exit(70)
	case .Ok:
		fmt.println(result)
	}
}

// repl mirrors glox's own REPL behavior: prints every result except
// the literal "nil" (the implicit value of a statement that isn't an
// expression), and buffers input across lines until
// replInputComplete's bracket-balance check says the buffered text
// forms one complete statement.
repl :: proc() {
	fmt.println("odlox:")
	vm_instance := vm.new_vm("__repl__")
	vm.set_repl(vm_instance, true)

	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(os.stdin))
	defer bufio.reader_destroy(&reader)

	buf: strings.Builder
	strings.builder_init(&buf)

	for {
		if strings.builder_len(buf) == 0 {
			fmt.print("> ")
		} else {
			fmt.print("... ")
		}

		line, ok := read_line(&reader)
		if !ok {
			return // EOF (Ctrl-Z / Ctrl-D)
		}

		if strings.builder_len(buf) == 0 && len(line) == 0 {
			return // blank line at top level exits
		}
		if strings.builder_len(buf) > 0 && len(line) == 0 {
			strings.builder_reset(&buf) // blank line while buffering cancels the pending entry
			continue
		}
		if strings.builder_len(buf) > 0 {
			strings.write_byte(&buf, '\n')
		}
		strings.write_string(&buf, line)

		src := strings.to_string(buf)
		if !repl_input_complete(src) {
			continue // need more input
		}

		status, result := vm.interpret(vm_instance, src)
		strings.builder_reset(&buf)

		switch status {
		case .Ok:
			if result != "nil" {
				fmt.println(result)
			}
		case .Runtime_Error:
			fmt.println(vm_instance.error_msg)
		case .Compile_Error:
		// compile errors are already reported by the compiler as they occur
		}
	}
}

@(private = "file")
read_line :: proc(reader: ^bufio.Reader) -> (string, bool) {
	line, err := bufio.reader_read_string(reader, '\n')
	if err != nil {
		return "", false
	}
	return strings.trim_right(line, "\r\n"), true
}

// repl_input_complete reports whether buffered REPL input forms a
// complete statement: all ()[]{}} are balanced and no string/
// interpolation is left open. Reuses the real scanner (rather than a
// separate paren-matcher) so brackets inside strings/comments never
// contribute stray depth.
@(private = "file")
repl_input_complete :: proc(src: string) -> bool {
	s := compiler.tokenize(src)
	defer compiler.destroy_scanner(&s)

	depth := 0
	for t in s.tokens {
		#partial switch t.type {
		case .Left_Brace, .Left_Paren, .Left_Bracket:
			depth += 1
		case .Right_Brace, .Right_Paren, .Right_Bracket:
			depth -= 1
		case .Error:
			if strings.contains(compiler.lexeme(t), "Unterminated") {
				return false // open string/interpolation -- keep reading
			}
		}
	}
	return depth <= 0
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
	fmt.eprintln(`Usage: odlox [options] filename

Options:
  --repl              Start interactive REPL
  --print-tokens      Tokenize a file and print the token stream, then exit
  -h, --help          Show this help`)
	os.exit(1)
}
