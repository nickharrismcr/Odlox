package vm

import "../core"
import "core:os"
import "core:path/filepath"
import "core:testing"

// module.odin's read_module_source path-resolution tests. Real filesystem
// fixtures, not just compiled-bytecode shape checks, since the two real
// bugs this covers -- the search order itself, and a bad free of a slice
// view into vm.script -- were both filesystem-resolution bugs a shape test
// can't catch. Both tests pass in isolation
// (-define:ODIN_TEST_NAMES=vm.test_import_...) but crash run as a pair --
// the "many VM instances in one odin test binary" issue (ROADMAP.md Phase 4).

@(private = "file")
write_temp_lox :: proc(t: ^testing.T, dir: string, name: string, source: string) -> string {
	path, _ := filepath.join({dir, name})
	err := os.write_entire_file(path, source)
	testing.expectf(t, err == nil, "expected to write %q, got %v", path, err)
	return path
}

// Regression test for a reproduced segfault: find_module_in_subdirs is
// exercised whenever the importing script's directory doesn't directly
// contain `<name>.lox`, forcing a recursive walk. The bug was
// read_module_source calling `delete()` on `filepath.dir(vm.script)`'s
// result, a slice into vm.script (not an owned allocation) -- a bad free
// that silently corrupted the heap until find_module_in_subdirs' own
// allocations changed the heap layout enough to make it segfault reliably.
@(test)
test_import_finds_module_in_subdirectory :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_module_test_subdir"})
	defer delete(root)
	sub, _ := filepath.join({root, "nested"})
	defer delete(sub)
	defer os.remove_all(root)

	testing.expect(t, os.make_directory_all(sub) == nil)
	script_path := write_temp_lox(t, root, "main.lox", "import greeter\nvar result = greeter.hello()\n")
	defer delete(script_path)
	mod_path := write_temp_lox(t, sub, "greeter.lox", "func hello() {\n\treturn \"hi from a subdirectory\"\n}\n")
	defer delete(mod_path)

	data, ok := os.read_entire_file_from_path(script_path, context.allocator)
	testing.expect(t, ok == nil)
	defer delete(data)

	vm_instance := new_vm(script_path)
	define_builtins(vm_instance)
	status, _ := interpret(vm_instance, string(data))
	testing.expectf(t, status == .Ok, "expected import to succeed, got %v: %s", status, vm_instance.error_msg)

	slot := core.env_slot_for_name(vm_instance.environment, "result")
	testing.expect(t, slot >= 0)
	if slot >= 0 {
		v := vm_instance.environment.globals[slot]
		testing.expect_value(t, core.string_get(core.as_string(v)), "hi from a subdirectory")
	}
}

// Regression test for the search-order fix: $LOX_PATH/modules is
// checked *before* the script's own directory (matching the reference
// implementation's own $LOX_PATH/src/modules-first order -- see read_module_source's doc
// comment for why the subdirectory name differs). A module of the same
// name sitting in both places must resolve to the LOX_PATH copy.
@(test)
test_import_prefers_lox_path_modules_dir :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_module_test_loxpath"})
	defer delete(root)
	modules_dir, _ := filepath.join({root, "modules"})
	defer delete(modules_dir)
	defer os.remove_all(root)

	testing.expect(t, os.make_directory_all(modules_dir) == nil)
	script_path := write_temp_lox(t, root, "main.lox", "import shadowed\nvar result = shadowed.which()\n")
	defer delete(script_path)
	same_dir_shadow := write_temp_lox(t, root, "shadowed.lox", "func which() {\n\treturn \"same-dir\"\n}\n")
	defer delete(same_dir_shadow)
	lox_path_shadow := write_temp_lox(t, modules_dir, "shadowed.lox", "func which() {\n\treturn \"lox-path\"\n}\n")
	defer delete(lox_path_shadow)

	old_lox_path, had_old := os.lookup_env_alloc("LOX_PATH", context.allocator)
	defer if had_old {
		delete(old_lox_path)
	}
	os.set_env("LOX_PATH", root)
	defer if had_old {
		os.set_env("LOX_PATH", old_lox_path)
	} else {
		os.unset_env("LOX_PATH")
	}

	data, ok := os.read_entire_file_from_path(script_path, context.allocator)
	testing.expect(t, ok == nil)
	defer delete(data)

	vm_instance := new_vm(script_path)
	define_builtins(vm_instance)
	status, _ := interpret(vm_instance, string(data))
	testing.expectf(t, status == .Ok, "expected import to succeed, got %v: %s", status, vm_instance.error_msg)

	slot := core.env_slot_for_name(vm_instance.environment, "result")
	testing.expect(t, slot >= 0)
	if slot >= 0 {
		v := vm_instance.environment.globals[slot]
		testing.expect_value(t, core.string_get(core.as_string(v)), "lox-path")
	}
}

