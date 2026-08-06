package vm

import "../core"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// End-to-end tests for Phase 6a's core builtins -- same "compile and
// actually run it" philosophy as vm_test.odin (see that file's header
// comment), plus define_builtins, which those tests don't need. This
// is what caught every real bug this phase found: format()'s any-
// boxing segfault, the missing Op_Invoke module-dispatch case (every
// built-in module function call fell through to "Undefined method"),
// and file_write's missing `\n`-unescape (this language's string
// literals have no real backslash-escape mechanism at all -- see
// obj_file.odin's file_write doc comment).

@(private = "file")
run_builtins :: proc(t: ^testing.T, source: string, var_name: string) -> core.Value {
	vm_instance := new_vm("test")
	define_builtins(vm_instance)
	status, _ := interpret(vm_instance, source)
	testing.expectf(t, status == .Ok, "expected %q to run without error, got %v: %s", source, status, vm_instance.error_msg)
	if status != .Ok {
		return core.NIL_VALUE
	}
	slot := core.env_slot_for_name(vm_instance.environment, var_name)
	testing.expectf(t, slot >= 0, "expected a global named %q", var_name)
	if slot < 0 || slot >= len(vm_instance.environment.globals) {
		return core.NIL_VALUE
	}
	return vm_instance.environment.globals[slot]
}

// -----------------------------------------------------------------------
// Core free functions

