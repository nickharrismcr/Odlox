package vm

import "../core"
import "core:fmt"

// The main opcode dispatch loop. Run_Mode.Current_Function backs the
// nested, re-entrant call used by the user-level foreach iterator
// protocol and instance toString dispatch -- see foreach.odin and this
// file's Op_Str case.
Run_Mode :: enum {
	To_Completion,
	Current_Function,
}

// Frame_Locals hoists the current frame's hot-path fields into local
// variables -- a small value returned by refresh_frame and reassigned
// at every call site that might change frame_count. Re-deriving
// `frame(vm)` and chasing `.closure.function.chunk...` on every single
// instruction would be needless indirection on the hottest path in the
// VM.
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
// "boom"` should produce a message reading `boom`, not `"boom"`).
// Package-visible so exceptions.odin's ensure_exception_instance can
// share it.
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

	// ip is a genuine loop-local mirror of fl.f.ip, kept as a plain int
	// rather than a struct field read through the fl.f pointer on every
	// single opcode/operand byte. See docs/ARCHITECTURE.md's VM
	// dispatch loop section for more on this design. The load-bearing
	// property is that it's a genuine local, not a pointer-chased
	// struct field, for the loop's whole body: Odin has no aliasing
	// reason to reload a plain local from fl.f between sync points, so
	// the optimizer keeps it register-resident, and a plain int matches
	// every other place in the codebase that already treats ip as a
	// plain offset (exceptions.odin, debug/inspect.odin, chunk line
	// lookups) with zero conversion.
	//
	// Sync discipline: every existing point in this loop that already
	// calls refresh_frame() (because frame_count might have changed)
	// re-seeds `ip` from the new fl.f.ip right after; every call this
	// loop makes into anything that could transitively read or
	// reposition *this* frame's ip while it's suspended --
	// call_value/invoke/do_super_invoke, raise_exception,
	// do_foreach/do_next, and the per-opcode debug hook -- writes
	// `fl.f.ip = ip` immediately before the call. Every other reader of
	// Call_Frame.ip in the codebase (exceptions.odin's stack-trace/
	// handler-matching, debug/inspect.odin's frame introspection
	// natives, debug/trace.odin's disassembler) is only ever reached
	// via one of these same call points, so this set of sync points is
	// complete.
	ip := fl.f.ip

	for {
		// Safe to collect here, and only here -- see gc.odin's
		// maybe_collect_garbage doc comment on why checking between
		// instructions (never mid-opcode) keeps the value stack always
		// consistent for root scanning.
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
		// entirely -- a minimal inline cache. A mixed-type site is
		// deliberately never patched: it just computes the generic
		// float result and stays Add_Nn/Incr_Const_N forever. fl.code
		// aliases the chunk's own backing array (see refresh_frame), so
		// the patch is a real, persistent bytecode rewrite, not a
		// per-call cache.
		case .Add_Nn:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
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
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) + core.as_int(b))
		case .Add_Ff:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) + core.as_float(b))
		case .Incr_Const_N:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
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
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) + core.as_int(b))
		case .Incr_Const_F:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) + core.as_float(b))

		// --- self-specializing vector-add family ---
		// Same peephole-fusion-plus-runtime-specialization shape as
		// Add_Nn above, with one deliberate divergence: Add_V2/V3/V4
		// re-check their operand types on every execution (arithmetic.odin's
		// vec_add_dispatch) instead of trusting the first patch forever.
		// A mismatched-type or non-vector operand is always a genuine Lox
		// bug (add_vector already raises on it, unfused) -- unlike
		// Add_Ii/Add_Ff, where int/float coercion has no failure mode to
		// guard against, a dynamically-typed call site that's all-Vec2 on
		// one call and all-Vec3 on a later call must not silently run the
		// wrong arity's lane math. See docs/plans/vec-op-peephole.md.
		case .Add_Vv:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			result, specialize_to, ok := vec_add_dispatch(vm, a, b)
			if ok {
				fl.code[op_ip] = u8(specialize_to)
				vm.stack[fl.f.slots + int(slot_a)] = result
			}
		case .Add_V2:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Vec2 && b.type == .Vec2 {
				av, bv := core.as_vec2(a), core.as_vec2(b)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_vec2_value(av.x + bv.x, av.y + bv.y)
			} else {
				result, specialize_to, ok := vec_add_dispatch(vm, a, b)
				if ok {
					fl.code[op_ip] = u8(specialize_to)
					vm.stack[fl.f.slots + int(slot_a)] = result
				}
			}
		case .Add_V3:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Vec3 && b.type == .Vec3 {
				av, bv := core.as_vec3(a), core.as_vec3(b)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_vec3_value(av.x + bv.x, av.y + bv.y, av.z + bv.z)
			} else {
				result, specialize_to, ok := vec_add_dispatch(vm, a, b)
				if ok {
					fl.code[op_ip] = u8(specialize_to)
					vm.stack[fl.f.slots + int(slot_a)] = result
				}
			}
		case .Add_V4:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Vec4 && b.type == .Vec4 {
				av, bv := core.as_vec4(a), core.as_vec4(b)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_vec4_value(av.x + bv.x, av.y + bv.y, av.z + bv.z, av.w + bv.w)
			} else {
				result, specialize_to, ok := vec_add_dispatch(vm, a, b)
				if ok {
					fl.code[op_ip] = u8(specialize_to)
					vm.stack[fl.f.slots + int(slot_a)] = result
				}
			}

		// --- self-specializing subtract/multiply/divide families ---
		// Same peephole-fusion-plus-runtime-specialization shape as
		// Add_Nn, generalized to Subtract/Multiply/Divide -- see
		// chunk.odin's Op_Code doc comment for why the Sub/Mul/Div _Ii/
		// _Ff leaves re-check their type on every execution (falling
		// back to numeric_binop_into_slot, arithmetic.odin, on a miss)
		// instead of trusting the first patch the way Add_Ii/Add_Ff do,
		// and repatch back to the unspecialized _Nn/_Const_N opcode on a
		// miss so a call site that durably changes type re-settles to
		// the right specialization within one call, rather than falling
		// into the (still correct, just slower) fallback path forever.
		case .Sub_Nn:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Sub_Ii)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) - core.as_int(b))
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Sub_Ff)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) - core.as_float(b))
			} else {
				numeric_binop_into_slot(vm, .Subtract, fl.f.slots + int(slot_a), a, b)
			}
		case .Sub_Ii:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) - core.as_int(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Sub_Nn)
				numeric_binop_into_slot(vm, .Subtract, fl.f.slots + int(slot_a), a, b)
			}
		case .Sub_Ff:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Float && b.type == .Float {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) - core.as_float(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Sub_Nn)
				numeric_binop_into_slot(vm, .Subtract, fl.f.slots + int(slot_a), a, b)
			}
		case .Decr_Const_N:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Decr_Const_I)
				vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) - core.as_int(b))
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Decr_Const_F)
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) - core.as_float(b))
			} else {
				numeric_binop_into_slot(vm, .Subtract, fl.f.slots + int(slot), a, b)
			}
		case .Decr_Const_I:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) - core.as_int(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Decr_Const_N)
				numeric_binop_into_slot(vm, .Subtract, fl.f.slots + int(slot), a, b)
			}
		case .Decr_Const_F:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Float && b.type == .Float {
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) - core.as_float(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Decr_Const_N)
				numeric_binop_into_slot(vm, .Subtract, fl.f.slots + int(slot), a, b)
			}

		case .Mul_Nn:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Ii)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) * core.as_int(b))
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Ff)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) * core.as_float(b))
			} else {
				numeric_binop_into_slot(vm, .Multiply, fl.f.slots + int(slot_a), a, b)
			}
		case .Mul_Ii:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) * core.as_int(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Nn)
				numeric_binop_into_slot(vm, .Multiply, fl.f.slots + int(slot_a), a, b)
			}
		case .Mul_Ff:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Float && b.type == .Float {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) * core.as_float(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Nn)
				numeric_binop_into_slot(vm, .Multiply, fl.f.slots + int(slot_a), a, b)
			}
		case .Mul_Const_N:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Const_I)
				vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) * core.as_int(b))
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Const_F)
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) * core.as_float(b))
			} else {
				numeric_binop_into_slot(vm, .Multiply, fl.f.slots + int(slot), a, b)
			}
		case .Mul_Const_I:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) * core.as_int(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Const_N)
				numeric_binop_into_slot(vm, .Multiply, fl.f.slots + int(slot), a, b)
			}
		case .Mul_Const_F:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Float && b.type == .Float {
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) * core.as_float(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Mul_Const_N)
				numeric_binop_into_slot(vm, .Multiply, fl.f.slots + int(slot), a, b)
			}

		// Div_Ii's int branch checks the divisor every execution
		// (bi == 0) regardless of the type-guard discipline above --
		// see chunk.odin's Op_Code doc comment: staying Int says nothing
		// about staying nonzero. Div_Ff has no such check, matching
		// numeric_binop's own float path (float division by zero is
		// ordinary IEEE inf/-inf/nan, not a raised error).
		case .Div_Nn:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Div_Ii)
				bi := core.as_int(b)
				if bi == 0 {
					runtime_error(vm, "Division by zero.")
				} else {
					vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) / bi)
				}
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Div_Ff)
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) / core.as_float(b))
			} else {
				numeric_binop_into_slot(vm, .Divide, fl.f.slots + int(slot_a), a, b)
			}
		case .Div_Ii:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Int && b.type == .Int {
				bi := core.as_int(b)
				if bi == 0 {
					runtime_error(vm, "Division by zero.")
				} else {
					vm.stack[fl.f.slots + int(slot_a)] = core.make_int_value(core.as_int(a) / bi)
				}
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Div_Nn)
				numeric_binop_into_slot(vm, .Divide, fl.f.slots + int(slot_a), a, b)
			}
		case .Div_Ff:
			op_ip := ip - 1
			slot_a := fl.code[ip]
			slot_b := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot_a)]
			b := vm.stack[fl.f.slots + int(slot_b)]
			if a.type == .Float && b.type == .Float {
				vm.stack[fl.f.slots + int(slot_a)] = core.make_float_value(core.as_float(a) / core.as_float(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Div_Nn)
				numeric_binop_into_slot(vm, .Divide, fl.f.slots + int(slot_a), a, b)
			}
		case .Div_Const_N:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				fl.code[op_ip] = u8(core.Op_Code.Div_Const_I)
				bi := core.as_int(b)
				if bi == 0 {
					runtime_error(vm, "Division by zero.")
				} else {
					vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) / bi)
				}
			} else if a.type == .Float && b.type == .Float {
				fl.code[op_ip] = u8(core.Op_Code.Div_Const_F)
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) / core.as_float(b))
			} else {
				numeric_binop_into_slot(vm, .Divide, fl.f.slots + int(slot), a, b)
			}
		case .Div_Const_I:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Int && b.type == .Int {
				bi := core.as_int(b)
				if bi == 0 {
					runtime_error(vm, "Division by zero.")
				} else {
					vm.stack[fl.f.slots + int(slot)] = core.make_int_value(core.as_int(a) / bi)
				}
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Div_Const_N)
				numeric_binop_into_slot(vm, .Divide, fl.f.slots + int(slot), a, b)
			}
		case .Div_Const_F:
			op_ip := ip - 1
			slot := fl.code[ip]
			const_idx := fl.code[ip + 1]
			ip = op_ip + 8
			a := vm.stack[fl.f.slots + int(slot)]
			b := fl.constants[const_idx]
			if a.type == .Float && b.type == .Float {
				vm.stack[fl.f.slots + int(slot)] = core.make_float_value(core.as_float(a) / core.as_float(b))
			} else {
				fl.code[op_ip] = u8(core.Op_Code.Div_Const_N)
				numeric_binop_into_slot(vm, .Divide, fl.f.slots + int(slot), a, b)
			}

		case .Inc_Local:
			// x += 1 as a full statement now compiles to this directly
			// (compiler/emit.odin's peephole_optimise, when the Add_Nn/
			// Incr_Const_N shape's constant operand is exactly 1) --
			// hardcodes +1 with no constant-pool lookup at all, the
			// smallest instruction the increment-by-one shape can reach.
			op_ip := ip - 1
			slot := fl.code[ip]
			ip = op_ip + 8
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
			// exactly Op_Str's contract. Run_Mode.Current_Function is
			// reserved for Op_Foreach/Op_Next, whose call result really
			// is needed mid-opcode.
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
		// Every one of these four cases resolves through
		// fl.fn.environment -- the *currently executing frame's
		// function's own* environment (already hoisted by refresh_frame
		// -- every Function_Object records which Environment it was
		// compiled against, see compiler_state.odin's
		// init_root_compiler/init_function_compiler) -- rather than
		// vm.environment, the *running VM instance's own* Environment
		// field. Those two are only the same Environment for the
		// top-level script itself: an *imported module's* function
		// (e.g. `math.sin(x)`, where math.lox's own `sin` body calls
		// `_sin(angle)`, a global reference) runs as a Closure belonging
		// to the module's own Environment (built by its own, separate
		// sub-VM compile in module.odin's load_module), a completely
		// different global slot space from the importing script's
		// vm.environment. Resolving through fl.fn.environment is
		// correct for the top-level script too, since its own
		// Function_Object.environment is set to the same vm.environment
		// Compile() was called with in the first place.
		case .Define_Global:
			slot := fl.code[ip]
			ip += 1
			// A plain (non-const) declaration always stores a mutable
			// binding, regardless of whether the value itself happens to
			// carry an immutable tag (e.g. a texture/window/tuple/regex-
			// match object -- see natives/gfx.odin's constructors, which
			// return immutable=true Values for reasons unrelated to
			// variable-reassignment semantics entirely). Set_Global below
			// refuses to overwrite a slot whose *currently stored value*
			// is tagged immutable, so clearing the tag here matters: a
			// variable holding an immutable-tagged value must still be
			// freely reassignable by ordinary `=`. Only Define_Global_Const
			// forces the tag on.
			v := pop(vm)
			v.immutable = false
			core.env_set_global(fl.fn.environment, int(slot), v)
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
				// Same reasoning as Define_Global above: an ordinary `=`
				// assignment always leaves the slot mutable, even if the
				// newly assigned value itself happens to carry an
				// immutable tag.
				v := peek(vm, 0)
				v.immutable = false
				core.env_set_global(fl.fn.environment, int(slot), v)
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
			field_slot_table_idx := fl.code[ip + 1]
			ip += 2
			do_class(vm, core.string_get(core.as_string(fl.constants[name_const])), fl.fn.chunk.field_slot_tables[field_slot_table_idx])
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

		// --- compile-time-baked instance field-slot fast path -- see
		// core/chunk.odin's Get_Field_Slot/Set_Field_Slot doc comment.
		// inst.class == fl.f.closure.owner_class is the guard that makes
		// this safe under inheritance: do_inherit copies method closures
		// verbatim into a subclass's method table, so a superclass
		// method's closure (and its baked-in slot index) can run against
		// a subclass instance whose field-slot table wasn't built from
		// the same init -- a mismatch there falls back to the exact same
		// get_property/set_property path Get_Property/Set_Property use,
		// same error behavior, just unoptimized for that one call.
		// Get_Field_Slot additionally requires the slot not be
		// core.UNDEFINED_VALUE (unset), so reading a field before its
		// assignment line inside init still raises the same "Undefined
		// property" error the map path already produces, instead of
		// silently returning nil.
		case .Get_Field_Slot:
			slot := fl.code[ip]
			name_const := fl.code[ip + 1]
			cache_idx := fl.code[ip + 2]
			ip += 3
			receiver := peek(vm, 0)
			inst := core.as_instance(receiver)
			if inst.class == fl.f.closure.owner_class && inst.slots[slot].type != .Undefined {
				pop(vm)
				push(vm, inst.slots[slot])
			} else {
				get_property(vm, core.as_string(fl.constants[name_const]), &fl.fn.chunk.property_caches[cache_idx])
			}
		case .Set_Field_Slot:
			slot := fl.code[ip]
			name_const := fl.code[ip + 1]
			ip += 2
			receiver := peek(vm, 1)
			inst := core.as_instance(receiver)
			if inst.class == fl.f.closure.owner_class {
				value := peek(vm, 0)
				inst.slots[slot] = value
				pop(vm)
				pop(vm)
				push(vm, value)
			} else {
				set_property(vm, core.as_string(fl.constants[name_const]))
			}

		// --- swizzle-component assignment write-back (`v.x = expr`) --
		// see properties.odin's swizzle_assign doc comment. Each reads
		// the receiver straight from its own storage (not off the VM
		// stack -- unlike every Get_* opcode, there's no separate "get"
		// step emitted first; see emit_expr.odin's emit_property), mutates
		// a local copy if it's a vector, writes the mutated whole value
		// back into that same storage, and leaves the assigned scalar on
		// the stack either way -- these compile as the *entire* target
		// half of the assignment, not just the write-back tail of one.
		case .Set_Local_Vec_Field:
			slot := fl.code[ip]
			name_const := fl.code[ip + 1]
			ip += 2
			name := core.as_string(fl.constants[name_const])
			value := peek(vm, 0)
			recv := vm.stack[fl.f.slots + int(slot)]
			mutated, write_back, ok := swizzle_assign(vm, recv, name, value)
			if ok && write_back {
				vm.stack[fl.f.slots + int(slot)] = mutated
			}
		case .Set_Global_Vec_Field:
			slot := fl.code[ip]
			name_const := fl.code[ip + 1]
			ip += 2
			name := core.as_string(fl.constants[name_const])
			value := peek(vm, 0)
			if int(slot) >= len(fl.fn.environment.defined) || !fl.fn.environment.defined[slot] {
				runtime_error(vm, "Undefined variable '%s'.", core.env_name_for_slot(fl.fn.environment, int(slot)))
			} else {
				recv := fl.fn.environment.globals[slot]
				if recv.immutable {
					runtime_error(vm, "Cannot assign to const variable '%s'.", core.env_name_for_slot(fl.fn.environment, int(slot)))
				} else {
					mutated, write_back, ok := swizzle_assign(vm, recv, name, value)
					if ok && write_back {
						core.env_set_global(fl.fn.environment, int(slot), mutated)
					}
				}
			}
		case .Set_Upvalue_Vec_Field:
			slot := fl.code[ip]
			name_const := fl.code[ip + 1]
			ip += 2
			name := core.as_string(fl.constants[name_const])
			value := peek(vm, 0)
			recv := fl.f.closure.upvalues[slot].location^
			mutated, write_back, ok := swizzle_assign(vm, recv, name, value)
			if ok && write_back {
				fl.f.closure.upvalues[slot].location^ = mutated
			}
		case .Set_Property_Vec_Field:
			outer_const := fl.code[ip]
			inner_const := fl.code[ip + 1]
			ip += 2
			outer_name := core.as_string(fl.constants[outer_const])
			inner_name := core.as_string(fl.constants[inner_const])
			value := pop(vm)
			recv := pop(vm)
			container := pop(vm)
			mutated, write_back, ok := swizzle_assign(vm, recv, inner_name, value)
			if ok {
				if write_back {
					set_obj_field(vm, container, outer_name, mutated)
				}
				push(vm, value)
			}
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
			// Reads and applies the forward jump offset the compiler
			// emits here (stmt.odin's try_except_statement patches
			// normal_end_jump with the distance past the
			// exceptional-path finally replay, straight to the
			// normal-path finally replay -- see that proc's "Shared
			// normal-completion landing point" comment), same pattern as
			// Op_Jump. The offset is not always zero: a try/finally with
			// no except clause needs it to skip past the
			// exceptional-path finally replay (which ends in an
			// unconditional Op_Raise, re-propagating) on normal
			// completion.
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
		// no-op -- reserved for a future debugger hook.

		case:
			runtime_error(vm, "Invalid opcode.")
		}

		// Shared error-conversion tail: opcodes/natives set vm.error_msg
		// rather than raising directly (see vm.odin's runtime_error doc
		// comment), and this is the one place that turns it into a real
		// exception, checked once per instruction rather than after
		// every single fallible operation.
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
