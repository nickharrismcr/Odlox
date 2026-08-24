package nativesig

// Static signatures for native/builtin functions -- the data the type
// checker (src/compiler/typecheck_native.odin) consults to check calls
// to things registered via vm.define_builtin, which are plain Odin procs
// with no reflectable Lox-level type info of their own. See nativesig_
// methods.odin for the parallel table covering built-in list/dict/string
// *methods* (vm/call.odin's invoke_builtin_list/dict/string), keyed by
// (receiver kind, method name) rather than (module, name).
//
// Zero imports of its own, deliberately: compiler <- vm <- natives (vm
// imports compiler, natives imports vm), so compiler can never import vm
// or natives without a cycle. Keyed by (module, name) to match
// define_builtin's own registration key -- module == "" is a global
// builtin (`len(x)`), a named module ("sys", "os", a natives module like
// "gfx") matches a member of that built-in module.
//
// Every entry is verified against its real implementation (vm/builtins*.
// odin and natives/*.odin) -- see each proc's own runtime argc/type
// checks. Covers every natives-package module's own free functions
// (gfx/colour_utils/sound/box2d/socket/pickle/process/physics/re/
// inspect), matching sys/os -- every object-constructing one of those
// returns a real Kind (Window, Texture, Sound, ...), not Dynamic. Not
// covered: the *methods* those objects expose (Window.rectangle,
// Texture.draw, Sound.play, Socket.recv, Box2DWorld.add_circle, and so
// on) -- typecheck_property (typecheck_expr.odin) has no dispatch case
// for any native object kind, so a call through one falls through to its
// permissive default and stays fully unchecked, same as an ordinary
// untyped value.

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

	// Native object kinds -- mirrors compiler.Type_Kind's own matching set
	// one-for-one (see that enum's own doc comment for why each is a flat
	// kind, no auxiliary data).
	Window,
	Image,
	Texture,
	Render_Texture,
	Shader,
	Camera3D,
	Batch,
	Batch2D,
	Batch_Instanced,
	Light,
	Sound,
	Music,
	Socket,
	Process,
	Box2D_World,
	Physics_World,
	Pattern,
	Match,
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
// error text, reused verbatim so the message matches whether it's caught
// at compile time or, for an untypeable call site, only later at
// runtime. An empty Arity_Message means arity is never diagnosed for
// this signature, because the real implementation doesn't enforce it
// either (e.g. rand(), which silently ignores any arguments passed to
// it) -- diagnosing a mismatch the runtime itself tolerates would be a
// false positive.
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

	// --- natives/gfx.odin, gfx_window/image/texture/camera/shader/batch*/
	// light.odin: object-constructor free functions. gfx.texture's image
	// param and gfx.batch_instanced's texture param are now real kinds
	// too. gfx.shader's real arity is "0 or 2", which Min/Max_Args can't
	// express without also accepting 1 -- Arity_Message is left empty so
	// a 1-argument call isn't misdiagnosed. instanced_ambient stays
	// Dynamic -- it returns nil, not an object. ---
	{module = "gfx", name = "encode_rgba", min_args = 3, max_args = 3, params = {{accepted = {.Int}}, {accepted = {.Int}}, {accepted = {.Int}}}, returns = .Float, arity_message = "encode_rgba expects 3 arguments"},
	{module = "gfx", name = "decode_rgba", min_args = 1, max_args = 1, params = {{accepted = STRICT_FLOAT}}, returns = .List, arity_message = "decode_rgba expects 1 float argument"},
	{module = "gfx", name = "float_array", min_args = 2, max_args = 2, params = {{accepted = {.Int}}, {accepted = {.Int}}}, returns = .Dynamic, arity_message = "Invalid argument count to float_array."},
	{module = "gfx", name = "float_array_3d", min_args = 3, max_args = 3, params = {{accepted = {.Int}}, {accepted = {.Int}}, {accepted = {.Int}}}, returns = .Dynamic, arity_message = "Invalid argument count to float_array_3d."},
	{module = "gfx", name = "window", min_args = 2, max_args = 2, params = {{accepted = {.Int}}, {accepted = {.Int}}}, returns = .Window, arity_message = "window() expects 2 arguments (width, height)."},
	{module = "gfx", name = "image", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Image, arity_message = "image() expects 1 argument (filename)."},
	{module = "gfx", name = "texture", min_args = 4, max_args = 4, params = {{accepted = {.Image}}, {accepted = {.Int}}, {accepted = {.Int}}, {accepted = {.Int}}}, returns = .Texture, arity_message = "texture() expects 4 arguments (image, frames, start_frame, end_frame)."},
	{module = "gfx", name = "render_texture", min_args = 2, max_args = 2, params = {{accepted = {.Int}}, {accepted = {.Int}}}, returns = .Render_Texture, arity_message = "render_texture() expects 2 arguments (width, height)."},
	{module = "gfx", name = "shader", min_args = 0, max_args = 2, params = {{accepted = STRING}, {accepted = STRING}}, returns = .Shader, arity_message = ""},
	{module = "gfx", name = "camera", min_args = 3, max_args = 3, params = {{accepted = {.Vec3}}, {accepted = {.Vec3}}, {accepted = {.Vec3}}}, returns = .Camera3D, arity_message = "camera() expects 3 arguments: position(vec3), target(vec3), up(vec3)."},
	{module = "gfx", name = "batch", min_args = 1, max_args = 1, params = {{accepted = {.Int}}}, returns = .Batch, arity_message = "batch() expects 1 argument (a win.BATCH_* constant)."},
	{module = "gfx", name = "batch2d", min_args = 1, max_args = 1, params = {{accepted = {.Int}}}, returns = .Batch2D, arity_message = "batch2d() expects 1 argument (a win.BATCH2D_* constant)."},
	{module = "gfx", name = "batch_instanced", min_args = 3, max_args = 3, params = {{accepted = {.Texture}}, {accepted = STRICT_FLOAT}, {accepted = {.Int}}}, returns = .Batch_Instanced, arity_message = "batch_instanced() expects 3 arguments (texture, cube_size, max_instances)."},
	{module = "gfx", name = "instanced_light", min_args = 4, max_args = 4, params = {{accepted = {.Int}}, {accepted = {.Vec3}}, {accepted = {.Vec3}}, {accepted = {.Vec4}}}, returns = .Light, arity_message = "instanced_light() expects 4 arguments (type, position, target, color)."},
	{module = "gfx", name = "instanced_ambient", min_args = 1, max_args = 1, params = {{accepted = {.Vec4}}}, returns = .Dynamic, arity_message = "instanced_ambient() expects 1 argument (color)."},

	// --- natives/colour_utils.odin: every function accepts int-or-float
	// components (coerced via core.as_float) and returns a vec4. ---
	{module = "colour_utils", name = "fade", min_args = 4, max_args = 4, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec4, arity_message = "fade expects 4 arguments (r, g, b, alpha)"},
	{module = "colour_utils", name = "tint", min_args = 6, max_args = 6, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec4, arity_message = "tint expects 6 arguments (r1, g1, b1, r2, g2, b2)"},
	{module = "colour_utils", name = "brightness", min_args = 4, max_args = 4, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec4, arity_message = "brightness expects 4 arguments (r, g, b, factor)"},
	{module = "colour_utils", name = "lerp", min_args = 7, max_args = 7, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec4, arity_message = "lerp expects 7 arguments (r1, g1, b1, r2, g2, b2, amount)"},
	{module = "colour_utils", name = "hsv_to_rgb", min_args = 3, max_args = 3, params = {{accepted = NUMERIC}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Vec4, arity_message = "hsv_to_rgb expects 3 arguments (h, s, v)"},
	{module = "colour_utils", name = "random", min_args = 0, max_args = 0, params = {}, returns = .Vec4, arity_message = "random expects 0 arguments"},

	// --- natives/sound.odin: module-level device/asset functions. ---
	{module = "sound", name = "init", min_args = 0, max_args = 0, params = {}, returns = .Dynamic, arity_message = "init() takes no arguments."},
	{module = "sound", name = "close", min_args = 0, max_args = 0, params = {}, returns = .Dynamic, arity_message = "close() takes no arguments."},
	{module = "sound", name = "is_ready", min_args = 0, max_args = 0, params = {}, returns = .Bool, arity_message = "is_ready() takes no arguments."},
	{module = "sound", name = "set_master_volume", min_args = 1, max_args = 1, params = {{accepted = NUMERIC}}, returns = .Dynamic, arity_message = "set_master_volume() expects 1 argument (volume)."},
	{module = "sound", name = "get_master_volume", min_args = 0, max_args = 0, params = {}, returns = .Float, arity_message = "get_master_volume() takes no arguments."},
	{module = "sound", name = "load", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Sound, arity_message = "load() expects 1 argument (filename)."},
	{module = "sound", name = "load_music", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Music, arity_message = "load_music() expects 1 argument (filename)."},

	// --- natives/box2d.odin ---
	{module = "box2d", name = "world", min_args = 1, max_args = 1, params = {{accepted = {.Vec2}}}, returns = .Box2D_World, arity_message = "world() expects 1 argument (gravity)."},

	// --- natives/socket.odin ---
	{module = "socket", name = "connect", min_args = 2, max_args = 2, params = {{accepted = STRING}, {accepted = NUMERIC}}, returns = .Socket, arity_message = "connect() expects 2 arguments (host, port)."},
	{module = "socket", name = "listen", min_args = 2, max_args = 3, params = {{accepted = STRING}, {accepted = NUMERIC}, {accepted = NUMERIC}}, returns = .Socket, arity_message = "listen() expects 2 or 3 arguments (host, port, backlog=1000)."},

	// --- natives/pickle.odin: dumps() accepts any value, unconstrained. ---
	{module = "pickle", name = "dumps", min_args = 1, max_args = 1, params = {{}}, returns = .String, arity_message = "Invalid argument count to dumps."},
	{module = "pickle", name = "loads", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Dynamic, arity_message = "Invalid argument count to loads."},

	// --- natives/process.odin: spawn/start's extra args (script's own
	// sys.args()) must all be strings, checked via Variadic_Tail. ---
	{module = "process", name = "spawn", min_args = 1, max_args = -1, params = {{accepted = STRING}}, variadic_tail = STRING, returns = .Process, arity_message = "spawn() expects at least 1 argument (script path)."},
	{module = "process", name = "start", min_args = 1, max_args = -1, params = {{accepted = STRING}}, variadic_tail = STRING, returns = .Process, arity_message = "start() expects at least 1 argument (script path)."},
	{module = "process", name = "parent", min_args = 0, max_args = 0, params = {}, returns = .Process, arity_message = "parent() expects no arguments."},
	{module = "process", name = "wait_any", min_args = 1, max_args = 1, params = {{accepted = {.List}}}, returns = .Dynamic, arity_message = "wait_any() expects 1 argument (a list of processes)."},

	// --- natives/physics.odin ---
	{module = "physics", name = "physics_world", min_args = 4, max_args = 4, params = {{accepted = {.Vec3}}, {accepted = {.Vec3}}, {accepted = NUMERIC}, {accepted = {.Vec3}}}, returns = .Physics_World, arity_message = "physics_world() expects 4 arguments (min, max, cell_size, gravity)."},

	// --- natives/re.odin. sub's trailing count is strictly checked
	// (Int); subn/split's trailing count/maxsplit are read via core.as_int
	// with no type check in the real implementation, so left unconstrained
	// to match. ---
	{module = "re", name = "search", min_args = 2, max_args = 2, params = {{accepted = STRING}, {accepted = STRING}}, returns = .Match, arity_message = "Invalid argument count to re.search."},
	{module = "re", name = "match", min_args = 2, max_args = 2, params = {{accepted = STRING}, {accepted = STRING}}, returns = .Match, arity_message = "Invalid argument count to re.match."},
	{module = "re", name = "fullmatch", min_args = 2, max_args = 2, params = {{accepted = STRING}, {accepted = STRING}}, returns = .Match, arity_message = "Invalid argument count to re.fullmatch."},
	{module = "re", name = "sub", min_args = 3, max_args = 4, params = {{accepted = STRING}, {accepted = STRING}, {accepted = STRING}, {accepted = {.Int}}}, returns = .String, arity_message = "re.sub expects 3 or 4 arguments."},
	{module = "re", name = "subn", min_args = 3, max_args = 4, params = {{accepted = STRING}, {accepted = STRING}, {accepted = STRING}, {}}, returns = .List, arity_message = "re.subn expects 3 or 4 arguments."},
	{module = "re", name = "split", min_args = 2, max_args = 3, params = {{accepted = STRING}, {accepted = STRING}, {}}, returns = .List, arity_message = "re.split expects 2 or 3 arguments."},
	{module = "re", name = "findall", min_args = 2, max_args = 2, params = {{accepted = STRING}, {accepted = STRING}}, returns = .List, arity_message = "Invalid argument count to re.findall."},
	{module = "re", name = "compile", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Pattern, arity_message = "Invalid argument count to re.compile."},

	// --- natives/inspect.odin: neither function checks argc at runtime,
	// so arity is left undiagnosed here too (same rationale as rand()). ---
	{module = "inspect", name = "get_frame", min_args = 0, max_args = -1, params = {}, returns = .Dict, arity_message = ""},
	{module = "inspect", name = "dump_frame", min_args = 0, max_args = -1, params = {}, returns = .Dynamic, arity_message = ""},
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