// -----------------------------------------------------------------------
// Regression test: run.odin's Get_Global/Set_Global/Define_Global(_Const)
// resolved through vm.environment (the running VM's own field) instead of
// the currently executing frame's function's environment. Those only
// coincide for the top-level script -- an imported module's function
// referencing any global resolved against the importing script's slot
// space instead of its own. See run.odin's doc comment on the fix.

@(private = "file")
run_two_module_files :: proc(t: ^testing.T, dir: string, main_source, helper_source: string) -> (result: core.Value, status: Interpret_Result, msg: string) {
	main_path := write_temp_lox(t, dir, "main.lox", main_source)
	defer delete(main_path)
	helper_path := write_temp_lox(t, dir, "helper.lox", helper_source)
	defer delete(helper_path)

	data, ok := os.read_entire_file_from_path(main_path, context.allocator)
	testing.expect(t, ok == nil)
	defer delete(data)

	vm_instance := new_vm(main_path)
	define_builtins(vm_instance)
	status, _ = interpret(vm_instance, string(data))
	msg = vm_instance.error_msg
	if status != .Ok {
		return
	}
	slot := core.env_slot_for_name(vm_instance.environment, "result")
	testing.expect(t, slot >= 0)
	if slot < 0 {
		return
	}
	result = vm_instance.environment.globals[slot]
	return
}

@(test)
test_imported_function_calling_another_function_in_its_own_module :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_module_test_crossref"})
	defer delete(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)

	v, status, msg := run_two_module_files(t, root, `
import helper
var result = helper.triple(7)
`, `
func triple(x) {
	return helper_val(x)
}
func helper_val(x) {
	return x * 3
}
`)
	testing.expectf(t, status == .Ok, "expected Ok, got %v: %s", status, msg)
	if status == .Ok {
		testing.expect_value(t, core.as_int(v), 21)
	}
}

@(test)
test_imported_function_reading_module_level_var :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_module_test_modvar"})
	defer delete(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)

	v, status, msg := run_two_module_files(t, root, `
import helper
var result = helper.get_base_plus(10)
`, `
var base_value = 100
func get_base_plus(x) {
	return base_value + x
}
`)
	testing.expectf(t, status == .Ok, "expected Ok, got %v: %s", status, msg)
	if status == .Ok {
		testing.expect_value(t, core.as_int(v), 110)
	}
}

// -----------------------------------------------------------------------
// Regression test for `from mod import *`, which had two bugs: (1) the
// scanner's Eol-suppression heuristic can't distinguish `*` from
// multiplication, so consume_eol always failed after the statement; (2)
// `import *` iterates every name in the module's environment, including
// incidentally-referenced free builtins, raising "has no global slot" --
// fixed with bind_imported_name_soft.
@(test)
test_from_import_star_with_module_referencing_extra_builtins :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_module_test_star"})
	defer delete(root)
	defer os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)

	v, status, msg := run_two_module_files(t, root, `
from helper import *
var result = double(21)
`, `
func double(x) {
	// References vec2() purely internally -- helper.environment.vars
	// ends up with a "vec2" entry as a side effect (see
	// seed_builtin_globals), which the importing script above never
	// mentions by name anywhere -- exactly the case that used to crash.
	var unused = vec2(0, 0)
	return x * 2
}
`)
	testing.expectf(t, status == .Ok, "expected Ok, got %v: %s", status, msg)
	if status == .Ok {
		testing.expect_value(t, core.as_int(v), 42)
	}
}