@(test)
test_type_builtin :: proc(t: ^testing.T) {
	v := run_builtins(t, "var result = type(1)\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "int")
}

@(test)
test_len_builtin :: proc(t: ^testing.T) {
	v := run_builtins(t, `var result = len("hello")` + "\n", "result")
	testing.expect_value(t, core.as_int(v), 5)
}

@(test)
test_append_builtin :: proc(t: ^testing.T) {
	v := run_builtins(t, "var a = [1,2]\nappend(a, 3)\nvar result = len(a)\n", "result")
	testing.expect_value(t, core.as_int(v), 3)
}

@(test)
test_append_rejects_tuple :: proc(t: ^testing.T) {
	vm_instance := new_vm("test")
	define_builtins(vm_instance)
	status, _ := interpret(vm_instance, "append((1,2), 3)\n")
	testing.expect_value(t, status, Interpret_Result.Runtime_Error)
}

@(test)
test_float_and_int_conversion :: proc(t: ^testing.T) {
	v := run_builtins(t, `var result = float("3.5")` + "\n", "result")
	testing.expect_value(t, core.as_float(v), 3.5)
	v2 := run_builtins(t, `var result = int("42")` + "\n", "result")
	testing.expect_value(t, core.as_int(v2), 42)
}

@(test)
test_replace_free_function :: proc(t: ^testing.T) {
	v := run_builtins(t, `var result = replace("abcabc", "a", "X")`+"\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "XbcXbc")
}

// Regression test for a real segfault: format()'s first implementation
// boxed converted values into `any` by returning `any` from a helper
// proc, which silently wraps the address of that proc's own return
// temporary -- dangling the moment the proc returned. See builtins.odin's
// format_builtin doc comment for the fix (heap-box inline, never
// return `any` from a helper).
@(test)
test_format_builtin :: proc(t: ^testing.T) {
	v := run_builtins(t, `var result = format("%d %f %s", 1, 2.2, "hi")`+"\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "1 2.200000 hi")
}

@(test)
test_range_builtin_via_foreach :: proc(t: ^testing.T) {
	v := run_builtins(t, "var total = 0\nforeach i in range(5) { total = total + i }\nvar result = total\n", "result")
	testing.expect_value(t, core.as_int(v), 0 + 1 + 2 + 3 + 4)
}

@(test)
test_vec_constructors :: proc(t: ^testing.T) {
	v := run_builtins(t, "var v = vec2(1, 2)\nvar result = v.x + v.y\n", "result")
	testing.expect_value(t, core.as_float(v), 3.0)
}

// Swizzle-component assignment (`v.x = ...`) through a bare global
// variable -- see emit_expr.odin's emit_swizzle_set and
// properties.odin's swizzle_assign. Because Vec2/3/4 are inlined into
// Value (see core/value.odin), `v` here is an independent copy each
// time it's read off the global slot -- Set_Global_Vec_Field (run.odin)
// is what actually writes the mutated whole vector back into that slot;
// without it, `v.x = 10` would silently do nothing observable (the
// mutation would happen to a copy on the stack and be discarded).
@(test)
test_vec_field_assignment :: proc(t: ^testing.T) {
	v := run_builtins(t, "var v = vec2(1, 2)\nv.x = 10\nvar result = v.x + v.y\n", "result")
	testing.expect_value(t, core.as_float(v), 12.0)

	v2 := run_builtins(t, "var v = vec3(1, 2, 3)\nv.z = 30\nvar result = v.z\n", "result")
	testing.expect_value(t, core.as_float(v2), 30.0)
}

// Same as above but through a real function-local slot (Set_Local_Vec_Field)
// rather than a global -- run_builtins only ever inspects globals, so this
// routes the local through a return value instead.
@(test)
test_vec_field_assignment_local :: proc(t: ^testing.T) {
	v := run_builtins(t, `
func f() {
	var v = vec2(1, 2)
	v.x = 10
	return v.x + v.y
}
var result = f()
`, "result")
	testing.expect_value(t, core.as_float(v), 12.0)
}

// Through an upvalue (Set_Upvalue_Vec_Field) -- a closure capturing an
// enclosing local and mutating a component of it.
@(test)
test_vec_field_assignment_upvalue :: proc(t: ^testing.T) {
	v := run_builtins(t, `
func make() {
	var v = vec2(1, 2)
	var setter = func() { v.x = 10 }
	setter()
	return v.x + v.y
}
var result = make()
`, "result")
	testing.expect_value(t, core.as_float(v), 12.0)
}

// Through one level of instance-property access (Set_Property_Vec_Field)
// -- the real-world shape every migrated example script uses
// (`this.pos.x = ...`), and the case set_vec_swizzle's old
// pointer-aliasing trick relied on most directly before vec2/3/4 were
// inlined.
@(test)
test_vec_field_assignment_property :: proc(t: ^testing.T) {
	v := run_builtins(t, `
class C {
	init() { this.pos = vec3(1, 2, 3) }
	bump() { this.pos.x = 10 }
}
var c = C()
c.bump()
var result = c.pos.x + c.pos.y + c.pos.z
`, "result")
	testing.expect_value(t, core.as_float(v), 15.0)
}

// r/g/b/a are accepted as aliases for x/y/z/w on Vec4 in the same
// write-back path (see properties.odin's vec_with_field_set).
@(test)
test_vec_field_assignment_color_aliases :: proc(t: ^testing.T) {
	v := run_builtins(t, "var c = vec4(0, 0, 0, 0)\nc.r = 255\nvar result = c.x\n", "result")
	testing.expect_value(t, core.as_float(v), 255.0)
}

// Copy independence: since vec2/3/4 are inline values (not shared heap
// objects -- see core/value.odin), assigning one variable's value to
// another must never let a later mutation through one be observed
// through the other. This is the direct mirror-image of what the old
// (now-deleted) pool allocator's stress test checked -- that one caught
// stale reused-heap-memory leaking between logically distinct vectors;
// this one catches the opposite failure mode a naive inlining port
// could introduce (accidentally keeping reference semantics somewhere).
@(test)
test_vec_assignment_is_a_copy_not_an_alias :: proc(t: ^testing.T) {
	v := run_builtins(t, "var a = vec2(1, 2)\nvar b = a\nb.x = 99\nvar result = a.x\n", "result")
	testing.expect_value(t, core.as_float(v), 1.0)
}

// A swizzle assignment expression evaluates to the assigned scalar, not
// the mutated vector -- matching plain `x = 5`'s own expression-value
// contract (see run.odin's Set_*_Vec_Field handlers, which push `value`
// on success, not the write-back destination's new whole-vector value).
@(test)
test_vec_field_assignment_expression_value_is_the_scalar :: proc(t: ^testing.T) {
	v := run_builtins(t, "var v = vec2(1, 2)\nvar result = (v.x = 5)\n", "result")
	testing.expect_value(t, core.as_float(v), 5.0)
}

// -----------------------------------------------------------------------
// Math free functions (the underscore-prefixed native floor --
// src/modules/math.lox's higher-level sin/cos/sqrt aren't ported yet)

@(test)
test_math_builtins :: proc(t: ^testing.T) {
	v := run_builtins(t, "var result = _sqrt(4.0)\n", "result")
	testing.expect_value(t, core.as_float(v), 2.0)
	v2 := run_builtins(t, "var result = _pow(2.0, 10.0)\n", "result")
	testing.expect_value(t, core.as_float(v2), 1024.0)
}

// -----------------------------------------------------------------------
// sys module -- regression coverage for the missing Op_Invoke module
// case (call.odin's invoke): `sys.clock()` compiles through Op_Invoke,
// same as any other `.name(args)` call, and every built-in module
// function call failed with "Undefined method" until that case existed.

@(test)
test_sys_module_function_call :: proc(t: ^testing.T) {
	v := run_builtins(t, "import sys\nvar result = sys.clock() >= 0.0\n", "result")
	testing.expect_value(t, core.as_bool(v), true)
}

// -----------------------------------------------------------------------
// os module -- file open/write/readln/close round trip, plus a couple
// of the path-manipulation functions.

@(test)
test_os_file_roundtrip :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.temp_allocator)
	path, _ := filepath.join({dir, "odlox_builtins_test.txt"})
	defer delete(path)
	defer os.remove(path)

	source_fmt := `
import os
var f = os.open("%s", "w")
os.write(f, "hello\n")
os.write(f, "world\n")
os.close(f)
var g = os.open("%s", "r")
var line1 = os.readln(g)
var line2 = os.readln(g)
os.close(g)
var result = line1 & "|" & line2
`
	source := fmt.aprintf(source_fmt, path, path)
	defer delete(source)

	v := run_builtins(t, source, "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "hello|world")
}

@(test)
test_os_path_functions :: proc(t: ^testing.T) {
	v := run_builtins(t, `import os` + "\n" + `var result = os.basename("a/b/c.txt")` + "\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "c.txt")
	v2 := run_builtins(t, `import os` + "\n" + `var result = os.dirname("a/b/c.txt")` + "\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v2)), "a/b")
}

// -----------------------------------------------------------------------
// String methods (replace/join -- see call.odin's invoke_builtin_string)

@(test)
test_string_replace_method :: proc(t: ^testing.T) {
	v := run_builtins(t, `var result = "abcabc".replace("a", "X")`+"\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "XbcXbc")
}

@(test)
test_string_join_method :: proc(t: ^testing.T) {
	v := run_builtins(t, `var result = "-".join(["a","b","c"])`+"\n", "result")
	testing.expect_value(t, core.string_get(core.as_string(v)), "a-b-c")
}
