package nativesig

// Static signatures for native/builtin functions -- the data the type
// checker (src/compiler/typecheck_native.odin) consults to check calls to
// things registered via vm.define_builtin, which are plain Odin procs
// with no reflectable Lox-level type info of their own (a Builtin_Fn is
// always `(argc, arg_stack_ptr, vm) -> Value`; real per-argument
// validation only exists as runtime checks inside each function body).
// See nativesig_methods.odin for the parallel table covering built-in
// list/dict/string *methods* (vm/call.odin's invoke_builtin_list/dict/
// string), a different dispatch shape keyed by (receiver kind, method
// name) rather than (module, name).
//
// This package has zero imports of its own and sits below compiler in
// the dependency graph, deliberately: the real import direction here is
// compiler <- vm <- natives (vm imports compiler, natives imports vm),
// so compiler can never import vm or natives without a cycle. Every
// signature below is keyed by (module, name) to match define_builtin's
// own registration key exactly -- module == "" is a global builtin
// (`len(x)`), a named module ("sys", "os", a natives module like "gfx")
// matches a member of that built-in module. Any Odin package that
// registers builtins through vm.define_builtin can import this one to
// declare its own signatures alongside its function definitions, once
// that's wired up -- see this file's own entries as the pattern.
//
// Every entry here is hand-verified against its real implementation
// (currently vm/builtins.odin, builtins_math.odin, builtins_sys.odin,
// builtins_os.odin), not guessed from the name -- see each proc's own
// runtime argc/type checks for the source of truth this table mirrors.
// Not yet covered: the `natives` package (raylib/gfx/sound/os/re/json/
// pickle/physics/...) -- a much larger surface, left for a future pass.

// Kind mirrors the subset of compiler.Type_Kind meaningful to a native's
// arguments/return value. compiler.typecheck_native.odin translates Kind
// -> Type_Kind when consuming a Signature; kept as its own small enum
// here rather than importing compiler's, which would create the cycle
// this package exists to avoid. No File/Iterator kind exists here
// because compiler's own Type_Kind has no such variant either -- a
// file-or-iterator-typed parameter/return is left Dynamic, the correct
// (not just convenient) choice given what the type lattice can actually
// represent.
Kind :: enum {
	Dynamic, // unchecked: any value, including Nil, is accepted
	Bool,
	Int,
	Float,
	String,
	List,
	Dict,
	Vec2,
	Vec3,
	Vec4,
}

// Param describes one positional parameter's accepted kind(s) -- any one
// of Accepted is fine (an actual argument type of Dynamic always passes
// regardless of Accepted, same escape hatch this feature uses
// everywhere else). An empty Accepted means "unchecked", for a
// parameter with no real type constraint (e.g. append()'s value, or
// type()'s single argument).
Param :: struct {
	accepted: []Kind,
}

// Signature is one define_builtin(vm, module, name, fn) call's real
// argument/return shape. Params[i] constrains position i, for i within
// len(Params). A call with more positional arguments than len(Params)
// is handled one of two ways past that point: if Variadic_Tail is set,
// every further position is checked against it (os.join: every argument
// after the first is still required to be a string); otherwise those
// positions are visited (for side effects / nested diagnostics) but not
// type-checked (format()'s template-plus-anything tail).
//
// Min_Args/Max_Args bound the argument count; Max_Args == -1 means
// unbounded. Arity_Message, when non-empty, is the native's own runtime
// error text, reused verbatim for a wrong-arg-count diagnostic so the
// message matches whether it's caught at compile time or, for an
// untypeable call site, only later at runtime -- the same precedent
// vec2()/vec3()/vec4()'s own former hand-written special case
// (typecheck_expr.odin, before this table existed) established. An
// empty Arity_Message means arity is never diagnosed for this
// signature, because the real implementation doesn't enforce it either
// (e.g. rand(), which silently ignores any arguments passed to it) --
// diagnosing a mismatch the runtime itself tolerates would be a false
// positive, exactly what this whole feature is designed to avoid.
Signature :: struct {
	module:        string,
	name:          string,
	min_args:      int,
	max_args:      int,
	params:        []Param,
	variadic_tail: []Kind,
	returns:       Kind,
	arity_message: string,
}

