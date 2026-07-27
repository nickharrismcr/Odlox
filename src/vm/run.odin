package vm

import "../core"
import "core:fmt"

// The main opcode dispatch loop. Run_Mode.Current_Function backs the
// nested, re-entrant call glox calls its "RUN_CURRENT_FUNCTION" mode --
// not yet exercised by anything in this phase (the user-level foreach
// iterator protocol and instance toString dispatch that would use it
// are both documented, deferred gaps -- see foreach.odin and this
// file's Op_Str case), but the mode exists now so those can be added
// later without reshaping run() itself.
Run_Mode :: enum {
	To_Completion,
	Current_Function,
}

// Frame_Locals hoists the current frame's hot-path fields into local
// variables -- Odin has no closure-over-mutable-outer-locals the way
// Go does, so this is a small value returned by refresh_frame and
// reassigned at every call site that might change frame_count, rather
// than glox's `refreshFrame()` closure mutating captured variables in
// place. Same reasoning either way: re-deriving `frame(vm)` and
// chasing `.closure.function.chunk...` on every single instruction
// would be needless indirection on the hottest path in the VM.
@(private = "file")
Frame_Locals :: struct {
	f:         ^Call_Frame,
	fn:        ^core.Function_Object,
	constants: []core.Value,
	code:      []u8,
}

@(private = "file")
refresh_frame :: proc(vm: ^VM) -> Frame_Locals {
	f := frame(vm)
	fn := f.closure.function
	return Frame_Locals{
		f = f,
		fn = fn,
		constants = fn.chunk.constants[:],
		code = fn.chunk.code[:],
	}
}

// display_string shows a string Value as its raw text, not its quoted
// representation -- core.value_to_string's `"..."` quoting exists for
// nested display (a string inside a printed list/dict) and for
// round-trip-able output; neither applies to a top-level `print`
// statement, or to a raised value's own .msg field (wrapping `raise
// "boom"` should produce a message reading `boom`, not `"boom"` --
// found via exactly that mismatch during Phase 4's first end-to-end
// exception test). Package-visible so exceptions.odin's
// ensure_exception_instance can share it.
display_string :: proc(v: core.Value) -> string {
	if core.is_string(v) {
		return core.string_get(core.as_string(v))
	}
	return core.value_to_string(v)
}

@(private = "file")
print_value :: proc(v: core.Value) {
	fmt.println(display_string(v))
}

@(private = "file")
is_falsey :: proc(v: core.Value) -> bool {
	if v.type == .Nil {
		return true
	}
	if v.type == .Bool {
		return v.data == 0
	}
	return false
}

@(private = "file")
read_u16 :: proc(code: []u8, ip: int) -> int {
	return int(code[ip]) << 8 | int(code[ip + 1])
}

