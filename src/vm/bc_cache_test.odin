package vm

import "../compiler"
import "../core"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

// bc_cache.odin's own integration tests: real filesystem fixtures (a
// temp directory tree), a real compiler, and real module imports through
// do_import -- not just the format-level unit tests in
// core/bc_cache_test.odin, since the risk this feature actually carries
// (a wrong-length property_caches array, a not-fully-wired environment
// on a nested function) only shows up once a cache hit is actually
// *executed*, not merely decoded. See module_test.odin's own doc comment
// for this project's established note on the toolchain issue these
// VM-heavy tests can trigger *in pairs* even though each passes reliably
// alone (-define:ODIN_TEST_NAMES=vm.test_x, one at a time) -- run these
// the same way if a batched run misbehaves, rather than assuming a new
// bug.

@(private = "file")
write_temp_file :: proc(t: ^testing.T, dir: string, name: string, content: string) -> string {
	path, _ := filepath.join({dir, name})
	err := os.write_entire_file(path, content)
	testing.expectf(t, err == nil, "expected to write %q, got %v", path, err)
	return path
}

@(private = "file")
read_global_int :: proc(t: ^testing.T, vm_instance: ^VM, name: string) -> int {
	slot := core.env_slot_for_name(vm_instance.environment, name)
	testing.expectf(t, slot >= 0, "expected global %q to exist", name)
	if slot < 0 {
		return 0
	}
	return core.as_int(vm_instance.environment.globals[slot])
}

@(private = "file")
read_global_string :: proc(t: ^testing.T, vm_instance: ^VM, name: string) -> string {
	slot := core.env_slot_for_name(vm_instance.environment, name)
	testing.expectf(t, slot >= 0, "expected global %q to exist", name)
	if slot < 0 {
		return ""
	}
	return core.string_get(core.as_string(vm_instance.environment.globals[slot]))
}

@(private = "file")
run_main_importing_helper :: proc(t: ^testing.T, root: string, main_source: string, force_compile := false) -> ^VM {
	main_path, _ := filepath.join({root, "main.lox"})
	defer delete(main_path)

	vm_instance := new_vm(main_path)
	vm_instance.force_compile = force_compile
	define_builtins(vm_instance)
	status, _ := interpret(vm_instance, main_source)
	testing.expectf(t, status == .Ok, "expected Ok, got %v: %s", status, vm_instance.error_msg)
	return vm_instance
}

// -----------------------------------------------------------------------
// Stage 2/3: a cache hit is used, and its whole Function_Object tree
// (not just the root) resolves globals correctly. helper.lox nests a
// closure two levels deep (make_counter -> bump), both of which need
// .environment wired for `counter = counter + 1` to resolve at all, and
// invokes Greeter.greet twice through the same call site, exercising the
// property_caches array-length requirement (a wrong length would corrupt
// or crash on the *second* Invoke through that cache slot).

@(private = "file")
HELPER_SOURCE :: `
var counter = 10

func make_counter() {
	func bump() {
		counter = counter + 1
		return counter
	}
	return bump
}

class Greeter {
	greet(x) {
		return "hi " & x
	}
}
`

@(private = "file")
MAIN_SOURCE :: `
import helper
var b = helper.make_counter()
var r1 = b()
var r2 = b()
var g = helper.Greeter()
var s1 = g.greet("a")
var s2 = g.greet("b")
`

@(test)
test_bc_cache_hit_wires_nested_environment_and_property_cache :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_bc_cache_test_hit"})
	defer delete(root)
	defer os.remove_all(root)
	os.remove_all(root) // defensive: clear any leftover state from an earlier interrupted run
	testing.expect(t, os.make_directory_all(root) == nil)

	helper_path := write_temp_file(t, root, "helper.lox", HELPER_SOURCE)
	defer delete(helper_path)

	// Hand-construct the .lxc directly via function_serialise -- NOT
	// through bc_cache_write -- so this test proves bc_cache_load's read
	// path + environment fixup on their own, independent of whether
	// writing works (that's Stage 3's own test, below).
	compile_env := core.make_environment(helper_path)
	fn, ok := compiler.Compile(HELPER_SOURCE, helper_path, compile_env)
	testing.expect(t, ok)
	data, enc_ok := core.function_serialise(fn)
	testing.expect(t, enc_ok)
	defer delete(data)

	cache_path := bc_cache_path(helper_path)
	defer delete(cache_path)
	testing.expect(t, os.make_directory_all(filepath.dir(cache_path)) == nil)
	testing.expect(t, os.write_entire_file(cache_path, data) == nil)

	// Cache must be strictly newer than the source for bc_cache_load to
	// use it -- write_temp_file above already wrote helper.lox first, so
	// the .lxc written just now is naturally newer; no extra delay needed.

	vm_instance := run_main_importing_helper(t, root, MAIN_SOURCE)
	testing.expect_value(t, read_global_int(t, vm_instance, "r1"), 11)
	testing.expect_value(t, read_global_int(t, vm_instance, "r2"), 12)
	testing.expect_value(t, read_global_string(t, vm_instance, "s1"), "hi a")
	testing.expect_value(t, read_global_string(t, vm_instance, "s2"), "hi b")
}

