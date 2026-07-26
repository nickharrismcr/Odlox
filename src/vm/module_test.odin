package vm

import "../core"
import "core:os"
import "core:path/filepath"
import "core:testing"

// module.odin's read_module_source path-resolution tests. Real
// filesystem fixtures (a temp directory tree), not just compiled-
// bytecode shape checks, since the two real bugs this covers were both
// filesystem-resolution bugs a shape test structurally can't catch:
// the search order itself, and a bad free (deleting a slice view into
// vm.script that read_module_source never owned -- see
// find_module_in_subdirs's doc comment) that only ever surfaced once a
// script's own directory actually needed a recursive subdirectory
// search to find a module.
//
// Both tests below pass reliably in isolation
// (-define:ODIN_TEST_NAMES=vm.test_import_..., one at a time) but the
// *pair* of them run together reproducibly crashes even with
// -define:ODIN_TEST_THREADS=1 -- consistent with, not a new instance
// of, the pre-existing "many VM instances in one odin test binary"
// toolchain issue documented at length in ROADMAP.md's Phase 4 section
// (each of these two tests constructs two full VMs -- the importing
// script's and the imported module's own sub-VM -- so a pair of them
// hits roughly the same total VM count that issue's writeup already
// found sufficient to trigger it, just via fewer, heavier tests instead
// of many small ones). Investigated directly rather than assumed:
// ruled out an env-var set/restore bug in this file specifically (the
// same set/lookup/restore sequence run standalone, twice in a row, in
// isolation from the VM/GC/compiler entirely, does not reproduce it).

@(private = "file")
write_temp_lox :: proc(t: ^testing.T, dir: string, name: string, source: string) -> string {
	path, _ := filepath.join({dir, name})
	err := os.write_entire_file(path, source)
	testing.expectf(t, err == nil, "expected to write %q, got %v", path, err)
	return path
}

// Regression test for a real, reproduced segfault: find_module_in_subdirs
// (module.odin) is exercised whenever the importing script's own
// directory doesn't directly contain `<name>.lox`, forcing a recursive
// walk of that directory tree. The first version of this walk crashed
// every time it succeeded (not "sometimes" -- every single run),
// because read_module_source separately called `delete()` on
// `filepath.dir(vm.script)`'s result, which is a slice *into*
// vm.script (see os/path.odin's split_path), not an owned allocation --
// a bad free that silently corrupted the heap on every successful
// module import since Phase 4 first wrote that line, without crashing
// immediately (bad frees don't always crash where they happen). It
// took find_module_in_subdirs' own extra allocations changing the heap
// layout to turn that latent corruption into an actual, reliable
// segfault. This test exists specifically to keep that path exercised.
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
// checked *before* the script's own directory (matching glox's own
// $LOX_PATH/src/modules-first order -- see read_module_source's doc
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