run :: proc(vm: ^VM, mode: Run_Mode) -> (Interpret_Result, core.Value) {
	start_frame := vm.frame_count
	saved_floor := vm.exception_floor
	if mode == .Current_Function {
		vm.exception_floor = start_frame - 1
	}
	defer vm.exception_floor = saved_floor

	fl := refresh_frame(vm)

	// ip is a genuine loop-local mirror of fl.f.ip -- not a struct field
	// read through the fl.f pointer on every single opcode/operand byte
	// the way `fl.f.ip` was before. See docs/ARCHITECTURE.md's VM
	// dispatch loop section: the documented design called for a raw
	// `ip: ^u8` pointer specifically, reasoning that Go can't do this
	// (no safe raw-pointer-into-slice idiom) but Odin can. That's true,
	// but beside the point once `-no-bounds-check` is already the
	// release flag (see bin/build.sh): `fl.code[ip]` for a hoisted `int`
	// local and `ip^`/`ip[0]` for a hoisted `^u8` compile to identical
	// pointer arithmetic either way -- bounds checking, not pointer-vs-
	// int, is the only thing that idiom was ever buying in C/clox. The
	// actual, load-bearing property is just "a genuine local, not a
	// pointer-chased struct field, for the loop's whole body" -- Odin
	// has no aliasing reason to reload a plain local from fl.f between
	// sync points, so the optimizer keeps it register-resident, and an
	// int stays a drop-in match for every other place in the codebase
	// that already treats ip as a plain offset (exceptions.odin,
	// debug/inspect.odin, chunk line lookups) with zero conversion.
	//
	// Sync discipline: every existing point in this loop that already
	// called refresh_frame() (because frame_count might have changed)
	// re-seeds `ip` from the new fl.f.ip right after; every call this
	// loop makes into anything that could transitively read or
	// reposition *this* frame's ip while it's suspended --
	// call_value/invoke/do_super_invoke, raise_exception,
	// do_foreach/do_next, and the per-opcode debug hook -- writes
	// `fl.f.ip = ip` immediately before the call. Verified exhaustively
	// against every other reader of Call_Frame.ip in the codebase
	// (exceptions.odin's stack-trace/handler-matching, debug/
	// inspect.odin's frame introspection natives, debug/trace.odin's
	// disassembler): all of them are only ever reached via one of these
	// same call points, so this set of sync points is complete.
	ip := fl.f.ip

	for {
		// Safe to collect here, and only here -- see gc.odin's
		// maybe_collect_garbage doc comment on why checking between
		// instructions (never mid-opcode) removes the need for
		// glox's "pre-mark a just-linked object" trick entirely.
		maybe_collect_garbage(vm)

		if vm.debug_hook != nil {
			fl.f.ip = ip
			vm.debug_hook(vm, .Opcode)
		}

		instr := core.Op_Code(fl.code[ip])
		ip += 1

		#partial switch instr {

		// --- stack/const primitives ---
		case .Noop:
		// nothing
		case .Constant:
			idx := fl.code[ip]
			ip += 1
			push(vm, fl.constants[idx])
		case .Nil:
			push(vm, core.NIL_VALUE)
		case .True:
			push(vm, core.make_bool_value(true))
		case .False:
			push(vm, core.make_bool_value(false))
		case .One:
			push(vm, core.make_int_value(1))
		case .Pop:
			pop(vm)
		case .Dup:
			push(vm, peek(vm, 0))

		// --- arithmetic (see arithmetic.odin) ---
		case .Negate:
			negate(vm)
		case .Add_Numeric:
			add_numeric(vm)
		case .Concat:
			concat(vm)
		case .Add_Vector:
			add_vector(vm)
		case .Subtract, .Multiply, .Divide, .Modulus:
			numeric_binop(vm, instr)

		// --- self-specializing peephole family ---
		// Add_Nn/Incr_Const_N are always local-slot-indexed by
		// construction (see compiler/compiler_state.odin's
		// peephole_optimise). On a monomorphic int/int or float/float
		// hit, patch this call site's opcode byte in place to the
		// _Ii/_Ff child so every later execution skips the type check
		// entirely -- a minimal inline cache, mirroring glox's own
		// OP_ADD_NN/OP_INCR_CONST_N (vm.go) exactly, including *not*
		// patching a mixed-type site (it just computes the generic
		// float result and stays Add_Nn/Incr_Const_N forever, same as
		// glox). fl.code aliases the chunk's own backing array (see
		// refresh_frame), so the patch is a real, persistent bytecode
		// rewrite, not a per-call cache.
		case .Add_Nn:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip += 2
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Add_Ii)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) + core.as_int(b))
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Add_Ff)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) + core.as_float(b))
			} else {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) + core.as_float(b))
			}
		case .Add_Ii:
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip += 2
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) + core.as_int(b))
		case .Add_Ff:
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip += 2
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) + core.as_float(b))
		case .Incr_Const_N:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip += 2
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Incr_Const_I)
				vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) + core.as_int(b))
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Incr_Const_F)
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) + core.as_float(b))
			} else {
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) + core.as_float(b))
			}
		case .Incr_Const_I:
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip += 2
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) + core.as_int(b))
		case .Incr_Const_F:
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip += 2
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) + core.as_float(b))
		case .Inc_Local:
			// Not currently emitted by the compiler (see
			// compiler/rules.odin's note on Plus_Plus meaning vector
			// add, not increment) -- implemented for completeness
			// since the opcode exists, unreachable from real programs.
			slot := fl.code[ip]
			ip += 1
			v := vm.stack[fl.f.slots + int(slot)]
			#partial switch v.type {
			case .Int:
				vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(v) + 1)
			case .Float:
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(v) + 1)
			case:
				runtime_error(vm, "Operand must be a number.")
			}

		// --- comparisons ---
		case .Not:
			push(vm, core.make_bool_value(is_falsey(pop(vm))))
		case .Equal:
			b := pop(vm)
			a := pop(vm)
			push(vm, core.make_bool_value(core.values_equal(a, b, false)))
		case .Greater, .Less:
			compare(vm, instr)

		// --- print / stringify ---
		case .Print:
			print_value(pop(vm))
		case .Str:
			// Dispatches to a user-defined toString() method on an
			// Instance receiver, if one exists. Deliberately does *not*
			// use a nested run(vm, .Current_Function) call the way
			// Op_Foreach/Op_Next do (see foreach.odin) -- unlike those,
			// which need the call's result back *within* the same
			// opcode's own handling to decide what to do next, Op_Str's
			// call is the very last thing this case does. Peeking
			// (never popping) the receiver, then just calling
			// call_value + refresh_frame and falling out of the switch
			// normally, pushes a new frame and lets the *outer* dispatch
			// loop run it -- when toString's own Op_Return eventually
			// fires, its ordinary return handling (pop back to
			// fl.f.slots, push the result) leaves exactly the string
			// result sitting where the original receiver was, which is
			// exactly Op_Str's contract. Same trick glox's own OP_STR
			// uses (`continue` after `vm.call(...)`/`refreshFrame()`,
			// no vm.run(RUN_CURRENT_FUNCTION) there either -- that mode
			// is reserved for Op_Foreach/Op_Next, whose call result
			// really is needed mid-opcode).
			v := peek(vm, 0)
			if core.is_string(v) {
				// already a string; nothing to do
			} else if v.type == .Obj && v.obj_type == .Instance {
				inst := core.as_instance(v)
				if method_val, ok := inst.class.methods[core.intern_string("toString")]; ok {
					fl.f.ip = ip
					if call_value(vm, method_val, 0) {
						fl = refresh_frame(vm)
						ip = fl.f.ip
					}
				} else {
					pop(vm)
					push(vm, core.make_string_value(core.value_to_string(v)))
				}
			} else {
				pop(vm)
				push(vm, core.make_string_value(core.value_to_string(v)))
			}

		// --- globals ---
		//
		// Real bug, found while porting the .lox standard library: every
		// one of these four cases used vm.environment (the *running VM
		// instance's own* Environment field) instead of the *currently
		// executing frame's function's own* environment (fl.fn.environment,
		// already hoisted by refresh_frame -- every Function_Object
		// records which Environment it was compiled against, see
		// compiler_state.odin's init_root_compiler/init_function_compiler).
		// Those are only the same Environment for the top-level script
		// itself. The moment an *imported module's* function is called --
		// e.g. `math.sin(x)`, where math.lox's own `sin` body calls
		// `_sin(angle)`, a global reference -- the Closure being executed
		// belongs to the module's own Environment (built by its own,
		// separate sub-VM compile in module.odin's load_module), but
		// global reads/writes were resolving against the *importing
		// script's* vm.environment instead: a completely different global
		// slot space. Any imported function that referenced a global at
		// all (calling another top-level function in its own module,
		// reading a module-level var, or calling an underscore-prefixed
		// native like _sin) read/wrote the wrong slot or hit "Undefined
		// variable '#N'" outright. Reproduced with the simplest possible
		// case: a two-function module where one calls the other by name.
		// Fixed by resolving through fl.fn.environment throughout --
		// correct for the top-level script too, since Function_Object.environment
		// there is set to the same vm.environment Compile() was called
		// with in the first place.
		case .Define_Global:
			slot := fl.code[ip]
			ip += 1
			core.env_set_global(fl.fn.environment, int(slot), pop(vm))
		case .Define_Global_Const:
			slot := fl.code[ip]
			ip += 1
			v := pop(vm)
			v.immutable = true
			core.env_set_global(fl.fn.environment, int(slot), v)
		case .Get_Global:
			slot := fl.code[ip]
			ip += 1
			if int(slot) >= len(fl.fn.environment.defined) || !fl.fn.environment.defined[slot] {
				runtime_error(vm, "Undefined variable '%s'.", core.env_name_for_slot(fl.fn.environment, int(slot)))
			} else {
				push(vm, fl.fn.environment.globals[slot])
			}
		case .Set_Global:
			slot := fl.code[ip]
			ip += 1
			if int(slot) >= len(fl.fn.environment.defined) || !fl.fn.environment.defined[slot] {
				runtime_error(vm, "Undefined variable '%s'.", core.env_name_for_slot(fl.fn.environment, int(slot)))
			} else if fl.fn.environment.globals[slot].immutable {
				runtime_error(vm, "Cannot assign to const variable '%s'.", core.env_name_for_slot(fl.fn.environment, int(slot)))
			} else {
				core.env_set_global(fl.fn.environment, int(slot), peek(vm, 0))
			}

		// --- locals / upvalues ---
		case .Get_Local:
			slot := fl.code[ip]
			ip += 1
			push(vm, vm.stack[fl.f.slots + int(slot)])
		case .Set_Local:
			slot := fl.code[ip]
			ip += 1
			vm.stack[fl.f.slots + int(slot)] = peek(vm, 0)
		case .Get_Upvalue:
			slot := fl.code[ip]
			ip += 1
			push(vm, fl.f.closure.upvalues[slot].location^)
		case .Set_Upvalue:
			slot := fl.code[ip]
			ip += 1
			fl.f.closure.upvalues[slot].location^ = peek(vm, 0)
		case .Close_Upvalue:
			close_upvalues(vm, vm.stack_top - 1)
			pop(vm)

		// --- jumps ---
		case .Jump_If_False:
			offset := read_u16(fl.code, ip)
			ip += 2
			if is_falsey(peek(vm, 0)) {
				ip += offset
			}
		case .Jump:
			offset := read_u16(fl.code, ip)
			ip += 2
			ip += offset
		case .Loop:
			offset := read_u16(fl.code, ip)
			ip += 2
			ip -= offset
		case .Jump_If_Defined:
			slot := fl.code[ip]
			offset := read_u16(fl.code, ip + 1)
			ip += 3
			if vm.stack[fl.f.slots + int(slot)].type != .Undefined {
				ip += offset
			}

		// --- calls ---
		case .Call:
			arg_count := int(fl.code[ip])
			ip += 1
			fl.f.ip = ip
			if call_value(vm, peek(vm, arg_count), arg_count) {
				fl = refresh_frame(vm)
				ip = fl.f.ip
			}
		case .Invoke:
			name_const := fl.code[ip]
			arg_count := int(fl.code[ip + 1])
			cache_idx := fl.code[ip + 2]
			ip += 3
			name := core.as_string(fl.constants[name_const])
			fl.f.ip = ip
			if invoke(vm, name, arg_count, &fl.fn.chunk.property_caches[cache_idx]) {
				fl = refresh_frame(vm)
				ip = fl.f.ip
			}
		case .Super_Invoke:
			name_const := fl.code[ip]
			arg_count := int(fl.code[ip + 1])
			ip += 2
			name := core.as_string(fl.constants[name_const])
			fl.f.ip = ip
			if do_super_invoke(vm, name, arg_count) {
				fl = refresh_frame(vm)
				ip = fl.f.ip
			}

		case .Return:
			result := pop(vm)
			close_upvalues(vm, fl.f.slots)
			vm.frame_count -= 1
			if vm.debug_hook != nil {
				fl.f.ip = ip
				vm.debug_hook(vm, .Return)
			}
			if mode == .Current_Function && vm.frame_count == start_frame - 1 {
				vm.stack_top = fl.f.slots
				return .Ok, result
			}
			if vm.frame_count == 0 {
				vm.stack_top = fl.f.slots
				return .Ok, result
			}
			vm.stack_top = fl.f.slots
			push(vm, result)
			fl = refresh_frame(vm)
			ip = fl.f.ip

		// --- closures ---
		case .Closure:
			const_idx := fl.code[ip]
			ip += 1
			fn := core.as_function(fl.constants[const_idx])
			closure := core.make_closure_object(fn)
			gc_track(vm, &closure.obj)
			for i in 0 ..< fn.upvalue_count {
				is_local := fl.code[ip]
				index := fl.code[ip + 1]
				ip += 2
				if is_local == 1 {
					closure.upvalues[i] = capture_upvalue(vm, fl.f.slots + int(index))
				} else {
					closure.upvalues[i] = fl.f.closure.upvalues[index]
				}
			}
			push(vm, core.make_object_value(&closure.obj))

		// --- collections (see collections.odin) ---
		case .Create_List:
			count := int(fl.code[ip])
			ip += 1
			create_list(vm, count, false)
		case .Create_Tuple:
			count := int(fl.code[ip])
			ip += 1
			create_list(vm, count, true)
		case .Create_Dict:
			count := int(fl.code[ip])
			ip += 1
			create_dict(vm, count)
		case .Index:
			do_index(vm)
		case .Index_Assign:
			do_index_assign(vm)
		case .Slice:
			do_slice(vm)
		case .Slice_Assign:
			do_slice_assign(vm)
		case .In:
			do_in(vm)
		case .Unpack:
			count := int(fl.code[ip])
			ip += 1
			do_unpack(vm, count)

		// --- classes / properties (see properties.odin) ---
		case .Class:
			name_const := fl.code[ip]
			ip += 1
			do_class(vm, core.string_get(core.as_string(fl.constants[name_const])))
		case .Inherit:
			do_inherit(vm)
		case .Method:
			name_const := fl.code[ip]
			ip += 1
			do_method(vm, core.string_get(core.as_string(fl.constants[name_const])), false)
		case .Static_Method:
			name_const := fl.code[ip]
			ip += 1
			do_method(vm, core.string_get(core.as_string(fl.constants[name_const])), true)
		case .Class_Var:
			name_const := fl.code[ip]
			ip += 1
			do_class_var(vm, core.string_get(core.as_string(fl.constants[name_const])))
		case .Get_Property:
			name_const := fl.code[ip]
			cache_idx := fl.code[ip + 1]
			ip += 2
			get_property(vm, core.as_string(fl.constants[name_const]), &fl.fn.chunk.property_caches[cache_idx])
		case .Set_Property:
			name_const := fl.code[ip]
			ip += 1
			set_property(vm, core.as_string(fl.constants[name_const]))
		case .Get_Super:
			name_const := fl.code[ip]
			ip += 1
			do_get_super(vm, core.as_string(fl.constants[name_const]))

		// --- foreach (see foreach.odin) ---
		case .Foreach:
			var_slot := fl.code[ip]
			iter_slot := fl.code[ip + 1]
			end_offset := read_u16(fl.code, ip + 2)
			ip += 4
			fl.f.ip = ip
			ip += do_foreach(vm, fl.f.slots, var_slot, iter_slot, end_offset)
		case .Next:
			jump_offset := read_u16(fl.code, ip)
			var_slot := fl.code[ip + 2]
			iter_slot := fl.code[ip + 3]
			ip += 4
			fl.f.ip = ip
			if do_next(vm, fl.f.slots, var_slot, iter_slot) {
				ip -= jump_offset
			}
		case .End_Foreach:
		// no-op landing marker

		// --- exceptions (see exceptions.odin; bytecode shape in
		// compiler/stmt.odin's try_except_statement) ---
		case .Try:
			offset := read_u16(fl.code, ip)
			ip += 2
			h := new(Exception_Handler)
			h.except_ip = ip + offset
			h.stack_top = vm.stack_top
			h.prev = fl.f.handlers
			fl.f.handlers = h
		case .End_Try:
			// Real bug, found via an actual "try { ... } finally { ... }"
			// run with no exception raised: the compiler emits a real,
			// non-zero forward jump here (stmt.odin's try_except_statement
			// patches normal_end_jump with the distance past the
			// exceptional-path finally replay, straight to the
			// normal-path finally replay -- see that proc's "Shared
			// normal-completion landing point" comment), but this case
			// was treating the offset as inert padding (the two
			// operand bytes were just skipped, not read and applied),
			// on the wrong assumption that "the compiler always emits
			// 0,0 here". It doesn't -- normal completion fell straight
			// through into the *exceptional* finally copy instead of
			// jumping past it, which ends in an unconditional Op_Raise
			// (re-propagate) -- so every try/finally with no except
			// clause raised a bogus uncaught exception on perfectly
			// normal completion. Fixed to actually jump, same pattern
			// as Op_Jump.
			offset := read_u16(fl.code, ip)
			ip += 2
			ip += offset
			pop_handler(vm)
		case .End_Except, .Finally:
		// no-op landing markers -- reached only by normal fallthrough;
		// the exceptional path jumps here via raise_exception, which
		// repositions frame.ip directly rather than "executing into" it.
		case .Raise:
			err := ensure_exception_instance(vm, pop(vm))
			fl.f.ip = ip
			if !raise_exception(vm, err) {
				vm.error_msg = format_uncaught_exception(err)
				return .Runtime_Error, core.NIL_VALUE
			}
			fl = refresh_frame(vm)
			ip = fl.f.ip

		// --- imports (see module.odin) ---
		case .Import:
			name_const := fl.code[ip]
			alias_const := fl.code[ip + 1]
			ip += 2
			do_import(
				vm,
				core.string_get(core.as_string(fl.constants[name_const])),
				core.string_get(core.as_string(fl.constants[alias_const])),
			)
		case .Import_From:
			module_const := fl.code[ip]
			count := int(fl.code[ip + 1])
			ip += 2
			names := make([dynamic]string, count)
			for i in 0 ..< count {
				names[i] = core.string_get(core.as_string(fl.constants[fl.code[ip]]))
				ip += 1
			}
			do_import_from(vm, core.string_get(core.as_string(fl.constants[module_const])), names[:])
			delete(names)

		case .Breakpoint:
		// no-op for now -- Phase 5's debugger would hook here.

		case:
			runtime_error(vm, "Invalid opcode.")
		}

		// Shared error-conversion tail, matching glox's design: opcodes/
		// natives set vm.error_msg rather than raising directly (see
		// vm.odin's runtime_error doc comment), and this is the one
		// place that turns it into a real exception, checked once per
		// instruction rather than after every single fallible operation.
		if vm.error_msg != "" {
			msg := vm.error_msg
			class_name := vm.pending_exception_class if vm.pending_exception_class != "" else "RunTimeError"
			vm.error_msg = ""
			vm.pending_exception_class = ""
			err_inst := make_named_error_instance(vm, class_name, msg)
			fl.f.ip = ip
			if !raise_exception(vm, err_inst) {
				vm.error_msg = format_uncaught_exception(err_inst)
				return .Runtime_Error, core.NIL_VALUE
			}
			fl = refresh_frame(vm)
			ip = fl.f.ip
		}
	}
}

@(private = "file")
make_named_error_instance :: proc(vm: ^VM, class_name: string, msg: string) -> core.Value {
	class_val, ok := vm.builtins[core.intern_string(class_name)]
	if !ok {
		class_val = vm.builtins[core.intern_string("RunTimeError")]
	}
	inst := core.make_instance_object(core.as_class(class_val))
	gc_track(vm, &inst.obj)
	inst.fields[core.intern_string("msg")] = core.make_string_value(msg)
	inst.fields[core.intern_string("name")] = core.make_string_value(class_name)
	return core.make_object_value(&inst.obj)
}