// -----------------------------------------------------------------------
// Stage 3: a real end-to-end round trip -- no hand-constructed cache.
// First import compiles from source and writes the cache; a second,
// completely fresh VM importing the same module should hit it, with
// identical results.

@(test)
test_bc_cache_write_then_reimport_hits_cache :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_bc_cache_test_roundtrip"})
	defer delete(root)
	defer os.remove_all(root)
	os.remove_all(root) // defensive: clear any leftover state from an earlier interrupted run
	testing.expect(t, os.make_directory_all(root) == nil)

	helper_path := write_temp_file(t, root, "helper.lox", HELPER_SOURCE)
	defer delete(helper_path)

	cache_path := bc_cache_path(helper_path)
	defer delete(cache_path)
	testing.expect(t, os.exists(cache_path) == false)

	vm1 := run_main_importing_helper(t, root, MAIN_SOURCE)
	testing.expect_value(t, read_global_int(t, vm1, "r1"), 11)
	testing.expectf(t, os.exists(cache_path), "expected %q to exist after a cold import", cache_path)

	vm2 := run_main_importing_helper(t, root, MAIN_SOURCE) // fresh VM -> fresh, empty module_cache
	testing.expect_value(t, read_global_int(t, vm2, "r1"), 11)
	testing.expect_value(t, read_global_int(t, vm2, "r2"), 12)
	testing.expect_value(t, read_global_string(t, vm2, "s1"), "hi a")
}

// -----------------------------------------------------------------------
// Stage 4: mtime invalidation. Editing helper.lox after a cache exists
// must produce fresh, updated output on the next import, never a stale
// serve -- and the cache self-refreshes to match.

@(test)
test_bc_cache_mtime_invalidation_on_source_edit :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_bc_cache_test_mtime"})
	defer delete(root)
	defer os.remove_all(root)
	os.remove_all(root) // defensive: clear any leftover state from an earlier interrupted run
	testing.expect(t, os.make_directory_all(root) == nil)

	main_source := `
import helper
var result = helper.value()
`
	write_temp_file(t, root, "helper.lox", "func value() { return 1 }\n")

	vm1 := run_main_importing_helper(t, root, main_source)
	testing.expect_value(t, read_global_int(t, vm1, "result"), 1)

	time.sleep(50 * time.Millisecond) // ensure a distinguishable mtime on the rewrite below
	write_temp_file(t, root, "helper.lox", "func value() { return 2 }\n")

	vm2 := run_main_importing_helper(t, root, main_source)
	testing.expectf(t, read_global_int(t, vm2, "result") == 2, "expected the edited source to be recompiled, not served stale from cache")

	time.sleep(50 * time.Millisecond)
	vm3 := run_main_importing_helper(t, root, main_source)
	testing.expect_value(t, read_global_int(t, vm3, "result"), 2) // the refreshed cache from vm2's write
}

// -----------------------------------------------------------------------
// Stage 5: --force-compile bypasses the cache *read* but still refreshes
// the *write* -- matching glox's own -f semantics exactly (see
// docs/plans/bytecode-cache.md). Verified by planting a *valid* cache
// holding a deliberately wrong result: a run with force_compile=false
// must be fooled by it (sanity-checking this test's own mechanism), one
// with force_compile=true must not be, and a run after that must see the
// cache freshly corrected.

