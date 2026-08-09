package debug

import "../compiler"
import "../core"
import "core:testing"

// Debug-package tests split into two kinds:
//
//   - "walk a real compiled chunk end to end" tests, which don't check
//     printed output (disassemble_instruction writes straight to
//     stdout, same as clox's own disassembler -- there's no return
//     value to assert on for the *content*) but do check the one
//     invariant that actually matters for correctness: walking from
//     offset 0 via the returned next-offset lands on exactly len(code),
//     for every opcode family the compiler can emit. An off-by-one in
//     any operand-width formula here would desync the walk from real
//     instruction boundaries and either panic on an out-of-range
//     access or never reach the end -- exactly the class of bug this
//     guards against.
//   - hand-built single-instruction tests for the operand shapes that
//     aren't obvious from the opcode name (Except/Foreach/Next/
//     Jump_If_Defined/Closure/Import_From), checking the returned
//     next-offset against the exact byte count each one's emission
//     site (see disassemble.odin's header comments) is documented to
//     use.

@(private = "file")
compile_ok :: proc(t: ^testing.T, source: string) -> ^core.Chunk {
	env := core.make_environment("test")
	fn, ok := compiler.Compile(source, "test.lox", env)
	testing.expectf(t, ok, "expected %q to compile without error", source)
	return fn.chunk
}

// walk_chunk mirrors compile_test.odin's own `decode` helper's job
// (skip exactly the right number of operand bytes per instruction) but
// exercises the real disassembler instead of a second, parallel
// implementation of the same operand-width table -- so a mistake fixed
// in one wouldn't silently persist, undetected, in the other.
@(private = "file")
walk_chunk :: proc(t: ^testing.T, c: ^core.Chunk) {
	offset := 0
	steps := 0
	for offset < len(c.code) {
		next := disassemble_instruction(c, offset)
		testing.expectf(
			t,
			next > offset,
			"disassemble_instruction did not advance at offset %d (opcode %v)",
			offset,
			core.Op_Code(c.code[offset]),
		)
		offset = next
		steps += 1
		if steps > len(c.code) {
			testing.fail_now(t, "walk did not terminate -- offsets are not advancing correctly")
		}
	}
	testing.expect_value(t, offset, len(c.code))
}

@(test)
test_disassemble_walks_kitchen_sink_program :: proc(t: ^testing.T) {
	c := compile_ok(t, `
class Animal {
	__init__(name) {
		this.name = name
	}
	speak() {
		return this.name & " makes a sound"
	}
}

class Dog < Animal {
	speak() {
		return super.speak() & "!"
	}
}

func make_counter(start=0) {
	var count = start
	return func() {
		count += 1
		return count
	}
}

var counter = make_counter()
var total = 0
for var i = 0; i < 5; i += 1 {
	total = total + counter()
}

var animals = [Animal("Cat"), Dog("Rex")]
foreach a in animals {
	print a.speak()
}

var config = {"retries": 3, "timeout": 10}
x, y = 1, 2

try {
	if x == 1 {
		raise "boom"
	}
} except RunTimeError as e {
	print e
} finally {
	print "cleanup"
}

import sys
from math import sqrt, pow
`)
	walk_chunk(t, c)
}

@(test)
test_disassemble_program_recurses_into_nested_functions :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	fn, ok := compiler.Compile("func outer() { func inner() { return 1 } return inner() }\nouter()\n", "test.lox", env)
	testing.expect(t, ok)
	// Just needs to not panic/infinite-loop walking into <fn outer>'s
	// Closure constant for <fn inner> -- see disassemble_program_rec's
	// visited-set guard.
	disassemble_program(fn)
	walk_chunk(t, fn.chunk)
}

// -----------------------------------------------------------------------
// Hand-built single-instruction operand-width checks

@(private = "file")
new_test_chunk :: proc() -> ^core.Chunk {
	return core.new_chunk("test")
}

@(test)
test_except_instruction_width :: proc(t: ^testing.T) {
	c := new_test_chunk()
	type_const := core.chunk_add_constant(c, core.make_string_value("Exception"))
	core.chunk_write_op(c, .Except, 1)
	core.chunk_write_byte(c, type_const, 1)
	core.chunk_write_byte(c, 0, 1) // skip_hi
	core.chunk_write_byte(c, 5, 1) // skip_lo -- next clause 5 bytes past this instruction's operands
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 4) // [op][type_const][skip_hi][skip_lo]
}

