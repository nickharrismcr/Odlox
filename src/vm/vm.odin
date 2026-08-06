package vm

import "../compiler"
import "../core"
import "core:fmt"
import "core:time"

// The VM: fixed-size value stack and call-frame array (matching clox's
// own arrays -- no heap indirection on the hot path), one intrusive GC
// object list, and the small amount of session state (REPL mode, error
// reporting, module cache) a running interpreter needs. See
// docs/ARCHITECTURE.md's VM dispatch loop and Garbage collector
// sections for the design this implements.
//
// No mutex/lock anywhere in this package: the VM is single-threaded for
// its whole life (see docs/ARCHITECTURE.md's Scope section -- threads
// are out of scope entirely).

FRAMES_MAX :: 64
STACK_MAX :: FRAMES_MAX * 256

Call_Frame :: struct {
	closure:  ^core.Closure_Object,
	ip:       int,
	slots:    int, // stack index where this frame's locals begin
	handlers: ^Exception_Handler,
	depth:    int,
}

// Exception_Handler is a cons-list node pushed by Op_Try and popped by
// Op_End_Try/a successful catch -- see exceptions.odin's raise_exception
// for the full matching loop.
Exception_Handler :: struct {
	except_ip: int,
	stack_top: int,
	prev:      ^Exception_Handler,
}

Interpret_Result :: enum {
	Ok,
	Compile_Error,
	Runtime_Error,
}

Debug_Event :: enum {
	Opcode,
	Call,
	Return,
	Gc_Start, // fired at the top of collect_garbage, before mark_roots
	Gc_End,   // fired after sweep, once vm.bytes_allocated/next_gc reflect the finished cycle
}

Debug_Hook :: #type proc(vm: ^VM, event: Debug_Event)

VM :: struct {
	script:      string, // path/name of the running script, for error messages
	root_script: string, // the top-level entry script's path -- module.odin's read_module_source resolves local (non-stdlib) imports relative to *this*, not `script`, so a nested import (e.g. a module in npc/ importing one that actually lives in game/) still finds it by searching from the entry script's own directory down, instead of resolving relative to whichever module happens to be doing the importing.
	source:      string, // its source text, for stack-trace context lines

	stack:       [STACK_MAX]core.Value,
	stack_top:   int,
	frames:      [FRAMES_MAX]Call_Frame,
	frame_count: int,

	open_upvalues: ^core.Upvalue_Object, // sorted descending by stack slot

	// Error state: opcodes/native calls set error_msg (see
	// runtime_error) rather than raising directly -- run()'s dispatch
	// loop checks it once per instruction and converts it into a real
	// exception via raise_exception (see exceptions.odin).
	error_msg:               string,
	pending_exception_class: string,
	stack_trace:             [dynamic]string,

	// exception_floor: raise_exception's unwind will not pop any frame
	// at or below this index -- raised while running a nested
	// re-entrant run() call (Run_Current_Function mode, used by
	// Op_Foreach/Op_Next/Op_Str's toString dispatch) so an exception
	// inside that nested call can't escape past its own boundary into
	// the real caller's frames.
	exception_floor: int,

	environment: ^core.Environment, // the running script's own globals

	builtins:        map[^core.String_Object]core.Value,
	builtin_modules:  map[^core.String_Object]^core.Module_Object,

	repl:        bool,
	repl_state:  compiler.Repl_State,

	// sys.clock()/sys.args() support (builtins.odin/builtins_sys.odin):
	// start_time is captured once at construction so `sys.clock()` can
	// report elapsed seconds since VM startup; script_args is empty
	// unless main.odin's CLI parsing populates it with argv entries
	// after the script path.
	start_time:  time.Time,
	script_args: []string,

	// GC (see gc.odin) -- an intrusive singly-linked list of every
	// collectible allocation this VM has made, mirroring clox's own
	// vm.objects.
	objects:         ^core.Obj,
	bytes_allocated: int,
	next_gc:         int,
	gray_stack:      [dynamic]^core.Obj,

	debug_hook: Debug_Hook,

	// force_compile: when set, module.odin's load_module skips
	// bc_cache_load's lookup entirely (never even stat-ing the .lxc)
	// but still writes a fresh cache afterward -- see
	// docs/plans/bytecode-cache.md. Never affects the entry script,
	// which never consults the cache at all.
	force_compile: bool,

	// force_bc_cache: the opposite trust direction from force_compile --
	// when set, bc_cache_load (vm/bc_cache.odin) skips the source-mtime
	// freshness check entirely and trusts a `.lxc` unconditionally
	// whenever one exists, and read_module_source (module.odin) will
	// resolve a module from a `.lxc` alone even when no matching `.lox`
	// exists on disk at all. Exists for compiled-only library
	// distribution: ship `__loxcache__/<name>.lxc` without the source
	// `.lox` it was built from. Never affects the entry script, same as
	// force_compile.
	force_bc_cache: bool,
}

