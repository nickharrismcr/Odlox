package debug

import "../core"
import "../vm"
import "core:fmt"

// Trace_Hook and Instrument_Hook implement vm.Debug_Hook -- wire either
// one to a running VM.debug_hook field (see main.odin's --debug flag)
// to watch it execute.
//
// Gated with `when ODIN_DEBUG` inside each proc body, not by leaving
// the procs out of a release build entirely: vm.odin's call sites
// already do a cheap `if vm.debug_hook != nil` check regardless (see
// run.odin/call.odin), so the only thing worth compiling out of a
// release (`-o:speed`, no `-debug`) build is the actual per-instruction
// disassembly/formatting work these hooks do, which *is* real
// overhead. ODIN_DEBUG is Odin's own builtin constant, true exactly
// when the binary was built with `-debug`, so there's no separate flag
// to keep in sync with the build script.

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

// Instrument_Hook just counts executed instructions (Opcode events). A
// package-level counter, not a field threaded through every call, is
// fine here for the same reason the rest of this VM has no
// synchronization anywhere: a single VM is never touched from more
// than one goroutine/thread (see docs/ARCHITECTURE.md's Scope
// section) -- two VMs run concurrently would share this counter, but
// that's not a supported use of --instrument in the first place (it's
// a single-script debugging aid, not a production metric).
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

// Gc_Hook logs each GC cycle as it happens (bytes reclaimed, new
// threshold) and tallies a running count/total for a post-run summary --
// see main.odin's --trace-gc flag. gc_bytes_before_val is package-level
// state bridging the .Gc_Start event (recorded here) to the matching
// .Gc_End event (where the before/after delta is known), same
// single-VM-at-a-time assumption instruction_count_val's own doc comment
// explains.
@(private)
gc_cycle_count_val: int
@(private)
gc_bytes_freed_val: int
@(private)
gc_bytes_before_val: int

Gc_Hook :: proc(v: ^vm.VM, event: vm.Debug_Event) {
	when ODIN_DEBUG {
		#partial switch event {
		case .Gc_Start:
			gc_bytes_before_val = v.bytes_allocated
		case .Gc_End:
			gc_cycle_count_val += 1
			freed := gc_bytes_before_val - v.bytes_allocated
			gc_bytes_freed_val += freed
			fmt.eprintfln(
				"[gc #%d] %d -> %d bytes (%d freed), next_gc=%d",
				gc_cycle_count_val,
				gc_bytes_before_val,
				v.bytes_allocated,
				freed,
				v.next_gc,
			)
		}
	}
}

gc_cycle_count :: proc() -> int {
	return gc_cycle_count_val
}

gc_bytes_freed :: proc() -> int {
	return gc_bytes_freed_val
}

reset_gc_stats :: proc() {
	gc_cycle_count_val = 0
	gc_bytes_freed_val = 0
	gc_bytes_before_val = 0
}