// Shared accepted-kind sets -- package-private (not file-private) since
// nativesig_methods.odin's table reuses them too.
@(private)
NUMERIC := []Kind{.Int, .Float}

@(private)
STRICT_FLOAT := []Kind{.Float}

@(private)
STRING := []Kind{.String}

// signatures is the whole table: the global (module == "") core builtins
// from vm/builtins.odin (including the underscore-prefixed math
// primitives math.lox wraps), plus the sys/os built-in modules.
@(private = "file")
signatures := []Signature {
	// --- vm/builtins.odin: core free functions ---
	{module = "", name = "type", min_args = 1, max_args = 1, params = {{}}, returns = .String, arity_message = "Single argument expected."},
	{module = "", name = "len", min_args = 1, max_args = 1, params = {{accepted = {.String, .List}}}, returns = .Int, arity_message = "Invalid argument count to len."},
	{module = "", name = "append", min_args = 2, max_args = 2, params = {{accepted = {.List}}, {}}, returns = .List, arity_message = "Invalid argument count to append."},
	{module = "", name = "float", min_args = 1, max_args = 1, params = {{accepted = {.Int, .Float, .String}}}, returns = .Float, arity_message = "Single argument expected."},
	{module = "", name = "int", min_args = 1, max_args = 1, params = {{accepted = {.Int, .Float, .String}}}, returns = .Int, arity_message = "Single argument expected."},
	{module = "", name = "rand", min_args = 0, max_args = -1, params = {}, returns = .Float, arity_message = ""},
	{module = "", name = "replace", min_args = 3, max_args = 3, params = {{accepted = STRING}, {accepted = STRING}, {accepted = STRING}}, returns = .String, arity_message = "Invalid argument count to replace."},
	{module = "", name = "format", min_args = 1, max_args = -1, params = {{accepted = STRING}}, returns = .String, arity_message = "format expects at least 1 argument"},
	{module = "", name = "range", min_args = 1, max_args = 3, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Dynamic, arity_message = "range expects 1 to 3 arguments"},
	{module = "", name = "vec2", min_args = 2, max_args = 2, params = {{accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec2, arity_message = "vec2 expects 2 arguments (x,y)"},
	{module = "", name = "vec3", min_args = 3, max_args = 3, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec3, arity_message = "vec3 expects 3 arguments (x,y,z)"},
	{module = "", name = "vec4", min_args = 4, max_args = 4, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec4, arity_message = "vec4 expects 4 arguments (x,y,z,w)"},

	// --- vm/builtins_math.odin: underscore-prefixed primitives math.lox
	// wraps. is_float, not is_number: unlike vec2/3/4 or range(), these
	// reject a plain int argument outright at runtime (`_sin(1)` errors),
	// so STRICT_FLOAT (not NUMERIC) is the correct accepted set. ---
	{module = "", name = "_sin", min_args = 1, max_args = 1, params = {{accepted = STRICT_FLOAT}}, returns = .Float, arity_message = "Invalid argument to sin."},
	{module = "", name = "_cos", min_args = 1, max_args = 1, params = {{accepted = STRICT_FLOAT}}, returns = .Float, arity_message = "Invalid argument to cos."},
	{module = "", name = "_tan", min_args = 1, max_args = 1, params = {{accepted = STRICT_FLOAT}}, returns = .Float, arity_message = "Invalid argument to tan."},
	{module = "", name = "_sqrt", min_args = 1, max_args = 1, params = {{accepted = STRICT_FLOAT}}, returns = .Float, arity_message = "Invalid argument to sqrt."},
	{module = "", name = "_pow", min_args = 2, max_args = 2, params = {{accepted = STRICT_FLOAT}, {accepted = STRICT_FLOAT}}, returns = .Float, arity_message = "Invalid argument to pow."},
	{module = "", name = "_atan2", min_args = 2, max_args = 2, params = {{accepted = STRICT_FLOAT}, {accepted = STRICT_FLOAT}}, returns = .Float, arity_message = "Invalid argument to atan2."},

	// --- vm/builtins_sys.odin ---
	{module = "sys", name = "args", min_args = 0, max_args = -1, params = {}, returns = .List, arity_message = ""},
	{module = "sys", name = "clock", min_args = 0, max_args = -1, params = {}, returns = .Float, arity_message = ""},
	{module = "sys", name = "sleep", min_args = 1, max_args = 1, params = {{accepted = NUMERIC}}, returns = .Dynamic, arity_message = "sys.sleep argument must be a number"},
	{module = "sys", name = "today", min_args = 0, max_args = -1, params = {}, returns = .String, arity_message = ""},
	{module = "sys", name = "now", min_args = 0, max_args = -1, params = {}, returns = .String, arity_message = ""},
	{module = "sys", name = "gc_set_min_threshold", min_args = 1, max_args = 1, params = {{accepted = NUMERIC}}, returns = .Dynamic, arity_message = "sys.gc_set_min_threshold argument must be a number"},

	// --- vm/builtins_os.odin. open/close/readln/write take a File value,
	// which -- like an iterator -- has no Type_Kind of its own; that
	// position is left unchecked (Dynamic) rather than mismodeled. ---
	{module = "os", name = "open", min_args = 2, max_args = 2, params = {{accepted = STRING}, {accepted = STRING}}, returns = .Dynamic, arity_message = "Invalid argument type to open."},
	{module = "os", name = "close", min_args = 1, max_args = 1, params = {{}}, returns = .Bool, arity_message = "Invalid argument type to close."},
	{module = "os", name = "readln", min_args = 1, max_args = 1, params = {{}}, returns = .String, arity_message = "Invalid argument type to readln."},
	{module = "os", name = "write", min_args = 2, max_args = 2, params = {{}, {accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to write."},
	{module = "os", name = "read_all", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .String, arity_message = "Invalid argument type to read_all."},
	{module = "os", name = "listdir", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .List, arity_message = "Invalid argument type to listdir, expected string."},
	{module = "os", name = "isdir", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to isdir, expected string."},
	{module = "os", name = "isfile", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to isfile, expected string."},
	{module = "os", name = "exists", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to exists, expected string."},
	{module = "os", name = "mkdir", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to mkdir, expected string."},
	{module = "os", name = "rmdir", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to rmdir, expected string."},
	{module = "os", name = "remove", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to remove, expected string."},
	{module = "os", name = "getcwd", min_args = 0, max_args = 0, params = {}, returns = .String, arity_message = "Invalid argument count to getcwd."},
	{module = "os", name = "chdir", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Bool, arity_message = "Invalid argument type to chdir, expected string."},
	{module = "os", name = "join", min_args = 1, max_args = -1, params = {{accepted = STRING}}, variadic_tail = STRING, returns = .String, arity_message = "join requires at least one argument."},
	{module = "os", name = "dirname", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .String, arity_message = "Invalid argument type to dirname, expected string."},
	{module = "os", name = "basename", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .String, arity_message = "Invalid argument type to basename, expected string."},
	{module = "os", name = "splitext", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .List, arity_message = "Invalid argument type to splitext, expected string."},
}

// lookup finds the signature for a (module, name) pair, if one is
// registered. Linear scan -- the table is small (a few dozen entries);
// switch to a map if this grows enough to matter.
lookup :: proc(module: string, name: string) -> (Signature, bool) {
	for sig in signatures {
		if sig.module == module && sig.name == name {
			return sig, true
		}
	}
	return Signature{}, false
}