@(test)
test_bc_cache_force_compile_bypasses_read_but_refreshes_write :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_bc_cache_test_force"})
	defer delete(root)
	defer os.remove_all(root)
	os.remove_all(root) // defensive: clear any leftover state from an earlier interrupted run
	testing.expect(t, os.make_directory_all(root) == nil)

	main_source := `
import helper
var result = helper.value()
`
	helper_path := write_temp_file(t, root, "helper.lox", "func value() { return 1 }\n")
	defer delete(helper_path)

	vm1 := run_main_importing_helper(t, root, main_source)
	testing.expect_value(t, read_global_int(t, vm1, "result"), 1)

	// Overwrite the real (correct) cache with a *different*, still-valid
	// cache -- compiled from source that returns 999 instead of 1. Still
	// passes the header/mtime checks, so a broken force_compile (one
	// that fails to bypass the read) would silently return 999 instead
	// of falling back to real source.
	bogus_env := core.make_environment(helper_path)
	bogus_fn, bogus_ok := compiler.Compile("func value() { return 999 }\n", helper_path, bogus_env)
	testing.expect(t, bogus_ok)
	bogus_data, bogus_enc_ok := core.function_serialise(bogus_fn)
	testing.expect(t, bogus_enc_ok)
	defer delete(bogus_data)
	cache_path := bc_cache_path(helper_path)
	defer delete(cache_path)
	testing.expect(t, os.write_entire_file(cache_path, bogus_data) == nil)

	vm2 := run_main_importing_helper(t, root, main_source) // force_compile=false
	testing.expectf(t, read_global_int(t, vm2, "result") == 999, "sanity check failed: expected the planted bogus cache to be read")

	vm3 := run_main_importing_helper(t, root, main_source, force_compile = true)
	testing.expectf(t, read_global_int(t, vm3, "result") == 1, "--force-compile should have bypassed the bogus cache and recompiled from real source")

	vm4 := run_main_importing_helper(t, root, main_source) // force_compile=false again
	testing.expectf(t, read_global_int(t, vm4, "result") == 1, "expected force_compile's own write to have refreshed the cache with the correct result")
}

// -----------------------------------------------------------------------
// Corruption recovery: glox's own documented weakness here is a stale/
// malformed .lxc causing a hang or OOM panic (see bc_cache.odin's own
// doc comment); every one of these must instead fall back to a correct
// source compile with no crash/hang, and the module import must still
// succeed end-to-end.

@(private = "file")
test_one_corruption_falls_back_and_self_heals :: proc(t: ^testing.T, root: string, corrupt: []u8, label: string) {
	main_source := `
import helper
var result = helper.value()
`
	helper_path, _ := filepath.join({root, "helper.lox"})
	defer delete(helper_path)

	cache_path := bc_cache_path(helper_path)
	defer delete(cache_path)
	testing.expect(t, os.make_directory_all(filepath.dir(cache_path)) == nil)
	testing.expectf(t, os.write_entire_file(cache_path, corrupt) == nil, "%s: failed writing corrupt cache", label)

	vm_instance := run_main_importing_helper(t, root, main_source)
	testing.expectf(t, read_global_int(t, vm_instance, "result") == 1, "%s: expected fallback compile to still produce the correct result", label)

	// Self-heal: the fallback compile's own write should have replaced
	// the corrupt file with a real, valid cache -- a subsequent import
	// must be able to read it cleanly.
	data, err := os.read_entire_file_from_path(cache_path, context.allocator)
	testing.expectf(t, err == nil, "%s: expected a fresh cache file after self-heal", label)
	if err == nil {
		defer delete(data)
		_, decode_err := core.function_deserialise(data)
		testing.expectf(t, decode_err == .None, "%s: expected the self-healed cache to decode cleanly, got %v", label, decode_err)
	}
}

@(test)
test_bc_cache_corrupted_lxc_falls_back_and_self_heals :: proc(t: ^testing.T) {
	base, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base, "odlox_bc_cache_test_corrupt"})
	defer delete(root)
	defer os.remove_all(root)
	os.remove_all(root) // defensive: clear any leftover state from an earlier interrupted run
	testing.expect(t, os.make_directory_all(root) == nil)
	write_temp_file(t, root, "helper.lox", "func value() { return 1 }\n")

	test_one_corruption_falls_back_and_self_heals(t, root, []u8{'O', 'L', 'X', 'C', 0xFF, 0xFF}, "wrong version")
	test_one_corruption_falls_back_and_self_heals(t, root, []u8{'O', 'L', 'X', 'C', 1, 0, 0, 0}, "truncated body")
	test_one_corruption_falls_back_and_self_heals(t, root, []u8{0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00}, "not a cache file at all")
}
