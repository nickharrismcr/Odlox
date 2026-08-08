package vm

import "../core"
import "core:fmt"
import "core:path/filepath"

// try/except/finally at the VM level. The bytecode shape this reads is
// documented in stmt.odin's try_except_statement; read that first.
//
// Op_Except carries its own explicit 2-byte skip offset (patched
// exactly like any other jump -- see stmt.odin) pointing straight at
// the next clause, rather than requiring a scan for the next
// Except/Finally opcode in the raw bytecode. A byte-by-byte scan would
// need to track nesting depth to work correctly when a clause body
// itself contains a *nested* try/except (whose own End_Except/Except/
// Finally bytes would otherwise be mistaken for the outer clause's
// terminator); an explicit offset needs no scanning and works through
// nested trys for free.

// bootstrap_exceptions compiles and runs a small embedded Lox source
// string defining the base exception hierarchy (Exception,
// RunTimeError, EOFError) through a disposable sub-VM, then harvests
// the resulting classes into vm.builtins (see docs/ARCHITECTURE.md's
// Native/builtin functions section): far less code than hand-building
// Class_Object graphs, and the hierarchy behaves exactly like any other
// Lox class (inheritance, toString, ...) because it *is* one, compiled
// by this same compiler. toString() returns the bare `this.msg`, with
// no class-name prefix, so `str(e)` on a caught exception yields just
// the message.
@(private = "file")
EXCEPTION_SOURCE :: `
class Exception {
	init(msg) {
		this.msg = msg
		this.name = "Exception"
	}
	toString() {
		return this.msg
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
class PickleError < Exception {
	init(msg) {
		this.msg = msg
		this.name = "PickleError"
	}
}
class ProcessError < Exception {
	init(msg) {
		this.msg = msg
		this.name = "ProcessError"
	}
}
class SocketError < Exception {
	init(msg) {
		this.msg = msg
		this.name = "SocketError"
	}
}`

// bootstrap_cache holds the harvested exception classes after the first
// bootstrap_exceptions call in this process -- every subsequent VM
// (there are many: one per script run in production is normal, but
// module.odin's load_module and the test suite both construct plenty of
// short-lived ones too) just copies from this cache instead of paying
// for a full compile-and-run of EXCEPTION_SOURCE again. Not just a perf
// win: recompiling the same tiny source through a fresh sub-VM dozens of
// times in one process, all hammering the same global string-intern
// table (see obj_string.odin), also risks an Odin-test-runner-specific
// memory-tracking issue under heavy repetition (see
// docs/ARCHITECTURE.md's "No concurrency anywhere" section) -- doing
// the real bootstrap only once per process avoids that entirely.
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
// bootstrap hierarchy and user-defined exception classes. Does not
// check a module's own export vars (see module.odin) separately from
// its globals.
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

