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
	return Frame_Locals{f = f, fn = fn, constants = fn.chunk.constants[:], code = fn.chunk.code[:]}
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

	for {
		// Safe to collect here, and only here -- see gc.odin's
		// maybe_collect_garbage doc comment on why checking between
		// instructions (never mid-opcode) removes the need for
		// glox's "pre-mark a just-linked object" trick entirely.
		maybe_collect_garbage(vm)

		if vm.debug_hook != nil {
			vm.debug_hook(vm, .Opcode)
		}

		instr := core.Op_Code(fl.code[fl.f.ip])
		fl.f.ip += 1

		#partial switch instr {

		// --- stack/const primitives ---
		case .Noop:
		// nothing
		case .Constant:
			idx := fl.code[fl.f.ip]
			fl.f.ip += 1
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
		// peephole_optimise) -- read both operands, compute, done. No
		// runtime type-specialization into _Ii/_Ff variants yet (that
		// second-stage inline-cache optimization is a Phase 7 concern,
		// not required for correctness); Add_Nn/Incr_Const_N just do the
		// int/float dispatch directly every time for now.
		case .Add_Nn:
			slot_a := fl.code[fl.f.ip]
			slot_b := fl.code[fl.f.ip + 1]
			fl.f.ip += 2
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) + core.as_int(b))
			} else {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) + core.as_float(b))
			}
		case .Incr_Const_N:
			slot := fl.code[fl.f.ip]
			const_idx := fl.code[fl.f.ip + 1]
			fl.f.ip += 2
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) + core.as_int(b))
			} else {
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) + core.as_float(b))
			}
		case .Inc_Local:
			// Not currently emitted by the compiler (see
			// compiler/rules.odin's note on Plus_Plus meaning vector
			// add, not increment) -- implemented for completeness
			// since the opcode exists, unreachable from real programs.
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
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
			// KNOWN GAP vs. glox: does not dispatch to a user-defined
			// toString() method on an Instance receiver (that needs the
			// nested re-entrant run() call this file's Run_Mode exists
			// for, not yet wired up here) -- falls back to
			// core.value_to_string's generic "<instance ClassName>" for
			// every instance regardless of a toString method.
			v := pop(vm)
			if core.is_string(v) {
				push(vm, v)
			} else {
				push(vm, core.make_string_value(core.value_to_string(v)))
			}

		// --- globals ---
		case .Define_Global:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			core.env_set_global(vm.environment, int(slot), pop(vm))
		case .Define_Global_Const:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			v := pop(vm)
			v.immutable = true
			core.env_set_global(vm.environment, int(slot), v)
		case .Get_Global:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			if int(slot) >= len(vm.environment.defined) || !vm.environment.defined[slot] {
				runtime_error(vm, "Undefined variable '%s'.", core.env_name_for_slot(vm.environment, int(slot)))
			} else {
				push(vm, vm.environment.globals[slot])
			}
		case .Set_Global:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			if int(slot) >= len(vm.environment.defined) || !vm.environment.defined[slot] {
				runtime_error(vm, "Undefined variable '%s'.", core.env_name_for_slot(vm.environment, int(slot)))
			} else if vm.environment.globals[slot].immutable {
				runtime_error(vm, "Cannot assign to const variable '%s'.", core.env_name_for_slot(vm.environment, int(slot)))
			} else {
				core.env_set_global(vm.environment, int(slot), peek(vm, 0))
			}

		// --- locals / upvalues ---
		case .Get_Local:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			push(vm, vm.stack[fl.f.slots + int(slot)])
		case .Set_Local:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			vm.stack[fl.f.slots + int(slot)] = peek(vm, 0)
		case .Get_Upvalue:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			push(vm, fl.f.closure.upvalues[slot].location^)
		case .Set_Upvalue:
			slot := fl.code[fl.f.ip]
			fl.f.ip += 1
			fl.f.closure.upvalues[slot].location^ = peek(vm, 0)
		case .Close_Upvalue:
			close_upvalues(vm, vm.stack_top - 1)
			pop(vm)

		// --- jumps ---
		case .Jump_If_False:
			offset := read_u16(fl.code, fl.f.ip)
			fl.f.ip += 2
			if is_falsey(peek(vm, 0)) {
				fl.f.ip += offset
			}
		case .Jump:
			offset := read_u16(fl.code, fl.f.ip)
			fl.f.ip += 2
			fl.f.ip += offset
		case .Loop:
			offset := read_u16(fl.code, fl.f.ip)
			fl.f.ip += 2
			fl.f.ip -= offset
		case .Jump_If_Defined:
			slot := fl.code[fl.f.ip]
			offset := read_u16(fl.code, fl.f.ip + 1)
			fl.f.ip += 3
			if vm.stack[fl.f.slots + int(slot)].type != .Undefined {
				fl.f.ip += offset
			}

		// --- calls ---
		case .Call:
			arg_count := int(fl.code[fl.f.ip])
			fl.f.ip += 1
			if call_value(vm, peek(vm, arg_count), arg_count) {
				fl = refresh_frame(vm)
			}
		case .Invoke:
			name_const := fl.code[fl.f.ip]
			arg_count := int(fl.code[fl.f.ip + 1])
			fl.f.ip += 2
			name := core.string_get(core.as_string(fl.constants[name_const]))
			if invoke(vm, name, arg_count) {
				fl = refresh_frame(vm)
			}
		case .Super_Invoke:
			name_const := fl.code[fl.f.ip]
			arg_count := int(fl.code[fl.f.ip + 1])
			fl.f.ip += 2
			name := core.string_get(core.as_string(fl.constants[name_const]))
			if do_super_invoke(vm, name, arg_count) {
				fl = refresh_frame(vm)
			}

		case .Return:
			result := pop(vm)
			close_upvalues(vm, fl.f.slots)
			vm.frame_count -= 1
			if vm.debug_hook != nil {
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

		// --- closures ---
		case .Closure:
			const_idx := fl.code[fl.f.ip]
			fl.f.ip += 1
			fn := core.as_function(fl.constants[const_idx])
			closure := core.make_closure_object(fn)
			gc_track(vm, &closure.obj)
			for i in 0 ..< fn.upvalue_count {
				is_local := fl.code[fl.f.ip]
				index := fl.code[fl.f.ip + 1]
				fl.f.ip += 2
				if is_local == 1 {
					closure.upvalues[i] = capture_upvalue(vm, fl.f.slots + int(index))
				} else {
					closure.upvalues[i] = fl.f.closure.upvalues[index]
				}
			}
			push(vm, core.make_object_value(&closure.obj))

		// --- collections (see collections.odin) ---
		case .Create_List:
			count := int(fl.code[fl.f.ip])
			fl.f.ip += 1
			create_list(vm, count, false)
		case .Create_Tuple:
			count := int(fl.code[fl.f.ip])
			fl.f.ip += 1
			create_list(vm, count, true)
		case .Create_Dict:
			count := int(fl.code[fl.f.ip])
			fl.f.ip += 1
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
			count := int(fl.code[fl.f.ip])
			fl.f.ip += 1
			do_unpack(vm, count)

		// --- classes / properties (see properties.odin) ---
		case .Class:
			name_const := fl.code[fl.f.ip]
			fl.f.ip += 1
			do_class(vm, core.string_get(core.as_string(fl.constants[name_const])))
		case .Inherit:
			do_inherit(vm)
		case .Method:
			name_const := fl.code[fl.f.ip]
			fl.f.ip += 1
			do_method(vm, core.string_get(core.as_string(fl.constants[name_const])), false)
		case .Static_Method:
			name_const := fl.code[fl.f.ip]
			fl.f.ip += 1
			do_method(vm, core.string_get(core.as_string(fl.constants[name_const])), true)
		case .Class_Var:
			name_const := fl.code[fl.f.ip]
			fl.f.ip += 1
			do_class_var(vm, core.string_get(core.as_string(fl.constants[name_const])))
		case .Get_Property:
			name_const := fl.code[fl.f.ip]
			fl.f.ip += 1
			get_property(vm, core.string_get(core.as_string(fl.constants[name_const])))
		case .Set_Property:
			name_const := fl.code[fl.f.ip]
			fl.f.ip += 1
			set_property(vm, core.string_get(core.as_string(fl.constants[name_const])))
		case .Get_Super:
			name_const := fl.code[fl.f.ip]
			fl.f.ip += 1
			do_get_super(vm, core.string_get(core.as_string(fl.constants[name_const])))

		// --- foreach (see foreach.odin) ---
		case .Foreach:
			var_slot := fl.code[fl.f.ip]
			iter_slot := fl.code[fl.f.ip + 1]
			end_offset := read_u16(fl.code, fl.f.ip + 2)
			fl.f.ip += 4
			fl.f.ip += do_foreach(vm, fl.f.slots, var_slot, iter_slot, end_offset)
		case .Next:
			jump_offset := read_u16(fl.code, fl.f.ip)
			var_slot := fl.code[fl.f.ip + 2]
			iter_slot := fl.code[fl.f.ip + 3]
			fl.f.ip += 4
			if do_next(vm, fl.f.slots, var_slot, iter_slot) {
				fl.f.ip -= jump_offset
			}
		case .End_Foreach:
		// no-op landing marker

		// --- exceptions (see exceptions.odin; bytecode shape in
		// compiler/stmt.odin's try_except_statement) ---
		case .Try:
			offset := read_u16(fl.code, fl.f.ip)
			fl.f.ip += 2
			h := new(Exception_Handler)
			h.except_ip = fl.f.ip + offset
			h.stack_top = vm.stack_top
			h.prev = fl.f.handlers
			fl.f.handlers = h
		case .End_Try:
			fl.f.ip += 2 // offset unused for a plain handler pop (compiler always emits 0,0 here)
			pop_handler(vm)
		case .End_Except, .Finally:
		// no-op landing markers -- reached only by normal fallthrough;
		// the exceptional path jumps here via raise_exception, which
		// repositions frame.ip directly rather than "executing into" it.
		case .Raise:
			err := ensure_exception_instance(vm, pop(vm))
			if !raise_exception(vm, err) {
				vm.error_msg = core.value_to_string(err)
				return .Runtime_Error, core.NIL_VALUE
			}
			fl = refresh_frame(vm)

		// --- imports (see module.odin) ---
		case .Import:
			name_const := fl.code[fl.f.ip]
			alias_const := fl.code[fl.f.ip + 1]
			fl.f.ip += 2
			do_import(
				vm,
				core.string_get(core.as_string(fl.constants[name_const])),
				core.string_get(core.as_string(fl.constants[alias_const])),
			)
		case .Import_From:
			module_const := fl.code[fl.f.ip]
			count := int(fl.code[fl.f.ip + 1])
			fl.f.ip += 2
			names := make([dynamic]string, count)
			for i in 0 ..< count {
				names[i] = core.string_get(core.as_string(fl.constants[fl.code[fl.f.ip]]))
				fl.f.ip += 1
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
			if !raise_exception(vm, err_inst) {
				vm.error_msg = core.value_to_string(err_inst)
				return .Runtime_Error, core.NIL_VALUE
			}
			fl = refresh_frame(vm)
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
