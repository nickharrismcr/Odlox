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
// ok=false for *any* reason a fresh compile should happen instead --
// --force-compile set, no .lxc yet, cache not newer than source, bad
// header, or a malformed body. Callers never need to distinguish these:
// falling back to compiling from source is always correct. A version
// mismatch specifically (a real cache of ours, just from a different
// schema) gets one non-fatal stderr line -- see core.Bc_Decode_Error's
// own doc comment for why that case alone is worth a diagnostic.
bc_cache_load :: proc(vm: ^VM, module_source_path: string, environment: ^core.Environment) -> (fn: ^core.Function_Object, ok: bool) {
	if vm.force_compile {
		return nil, false // never even stats the file
	}

	cache_path := bc_cache_path(module_source_path)
	defer delete(cache_path)

	src_mtime, src_err := os.modification_time_by_path(module_source_path)
	if src_err != nil {
		return nil, false
	}
	cache_mtime, cache_err := os.modification_time_by_path(cache_path)
	if cache_err != nil {
		return nil, false // no .lxc yet -- not an error, the common case
	}
	if time.diff(src_mtime, cache_mtime) <= 0 {
		return nil, false // cache not strictly newer than source -- stale
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

	// Environment.global_names is a *separate* field from
	// Chunk.global_names (the one function_deserialise itself restores)
	// -- for a fresh compile it's populated by compiler_state.odin's own
	// end_compiler, as a side effect of Compile actually running, which a
	// cache hit deliberately skips. module.odin's load_module relies on
	// Environment.global_names (not Chunk's) to know which slots to
	// publish into the module's name-keyed vars map after running its
	// top-level code, so a cache hit must populate it here too. Clearing
	// before appending (rather than appending outright) keeps this
	// correct if environment is reused across more than one load.
	clear(&environment.global_names)
	for name in decoded.chunk.global_names {
		append(&environment.global_names, name)
	}

	return decoded, true
}

// bc_cache_wire_environment walks fn and every nested Function_Object
// reachable through chunk.constants (the same shape function_serialise/
// function_deserialise themselves recurse through), setting .environment
// on each one. Required because Get_Global/Set_Global (run.odin) resolve
// globals through *whichever frame's own* fn.environment is currently
// executing, not just the top-level function's -- the compiler already
// points every nested function at the same shared Environment, so a
// fixup that only patched the root would leave nested functions with a
// nil environment, crashing the first time one of them touched a global.
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
// A failure here (encode failure, directory/file write error) is never
// fatal -- a missed cache write just means the next import recompiles
// from source again, exactly like every import before this feature
// existed; it's silently skipped, not reported, since it's not a script-
// visible condition and every real error case (a read-only filesystem,
// a full disk) would otherwise spam stderr on every single import.
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
