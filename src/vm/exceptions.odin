package vm

import "../core"

// try/except/finally at the VM level. The bytecode shape this reads is
// documented in stmt.odin's try_except_statement; read that first.
//
// One deliberate departure from glox's own algorithm here, not just a
// port: glox's `nextHandler()` finds "the next clause" by scanning the
// raw bytecode byte-by-byte for an Op_End_Except immediately followed
// by Op_Except/Op_Finally (see glox's docs/exception-handling.md).
// That's fragile in a way this port doesn't need to accept: a clause
// body can itself contain a *nested* try/except, whose own
// End_Except/Except/Finally bytes would appear earlier in the byte
// stream than the outer clause's real terminator, and a flat scan has
// no way to tell those apart from the outside without also tracking
// nesting depth through arbitrary intervening code. Since this port
// controls both the compiler's emission and the VM's reading of it,
// Op_Except instead carries its own explicit 2-byte skip offset
// (patched exactly like any other jump -- see stmt.odin) pointing
// straight at the next clause. No scanning, no ambiguity, and it works
// correctly through nested trys for free.

// bootstrap_exceptions compiles and runs a small embedded Lox source
// string defining the base exception hierarchy (Exception,
// RunTimeError, EOFError) through a disposable sub-VM, then harvests
// the resulting classes into vm.builtins -- mirrors glox's own
// `loadBuiltInFromSource` approach (see docs/ARCHITECTURE.md's
// Native/builtin functions section): far less code than hand-building
// Class_Object graphs, and the hierarchy behaves exactly like any other
// Lox class (inheritance, toString, ...) because it *is* one, compiled
// by this same compiler.
@(private = "file")
EXCEPTION_SOURCE :: `
class Exception {
	init(msg) {
		this.msg = msg
		this.name = "Exception"
	}
	toString() {
		return this.name & ": " & this.msg
	}
}
class RunTimeError < Exception {
	init(msg) {
		this.msg = msg
		this.name = "RunTimeError"
	}
}
class EOFError < Exception {
	init(msg) {
		this.msg = msg
		this.name = "EOFError"
	}
}
`

// bootstrap_cache holds the harvested exception classes after the first
// bootstrap_exceptions call in this process -- every subsequent VM
// (there are many: one per script run in production is normal, but
// module.odin's load_module and the test suite both construct plenty of
// short-lived ones too) just copies from this cache instead of paying
// for a full compile-and-run of EXCEPTION_SOURCE again. Not just a perf
// win: recompiling the same tiny source through a fresh sub-VM dozens of
// times in one process, all hammering the same global string-intern
// table (see obj_string.odin), turned out to be exactly the load
// pattern that made an Odin-test-runner-specific memory-tracking issue
// reproducible (see docs/ARCHITECTURE.md's "No concurrency anywhere"
// section) -- cutting the real bootstrap down to once per process
// removed the repetition that was triggering it.
@(private)
bootstrap_cache: map[string]core.Value
@(private)
bootstrap_ready: bool

// Package-private (not file-private): called from vm.odin's new_vm.
@(private)
bootstrap_exceptions :: proc(vm: ^VM) {
	if !bootstrap_ready {
		sub := new_vm_raw("__exceptions__")
		status, _ := interpret(sub, EXCEPTION_SOURCE)
		if status != .Ok {
			panic("internal error: built-in exception bootstrap failed to compile/run")
		}
		bootstrap_cache = make(map[string]core.Value)
		for name, slot in sub.environment.global_names {
			if slot < len(sub.environment.defined) && sub.environment.defined[slot] {
				bootstrap_cache[name] = sub.environment.globals[slot]
			}
		}
		bootstrap_ready = true
	}
	for name, v in bootstrap_cache {
		vm.builtins[core.intern_string(name)] = v
	}
}

// ensure_exception_instance normalizes whatever Op_Raise found on top
// of the stack into a real Exception-hierarchy instance: `raise
// "boom"` (or any non-exception value) is convenience syntax for
// `raise RunTimeError("boom")`, wrapping the stringified value.
ensure_exception_instance :: proc(vm: ^VM, val: core.Value) -> core.Value {
	if val.type == .Obj && val.obj_type == .Instance {
		inst := core.as_instance(val)
		if is_exception_class(vm, inst.class) {
			return val
		}
	}
	class_val, ok := vm.builtins[core.intern_string("RunTimeError")]
	if !ok {
		return val // unreachable once bootstrap_exceptions has run
	}
	inst := core.make_instance_object(core.as_class(class_val))
	gc_track(vm, &inst.obj)
	inst.fields[core.intern_string("msg")] = core.make_string_value(display_string(val))
	inst.fields[core.intern_string("name")] = core.make_string_value("RunTimeError")
	return core.make_object_value(&inst.obj)
}

