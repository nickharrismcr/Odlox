package vm

import "../compiler"
import "../core"

// interpret is the single entry point for both a fresh script run and
// a REPL line -- and, via module.odin's load_module, a module import's
// nested compile+run too. Compiles source (through Compile_Repl if
// vm.repl, else a plain one-shot Compile), wraps the result in a
// closure, and runs it to completion.
interpret :: proc(vm: ^VM, source: string) -> (Interpret_Result, string) {
	reset_stack(vm)
	delete(vm.stack_trace)
	vm.stack_trace = nil
	vm.error_msg = ""
	vm.pending_exception_class = ""

	fn: ^core.Function_Object
	ok: bool
	if vm.repl {
		fn, ok = compiler.Compile_Repl(source, &vm.repl_state)
	} else {
		fn, ok = compiler.Compile(source, vm.script, vm.environment)
	}
	if !ok {
		return .Compile_Error, ""
	}

	// The compiler only *computes* how many global slots this
	// compilation unit needs (fn.chunk.global_count); actually sizing
	// Environment.globals/defined is a separate runtime step -- grow
	// rather than a fresh init, so a REPL line's globals survive into
	// the next one instead of being wiped out here.
	core.env_grow_globals(vm.environment, fn.chunk.global_count)
	seed_builtin_globals(vm, fn)

	closure := core.make_closure_object(fn)
	gc_track(vm, &closure.obj)
	push(vm, core.make_object_value(&closure.obj))
	if !call(vm, closure, 0) {
		return .Runtime_Error, vm.error_msg
	}

	status, result := run(vm, .To_Completion)
	if status == .Runtime_Error {
		return .Runtime_Error, vm.error_msg
	}
	return .Ok, core.value_to_string(result)
}
