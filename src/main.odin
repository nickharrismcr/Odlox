package main

// CLI entry point: file execution, REPL, the standalone `--print-tokens`
// scanner smoke test kept from Phase 1, and Phase 5's debug-tooling
// flags (--compile-only, --disassemble, --info, --debug, --instrument,
// --no-peephole).

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strings"

import "compiler"
import "core"
import "debug"
import "vm"

Options :: struct {
	trace:      bool, // --debug: attach debug.Trace_Hook while running
	instrument: bool, // --instrument: attach debug.Instrument_Hook, report the count after running
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
	}

	opts: Options
	mode := ""
	file_path := ""
	script_args: [dynamic]string

	// Everything up to and including the script path is odlox's own
	// flags/positional argument; everything *after* it is passed
	// through verbatim as the script's own argv (sys.args(), see
	// builtins_sys.odin) rather than parsed as more odlox flags --
	// standard CLI convention (`odlox script.lox --foo` should hand
	// `--foo` to the script, not try to interpret it as odlox's own).
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if file_path != "" {
			append(&script_args, a)
			continue
		}
		switch a {
		case "-h", "--help":
			usage()
		case "--repl":
			mode = "repl"
		case "--print-tokens":
			mode = "print-tokens"
		case "--compile-only":
			mode = "compile-only"
		case "--disassemble":
			mode = "disassemble"
		case "--info":
			mode = "info"
		case "--debug":
			opts.trace = true
		case "--instrument":
			opts.instrument = true
		case "--no-peephole":
			compiler.DebugSkipPeephole = true
		case "--force-compile":
			// Real bug, found via the ported pytest suite's own
			// lox_helper.py, which calls every fixture twice, once with
			// this flag: before this case existed, "--force-compile"
			// fell into the `case:` branch below same as any real file
			// path would, so *it* became file_path (the very next arg,
			// the real path, then landed in script_args instead --
			// "everything after the script path is passed through
			// verbatim", per this loop's own comment above, and once
			// file_path is set to anything, nothing overwrites it
			// again). Every force_compile=True test invocation failed
			// to even find its own script. glox's -f/--force-compile
			// bypasses its bytecode cache (see ARCHITECTURE.md's
			// Bytecode cache section) -- there's no cache here at all
			// (Phase 8, deferred), so every run already recompiles from
			// source unconditionally; explicitly accepting and ignoring
			// the flag is the correct behavior, not a stopgap.
			continue
		case:
			file_path = a
		}
	}

	when !ODIN_DEBUG {
		if opts.trace || opts.instrument {
			fmt.eprintln("odlox: --debug/--instrument have no effect in this build (rebuild with `odin build src -debug`)")
		}
	}

	switch mode {
	case "repl":
		repl()
	case "print-tokens":
		require_file(file_path)
		print_tokens_for_file(file_path)
	case "compile-only":
		require_file(file_path)
		compile_only(file_path)
	case "disassemble":
		require_file(file_path)
		disassemble_file(file_path)
	case "info":
		require_file(file_path)
		info_file(file_path)
	case:
		require_file(file_path)
		run_file(file_path, opts, script_args[:])
	}
}

@(private = "file")
require_file :: proc(path: string) {
	if path == "" {
		usage()
	}
}

run_file :: proc(path: string, opts: Options, script_args: []string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("odlox: could not read %q: %v", path, err)
		os.exit(1)
	}
	defer delete(data)

	vm_instance := vm.new_vm(path)
	vm_instance.script_args = script_args
	vm.define_builtins(vm_instance)
	if opts.trace {
		vm_instance.debug_hook = debug.Trace_Hook
	} else if opts.instrument {
		debug.reset_instrument()
		vm_instance.debug_hook = debug.Instrument_Hook
	}

	status, result := vm.interpret(vm_instance, string(data))

	if opts.instrument {
		fmt.eprintfln("odlox: %d instructions executed", debug.instruction_count())
	}

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

// compile_only reports whether path compiles, without running it --
// the `odlox --compile-only` milestone check ROADMAP.md's Phase 3
// section refers to.
compile_only :: proc(path: string) {
	fn, ok := compile_file(path)
	if !ok {
		os.exit(65)
	}
	_ = fn
	fmt.println("OK")
}

// disassemble_file compiles path and dumps the full bytecode listing
// (the top-level chunk plus every nested function's own chunk) without
// running it -- Phase 5's primary deliverable, wired up.
disassemble_file :: proc(path: string) {
	fn, ok := compile_file(path)
	if !ok {
		os.exit(65)
	}
	debug.disassemble_program(fn)
}

// info_file compiles path and prints a compact summary rather than the
// full instruction-by-instruction dump `--disassemble` gives -- a
// quick "how big is this program" check. glox's own `--info`/`-i`
// output isn't available to compare against in this workspace (glox
// itself isn't checked out here, only the unrelated odin-lang/examples
// reference), so this is this port's own reasonable definition of what
// the flag should report, not a verified port of glox's exact format.
info_file :: proc(path: string) {
	fn, ok := compile_file(path)
	if !ok {
		os.exit(65)
	}
	functions, instructions, constants := program_stats(fn, {})
	fmt.printfln("%s:", path)
	fmt.printfln("  functions:    %d", functions)
	fmt.printfln("  instructions: %d bytes", instructions)
	fmt.printfln("  constants:    %d", constants)
	fmt.printfln("  globals:      %d", fn.chunk.global_count)
}

@(private = "file")
program_stats :: proc(fn: ^core.Function_Object, visited: map[^core.Function_Object]bool) -> (functions, instructions, constants: int) {
	visited := visited
	if visited[fn] {
		return
	}
	visited[fn] = true
	functions = 1
	instructions = len(fn.chunk.code)
	constants = len(fn.chunk.constants)
	for v in fn.chunk.constants {
		if v.type == .Obj && v.obj_type == .Function {
			f2, i2, c2 := program_stats(core.as_function(v), visited)
			functions += f2
			instructions += i2
			constants += c2
		}
	}
	return
}

// compile_file reads and compiles path against a throwaway Environment
// (nothing here runs the result, so there's no VM to size globals
// against -- see interpret.odin's core.env_grow_globals call for why a
// real run needs that extra step and this doesn't).
@(private = "file")
compile_file :: proc(path: string) -> (^core.Function_Object, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("odlox: could not read %q: %v", path, err)
		os.exit(1)
	}
	defer delete(data)

	env := core.make_environment(path)
	return compiler.Compile(string(data), path, env)
}

// repl mirrors glox's own REPL behavior: prints every result except
// the literal "nil" (the implicit value of a statement that isn't an
// expression), and buffers input across lines until
// replInputComplete's bracket-balance check says the buffered text
// forms one complete statement.
repl :: proc() {
	fmt.println("odlox:")
	vm_instance := vm.new_vm("__repl__")
	vm.define_builtins(vm_instance)
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
  --compile-only      Compile a file and report success/failure, then exit
  --disassemble       Compile a file and print its full bytecode listing, then exit
  --info              Compile a file and print a size summary, then exit
  --debug             Attach a live execution trace while running (needs a -debug build)
  --instrument        Count executed instructions while running (needs a -debug build)
  --no-peephole       Disable the peephole optimizer
  -h, --help          Show this help`)
	os.exit(1)
}
