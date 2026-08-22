package vm

import "../core"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// bc_cache.odin: the file-I/O/path/mtime layer on top of core/bc_cache.odin's
// pure format (see docs/plans/bytecode-cache.md for the full design).
// Everything here that core structurally can't do itself: reading/
// writing the `.lxc` file, deriving its path, comparing mtimes, and
// wiring a deserialized Function_Object tree's .environment (core has
// no vm.Environment in scope for a given module load -- only this layer
// does).

// bc_cache_path is <module_dir>/__loxcache__/<name>.lxc.
// module.odin's find_module_in_subdirs already skips
// `__loxcache__` by name when walking a script's directory tree for a
// module, anticipating this.
bc_cache_path :: proc(module_source_path: string) -> string {
	dir := filepath.dir(module_source_path) // slice into the input -- do not delete()
	base := filepath.base(module_source_path)
	stem := filepath.stem(base)
	cache_dir, _ := filepath.join({dir, "__loxcache__"})
	defer delete(cache_dir)
	path, _ := filepath.join({cache_dir, strings.concatenate({stem, ".lxc"})})
	return path
}

// bc_cache_load attempts a cache hit for module_source_path, returning
// ok=false for any reason a fresh compile should happen instead
// (--force-compile, no .lxc yet, stale cache, bad header/body). Callers
// never need to distinguish these -- falling back to compiling from source
// is always correct, unless vm.force_bc_cache is set with no source to fall
// back to (see module.odin's compile_and_run_module).
bc_cache_load :: proc(vm: ^VM, module_source_path: string, environment: ^core.Environment) -> (fn: ^core.Function_Object, ok: bool) {
	if vm.force_compile {
		return nil, false // never even stats the file
	}

	cache_path := bc_cache_path(module_source_path)
	defer delete(cache_path)

	cache_mtime, cache_err := os.modification_time_by_path(cache_path)
	if cache_err != nil {
		return nil, false // no .lxc yet -- not an error, the common case
	}

	// force_bc_cache trusts the cache unconditionally once it exists --
	// no source stat, no freshness comparison. This is what makes a
	// source-free module (only __loxcache__/<name>.lxc shipped, no
	// matching .lox at all) loadable at all: module_source_path may not
	// exist on disk in that case, so stat-ing it here would always fail.
	if !vm.force_bc_cache {
		src_mtime, src_err := os.modification_time_by_path(module_source_path)
		if src_err != nil {
			return nil, false
		}
		if time.diff(src_mtime, cache_mtime) <= 0 {
			return nil, false // cache not strictly newer than source -- stale
		}
	}

	data, read_err := os.read_entire_file_from_path(cache_path, context.allocator)
	if read_err != nil {
		return nil, false
	}
	defer delete(data)

	decoded, decode_err := core.function_deserialise(data)
	if decode_err == .Bad_Version {
		fmt.eprintfln("odlox: %s is a stale-format bytecode cache -- recompiling", cache_path)
	}
	if decode_err != .None {
		return nil, false
	}

	bc_cache_wire_environment(decoded, environment)

	// Environment.global_names is separate from Chunk.global_names; a fresh
	// compile populates it via end_compiler, which a cache hit skips.
	// load_module (module.odin) needs it to publish top-level slots into the
	// module's vars map, so it must be populated here too.
	clear(&environment.global_names)
	for name in decoded.chunk.global_names {
		append(&environment.global_names, name)
	}

	return decoded, true
}

// bc_cache_wire_environment walks fn and every nested Function_Object
// reachable through chunk.constants, setting .environment on each one.
// Get_Global/Set_Global resolve globals through whichever frame's own
// fn.environment is executing, so patching only the root would leave
// nested functions with a nil environment.
@(private = "file")
bc_cache_wire_environment :: proc(fn: ^core.Function_Object, environment: ^core.Environment) {
	fn.environment = environment
	for v in fn.chunk.constants {
		if v.type == .Obj && v.obj_type == .Function {
			bc_cache_wire_environment(core.as_function(v), environment)
		}
	}
}

// bc_cache_write serializes fn and writes it to module_source_path's
// `.lxc` cache location, creating the __loxcache__ directory if needed.
// Failures are silently skipped, not reported -- a missed write just means
// the next import recompiles from source, as it always did before caching.
bc_cache_write :: proc(module_source_path: string, fn: ^core.Function_Object) {
	data, ok := core.function_serialise(fn)
	if !ok {
		return
	}
	defer delete(data)

	cache_path := bc_cache_path(module_source_path)
	defer delete(cache_path)

	// filepath.dir returns a slice *into* cache_path, not a fresh
	// allocation (see os/path.odin's split_path) -- do not delete() it.
	// module.odin's read_module_source has its own doc comment on the
	// same API gotcha.
	dir := filepath.dir(cache_path)
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(cache_path, data)
}
