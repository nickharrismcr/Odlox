package debug

import "../core"
import "../vm"
import "core:fmt"

// Trace_Hook and Instrument_Hook implement vm.Debug_Hook -- wire either
// one to a running VM.debug_hook field (see main.odin's --debug flag)
// to watch it execute, matching glox's own hot-loop debug hook
// (core.HotLoopDebugHookCompiled).
//
// Gated with `when ODIN_DEBUG` inside each proc body, not by leaving
// the procs out of a release build entirely: vm.odin's call sites
// already do a cheap `if vm.debug_hook != nil` check regardless (see
// run.odin/call.odin), so the only thing worth compiling out of a
// release (`-o:speed`, no `-debug`) build is the actual per-instruction
// disassembly/formatting work these hooks do, which *is* real
// overhead. ODIN_DEBUG is Odin's own builtin constant, true exactly
// when the binary was built with `-debug` -- using it directly means
// there's no separate flag to keep in sync with the build script, and
// no glox-style shell-script uncomment/recomment dance needed either.

// Trace_Hook dumps the value stack, then disassembles the instruction
// about to execute, every step. Very verbose -- meant for debugging
// the VM itself on a small script, not for anything long-running.
Trace_Hook :: proc(v: ^vm.VM, event: vm.Debug_Event) {
	when ODIN_DEBUG {
		if event != .Opcode {
			return
		}
		print_stack(v)
		f := vm.frame(v)
		disassemble_instruction(f.closure.function.chunk, f.ip)
	} else {
		// Compiled out entirely in a non-debug build -- see this
		// file's header comment.
	}
}

@(private = "file")
print_stack :: proc(v: ^vm.VM) {
	fmt.print("          ")
	for i in 0 ..< v.stack_top {
		fmt.printf("[ %s ]", core.value_to_string(v.stack[i]))
	}
	fmt.println()
}

// Instrument_Hook just counts executed instructions (Opcode events) --
// glox's equivalent is its own hot-loop instruction counter. A
// package-level counter, not a field threaded through every call, is
// fine here for the same reason the rest of this VM has no
// synchronization anywhere: a single VM is never touched from more
// than one goroutine/thread in this port's scope (see
// docs/ARCHITECTURE.md's Scope section) -- two VMs run concurrently
// would share this counter, but that's not a supported use of
// --instrument in the first place (it's a single-script debugging
// aid, not a production metric).
@(private)
instruction_count_val: int

Instrument_Hook :: proc(v: ^vm.VM, event: vm.Debug_Event) {
	when ODIN_DEBUG {
		if event == .Opcode {
			instruction_count_val += 1
		}
	}
}

instruction_count :: proc() -> int {
	return instruction_count_val
}

reset_instrument :: proc() {
	instruction_count_val = 0
}