// format_uncaught_exception builds the "Uncaught exception: <class> :
// <msg> " report -- note the trailing space baked into the format
// string itself, which is deliberate, not stray whitespace.
format_uncaught_exception :: proc(err: core.Value) -> string {
	inst := core.as_instance(err)
	class_str := core.value_to_string(core.make_object_value(&inst.class.obj))
	// core.instance_get_field, not a raw inst.fields[...] read: built-in
	// exception classes' init bodies set `this.msg` unconditionally at
	// the top level (see EXCEPTION_SOURCE below), exactly the shape
	// compiler/resolve.odin's discover_field_slots slot-optimizes, so
	// `msg` may live in inst.slots instead of inst.fields.
	msg, has_msg := core.instance_get_field(inst, core.intern_string("msg"))
	msg_str := core.value_to_string(msg) if has_msg else "\"\""
	return fmt.aprintf("Uncaught exception: %s : %s ", class_str, msg_str)
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
		append_stack_trace(vm)
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

// clear_stack_trace discards whatever append_stack_trace built up while
// this exception was propagating -- called at both of
// match_clause_chain's successful-match returns (an except clause
// matching, or the always-matching Finally handler). Without this, a
// caught-and-handled exception's trace entries would linger in
// vm.stack_trace and get prepended, stale and misleading, to a *later*
// uncaught exception's real trace within the same interpret() call.
@(private = "file")
clear_stack_trace :: proc(vm: ^VM) {
	delete(vm.stack_trace)
	vm.stack_trace = nil
}

// append_stack_trace records one entry per frame `raise_exception`'s
// unwind loop visits, recorded *before* that frame is popped
// (pop_frame_for_exception below discards the frame outright, taking
// its ip/line info with it -- there's no recovering it afterward). Each
// frame contributes two trace lines: the "File '<script>', line <N>, in
// <function>" location line, and the actual source line's text.
// vm.stack_trace is printed unconditionally on every uncaught error
// (print_stack_trace, vm.odin), not as an opt-in debug feature.
@(private = "file")
append_stack_trace :: proc(vm: ^VM) {
	f := frame(vm)
	if f.closure == nil {
		return
	}
	function := f.closure.function
	where_name := core.string_get(function.name)
	if where_name == "" {
		where_name = "<module>"
	}
	// A frame caught mid-push (e.g. on stack overflow) can have ip == 0,
	// and a finished frame can have ip past the code -- clamp so the
	// line lookup can never index out of range.
	ip := f.ip - 1
	if ip < 0 {
		ip = 0
	}
	if ip >= len(function.chunk.lines) {
		ip = len(function.chunk.lines) - 1
	}
	if ip < 0 {
		return
	}
	line := function.chunk.lines[ip]
	append(&vm.stack_trace, fmt.aprintf("File '%s', line %d, in %s", function.chunk.filename, line, where_name))
	append(&vm.stack_trace, source_line(frame_source(vm, function.chunk.filename), line))
}

// frame_source picks the right source text to pull a trace's context
// line from: vm.source directly if the frame belongs to vm's own
// top-level script, or module_source_cache otherwise -- a frame can
// belong to a function defined in an *imported* module, running as an
// ordinary closure in this vm long after the sub-VM that originally
// compiled that module's source went out of scope (see
// module_source_cache's own doc comment, module.odin).
@(private = "file")
frame_source :: proc(vm: ^VM, chunk_filename: string) -> string {
	if chunk_filename == vm.script {
		return vm.source
	}
	return module_source_cache[filepath.stem(chunk_filename)]
}

// source_line extracts line n (1-indexed, matching every line number
// this compiler/VM tracks -- see scanner.odin's Scanner.line starting at
// 1) from source. Returns an empty string rather than erroring if n is
// out of range (a stale/
// mismatched vm.source, or a line number past the end of a since-
// truncated source) -- a blank context line is a reasonable degradation,
// not worth a second failure mode inside error reporting itself.
@(private = "file")
source_line :: proc(source: string, n: int) -> string {
	start := 0
	current_line := 1
	for i := 0; i < len(source); i += 1 {
		if current_line == n {
			start = i
			for j := i; j < len(source); j += 1 {
				if source[j] == '\n' {
					end := j
					if end > start && source[end - 1] == '\r' {
						end -= 1
					}
					return source[start:end]
				}
			}
			return source[start:]
		}
		if source[i] == '\n' {
			current_line += 1
		}
	}
	return ""
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
			clear_stack_trace(vm)
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
			clear_stack_trace(vm)
			return true
		}

		// next_clause is either the next Except/Finally clause's start,
		// or -- when this was the last clause -- the shared landing
		// point right after the whole try/except construct (the same
		// position normal_end_jump/End_Try's own jump target patches
		// to; see stmt.odin's try_except_statement). Bounds-checking
		// against len(code) alone cannot tell these apart: it only
		// looks "off the end of the chunk", which is only true when
		// this try/except happens to be the very last construct in its
		// function. Any code after it (the overwhelmingly common case)
		// puts a real, in-bounds instruction at next_clause that has
		// nothing to do with exception handling, so this checks what's
		// actually *at* next_clause -- an Except or Finally opcode --
		// rather than just whether the offset is in bounds, before
		// reading it as [type_const][skip_hi][skip_lo].
		next_clause := clause_start + 4 + skip
		if next_clause >= len(code) {
			return false // no more clauses in this try
		}
		next_op := core.Op_Code(code[next_clause])
		if next_op != .Except && next_op != .Finally {
			return false // next_clause is the post-try landing point, not another clause
		}
		frame(vm).ip = next_clause
	}
}

// pop_frame_for_exception unwinds the current top frame, refusing once
// that top frame's own index (frame_count-1) would be at or below
// exception_floor -- i.e. once frame_count <= exception_floor+1, not
// frame_count <= exception_floor. The stricter check matters: the
// looser one would let the *last* frame at the floor itself be popped,
// dropping frame_count to 0 and leaving nothing for the next loop
// iteration's frame(vm) call to read.
pop_frame_for_exception :: proc(vm: ^VM) -> bool {
	if vm.frame_count <= vm.exception_floor + 1 {
		return false
	}
	close_upvalues(vm, frame(vm).slots)
	vm.frame_count -= 1
	return true
}