@(test)
test_foreach_instruction_width :: proc(t: ^testing.T) {
	c := new_test_chunk()
	core.chunk_write_op(c, .Foreach, 1)
	core.chunk_write_byte(c, 0, 1) // var_slot
	core.chunk_write_byte(c, 1, 1) // iter_slot
	core.chunk_write_byte(c, 0, 1) // end_hi
	core.chunk_write_byte(c, 3, 1) // end_lo
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 5) // [op][var_slot][iter_slot][end_hi][end_lo]
}

@(test)
test_next_instruction_width :: proc(t: ^testing.T) {
	c := new_test_chunk()
	core.chunk_write_op(c, .Next, 1)
	core.chunk_write_byte(c, 0, 1) // jump_hi
	core.chunk_write_byte(c, 9, 1) // jump_lo
	core.chunk_write_byte(c, 0, 1) // var_slot
	core.chunk_write_byte(c, 1, 1) // iter_slot
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 5) // [op][jump_hi][jump_lo][var_slot][iter_slot]
}

@(test)
test_jump_if_defined_instruction_width :: proc(t: ^testing.T) {
	c := new_test_chunk()
	core.chunk_write_op(c, .Jump_If_Defined, 1)
	core.chunk_write_byte(c, 0, 1) // slot
	core.chunk_write_byte(c, 0, 1) // jump_hi
	core.chunk_write_byte(c, 2, 1) // jump_lo
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 4) // [op][slot][jump_hi][jump_lo]
}

@(test)
test_import_from_instruction_width_with_names :: proc(t: ^testing.T) {
	c := new_test_chunk()
	module_const := core.chunk_add_constant(c, core.make_string_value("math"))
	name_a := core.chunk_add_constant(c, core.make_string_value("sqrt"))
	name_b := core.chunk_add_constant(c, core.make_string_value("pow"))
	core.chunk_write_op(c, .Import_From, 1)
	core.chunk_write_byte(c, module_const, 1)
	core.chunk_write_byte(c, 2, 1) // count
	core.chunk_write_byte(c, name_a, 1)
	core.chunk_write_byte(c, name_b, 1)
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 5) // [op][module_const][count][name_a][name_b]
}

@(test)
test_import_from_instruction_width_star :: proc(t: ^testing.T) {
	c := new_test_chunk()
	module_const := core.chunk_add_constant(c, core.make_string_value("math"))
	core.chunk_write_op(c, .Import_From, 1)
	core.chunk_write_byte(c, module_const, 1)
	core.chunk_write_byte(c, 0, 1) // count == 0 means "import everything"
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 3) // [op][module_const][count]
}

@(test)
test_get_super_instruction_is_one_operand_byte :: proc(t: ^testing.T) {
	// Regression test: an earlier version of this disassembler
	// mis-classified Get_Super as a zero-operand opcode, which would
	// desync every instruction after it in any chunk containing a
	// `super.name` reference.
	c := new_test_chunk()
	name_const := core.chunk_add_constant(c, core.make_string_value("speak"))
	core.chunk_write_op(c, .Get_Super, 1)
	core.chunk_write_byte(c, name_const, 1)
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 2) // [op][name_const]
}

@(test)
test_global_slot_is_not_a_constant_pool_index :: proc(t: ^testing.T) {
	// Regression test: Get_Global/Set_Global/Define_Global(_Const)
	// operands are slots into Environment.globals, not indices into
	// this chunk's own constant pool -- an earlier version of this
	// disassembler conflated the two, which happens to be harmless
	// when slot and constant-pool indices are small and coincide, but
	// reads the wrong constant (or panics, out of range) the moment
	// they diverge, e.g. after any constant that doesn't also define a
	// global. Reproduce exactly that: constant 0 is a plain string
	// (never a global), then a global at slot 0 (`x`).
	c := new_test_chunk()
	core.chunk_add_constant(c, core.make_string_value("not a global"))
	append(&c.global_names, "x")
	core.chunk_write_op(c, .Get_Global, 1)
	core.chunk_write_byte(c, 0, 1) // slot 0 -- must resolve to "x", not constant 0
	next := disassemble_instruction(c, 0)
	testing.expect_value(t, next, 2)
}