// new_vm_raw constructs a bare VM with no exception hierarchy bootstrapped
// yet -- used both as the real constructor's first step and, directly,
// by bootstrap_exceptions/module.odin's load_module for the disposable
// sub-VMs that compile-and-run a small embedded/imported source: those
// must NOT recursively call new_vm (which would re-run
// bootstrap_exceptions, which itself needs a working VM to run its own
// embedded source against -- infinite regress).
new_vm_raw :: proc(script: string) -> ^VM {
	vm := new(VM)
	vm.script = script
	vm.root_script = script
	vm.environment = core.make_environment(script)
	vm.start_time = time.now()
	vm.next_gc = INITIAL_GC_THRESHOLD
	vm.builtins = make(map[^core.String_Object]core.Value)
	vm.builtin_modules = make(map[^core.String_Object]^core.Module_Object)
	return vm
}

// new_vm constructs a VM ready to run script (used for error messages;
// pass "" for a REPL session). Built-in registration is a separate,
// optional step the caller performs afterward (see builtins.odin).
new_vm :: proc(script: string) -> ^VM {
	vm := new_vm_raw(script)
	bootstrap_exceptions(vm)
	return vm
}

// set_repl switches vm into REPL mode, initializing the persistent
// slot-assignment state (compiler.Repl_State) subsequent Interpret
// calls need to keep resolving names consistently across separately-
// compiled lines -- see docs/ARCHITECTURE.md's Compiler section.
set_repl :: proc(vm: ^VM, repl: bool) {
	vm.repl = repl
	if repl {
		vm.repl_state = compiler.make_repl_state(vm.environment)
	}
}

frame :: proc(vm: ^VM) -> ^Call_Frame {
	return &vm.frames[vm.frame_count - 1]
}

// print_stack_trace is called from main.odin right after printing an
// uncaught runtime error's own message, on every such error in both the
// file-run and REPL paths, not as an opt-in debug feature.
// vm.stack_trace is built up by exceptions.odin's append_stack_trace as
// raise_exception unwinds.
print_stack_trace :: proc(vm: ^VM) {
	for line in vm.stack_trace {
		fmt.println(line)
	}
}

push :: proc(vm: ^VM, v: core.Value) {
	vm.stack[vm.stack_top] = v
	vm.stack_top += 1
}

pop :: proc(vm: ^VM) -> core.Value {
	vm.stack_top -= 1
	return vm.stack[vm.stack_top]
}

peek :: proc(vm: ^VM, distance: int) -> core.Value {
	return vm.stack[vm.stack_top - 1 - distance]
}

reset_stack :: proc(vm: ^VM) {
	vm.stack_top = 0
	vm.frame_count = 0
	vm.open_upvalues = nil
}

// runtime_error records a formatted message on the VM rather than
// raising immediately -- run()'s dispatch loop converts it into a real
// exception at the bottom of the loop body (see exceptions.odin). This
// indirection is what lets a single conversion site turn "the built-in
// arithmetic opcodes hit a type error" and "a native function reported
// a problem" into the exact same Lox-level exception machinery.
runtime_error :: proc(vm: ^VM, format: string, args: ..any) {
	vm.error_msg = fmt_error(format, ..args)
}

// runtime_error_named additionally picks which built-in exception class
// the message becomes (default is "RunTimeError" -- see
// exceptions.odin's raise_exception_by_name).
runtime_error_named :: proc(vm: ^VM, class_name: string, format: string, args: ..any) {
	vm.error_msg = fmt_error(format, ..args)
	vm.pending_exception_class = class_name
}

@(private = "file")
fmt_error :: proc(format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args)
}