@(private = "file")
is_exception_class :: proc(vm: ^VM, class: ^core.Class_Object) -> bool {
	base_val, ok := vm.builtins[core.intern_string("Exception")]
	if !ok {
		return false
	}
	return core.is_subclass_of(class, core.as_class(base_val))
}

@(private = "file")
exception_class_of :: proc(err: core.Value) -> ^core.Class_Object {
	if err.type == .Obj && err.obj_type == .Instance {
		return core.as_instance(err).class
	}
	return nil
}

// resolve_class_by_name looks a name up as a built-in first, then as a
// global in the running script's own Environment -- covers both the
// bootstrap hierarchy and user-defined exception classes. (glox's
// fuller version also checks the current function's module-export
// Vars; skipped here as a Phase 4 simplification since module imports
// are still minimal at this point -- see module.odin.)
resolve_class_by_name :: proc(vm: ^VM, name: string) -> (^core.Class_Object, bool) {
	key := core.intern_string(name)
	if v, ok := vm.builtins[key]; ok && v.type == .Obj && v.obj_type == .Class {
		return core.as_class(v), true
	}
	slot := core.env_slot_for_name(vm.environment, name)
	if slot >= 0 && slot < len(vm.environment.globals) && vm.environment.defined[slot] {
		v := vm.environment.globals[slot]
		if v.type == .Obj && v.obj_type == .Class {
			return core.as_class(v), true
		}
	}
	return nil, false
}

pop_handler :: proc(vm: ^VM) {
	f := frame(vm)
	if f.handlers != nil {
		f.handlers = f.handlers.prev
	}
}

// raise_exception is the whole matching engine. err must already be a
// real exception instance (see ensure_exception_instance). Returns true
// once a handler has claimed it -- the current frame's ip and handler
// list are left positioned at the matching clause's body, ready for
// run()'s dispatch loop to just continue -- or false if nothing caught
// it anywhere up to exception_floor, meaning the caller should report
// an uncaught exception.
raise_exception :: proc(vm: ^VM, err: core.Value) -> bool {
	err_class := exception_class_of(err)

	for {
		for h := frame(vm).handlers; h != nil; h = h.prev {
			vm.stack_top = h.stack_top
			push(vm, err)
			frame(vm).ip = h.except_ip

			if match_clause_chain(vm, h, err_class) {
				return true
			}
			// This handler's own clause chain didn't match -- fall back
			// to h.prev (an enclosing try in the *same* frame) before
			// giving up on the frame entirely.
		}
		if !pop_frame_for_exception(vm) {
			return false
		}
	}
}

// match_clause_chain walks h's try statement's own Except/Finally
// clauses (starting at frame.ip, already positioned at the first one)
// looking for a match. On success, leaves frame.ip at the matching
// clause's body and pops h off the handler list.
@(private = "file")
match_clause_chain :: proc(vm: ^VM, h: ^Exception_Handler, err_class: ^core.Class_Object) -> bool {
	code := frame(vm).closure.function.chunk.code
	for {
		clause_start := frame(vm).ip
		op := core.Op_Code(code[clause_start])

		if op == .Finally {
			frame(vm).handlers = h.prev
			return true
		}

		// op == .Except: [op][type_const][skip_hi][skip_lo]
		type_const := code[clause_start + 1]
		skip := int(code[clause_start + 2]) << 8 | int(code[clause_start + 3])

		class_val := frame(vm).closure.function.chunk.constants[type_const]
		handler_class, found := resolve_class_by_name(vm, core.string_get(core.as_string(class_val)))

		if found && err_class != nil && core.is_subclass_of(err_class, handler_class) {
			frame(vm).ip = clause_start + 4 // past Except's own operands, at the clause body
			frame(vm).handlers = h.prev
			return true
		}

		next_clause := clause_start + 4 + skip
		if next_clause >= len(code) {
			return false // no more clauses in this try
		}
		frame(vm).ip = next_clause
	}
}

// pop_frame_for_exception unwinds the current top frame, refusing once
// that top frame's own index (frame_count-1) would be at or below
// exception_floor -- i.e. once frame_count <= exception_floor+1, not
// frame_count <= exception_floor (an off-by-one that let the *last*
// frame at the floor itself be popped, dropping frame_count to 0 and
// crashing the next loop iteration's frame(vm) call: found via every
// single "should be an uncaught runtime error" test in vm_test.odin
// crashing instead of returning cleanly).
pop_frame_for_exception :: proc(vm: ^VM) -> bool {
	if vm.frame_count <= vm.exception_floor + 1 {
		return false
	}
	close_upvalues(vm, frame(vm).slots)
	vm.frame_count -= 1
	return true
}
