package vm

import "../core"
import "core:fmt"
import "core:math/rand"
import "core:strconv"
import "core:strings"

// Port of glox's src/vm/builtin.go's core (non-raylib) registrations --
// the free functions and the sys/os module functions. glox's own split
// (src/vm/builtin.go for core, src/builtin/*.go for the much larger
// raylib-backed surface) maps onto this port's package layout exactly:
// core builtins live directly in `vm` (this file plus builtins_math.odin/
// builtins_sys.odin/builtins_os.odin), and the raylib-backed equivalent
// of glox's src/builtin becomes odlox's `natives` package -- not created
// yet, since there's nothing to put in it until that sub-phase.
//
// define_builtins is an explicit, separate step from new_vm (see
// vm.odin's doc comment) -- a caller can construct a VM and skip this
// entirely, same as glox's own `defineBuiltins` being optional
// (`-s`/`--skip-builtins`).

// native_vm is the one place a Builtin_Fn's raw `vm: rawptr` parameter
// gets cast back to a concrete `^VM` -- see obj_native.odin's doc
// comment on Builtin_Fn for why that boundary exists at all. Every
// builtin proc in this file and its siblings starts with this line
// instead of writing the cast inline.
native_vm :: proc(vm_ptr: rawptr) -> ^VM {
	return (^VM)(vm_ptr)
}

define_builtins :: proc(vm: ^VM) {
	make_builtin_module(vm, "sys")
	make_builtin_module(vm, "os")

	define_builtin(vm, "", "type", type_builtin)
	define_builtin(vm, "", "len", len_builtin)
	define_builtin(vm, "", "append", append_builtin)
	define_builtin(vm, "", "float", float_builtin)
	define_builtin(vm, "", "int", int_builtin)
	define_builtin(vm, "", "rand", rand_builtin)
	define_builtin(vm, "", "replace", replace_builtin)
	define_builtin(vm, "", "format", format_builtin)
	define_builtin(vm, "", "range", range_builtin)
	define_builtin(vm, "", "vec2", vec2_builtin)
	define_builtin(vm, "", "vec3", vec3_builtin)
	define_builtin(vm, "", "vec4", vec4_builtin)

	define_math_builtins(vm)
	define_sys_builtins(vm)
	define_os_builtins(vm)

	// Do NOT inject sys/os into the global environment here -- a script
	// must `import sys`/`import os` explicitly, same as any other
	// module (see module.odin's do_import).
}

// seed_builtin_globals is what actually makes `type(1)`/`len(x)`/...
// resolvable at all: the compiler assigns every referenced name a
// global slot purely from source (see compiler_state.odin's
// global_slot -- "first mention wins"), with no notion that some
// names are builtins, so a bare call to a builtin free function
// compiles to an ordinary Op_Get_Global on a slot nothing has called
// Define_Global for. Op_Get_Global has no map-fallback path of its
// own (by design -- see run.odin, a direct slice index is the whole
// point of slot-indexed globals over glox's earlier map-backed one) --
// mirrors glox's own initGlobals: after every compile, walk the
// slots this compilation unit's top-level chunk actually names
// (fn.chunk.global_names is only populated there -- see chunk.odin)
// and seed any still-undefined slot whose name matches a registered
// builtin or built-in module. "Still-undefined" matters for the REPL
// (and for module re-imports) exactly as it does in glox: a slot the
// script has already assigned into must never be clobbered back to
// the builtin, or a user global that happens to shadow a builtin name
// would silently revert on the next line.
seed_builtin_globals :: proc(vm: ^VM, fn: ^core.Function_Object) {
	for name, slot in fn.chunk.global_names {
		if slot < len(vm.environment.defined) && vm.environment.defined[slot] {
			continue
		}
		id := core.intern_string(name)
		if v, ok := vm.builtins[id]; ok {
			core.env_set_global(vm.environment, slot, v)
			core.env_set_var(vm.environment, id, v)
			continue
		}
		if mod, ok := vm.builtin_modules[id]; ok {
			v := core.make_object_value(&mod.obj)
			core.env_set_global(vm.environment, slot, v)
			core.env_set_var(vm.environment, id, v)
		}
	}
}

// Package-public (not private) -- the natives package (Phase 6b+)
// creates its own built-in modules (gfx, colour_utils, physics, ...)
// through this exact same mechanism, same reasoning as define_builtin's
// own doc comment just below.
make_builtin_module :: proc(vm: ^VM, name: string) {
	env := core.make_environment(name)
	mod := core.make_module_object(name, env)
	vm.builtin_modules[core.intern_string(name)] = mod
}

// define_builtin registers fn as name, either globally (module == "")
// or as a member of an already-created built-in module. Package-public
// (not file- or package-private) since the natives package (Phase 6b+)
// registers its own native functions through this exact same mechanism --
// see docs/ARCHITECTURE.md's Native/builtin functions section for why
// natives imports vm directly rather than through an abstract interface.
define_builtin :: proc(vm: ^VM, module: string, name: string, fn: core.Builtin_Fn) {
	native := core.make_native_object(fn)
	val := core.make_object_value(&native.obj)
	if module == "" {
		vm.builtins[core.intern_string(name)] = val
		return
	}
	mod := vm.builtin_modules[core.intern_string(module)]
	core.env_set_var(mod.environment, core.intern_string(name), val)
}

// -----------------------------------------------------------------------
// Core free functions (glox's builtin.core_functions.go)

@(private = "file")
type_name :: proc(v: core.Value) -> string {
	#partial switch v.type {
	case .Int:
		return "int"
	case .Float:
		return "float"
	case .Bool:
		return "boolean"
	case .Nil:
		return "nil"
	case .Vec2:
		return "vec2"
	case .Vec3:
		return "vec3"
	case .Vec4:
		return "vec4"
	case .Obj:
		#partial switch v.obj_type {
		case .String:
			return "string"
		case .Function:
			return "function"
		case .Closure:
			return "closure"
		case .List:
			return "list"
		case .Native:
			return "builtin"
		case .Dict:
			return "dict"
		case .Class:
			return "class"
		case .Instance:
			return "instance"
		case .Module:
			return "module"
		case .File:
			return "file"
		case .Float_Array:
			// Matches glox's own type() exactly: FloatArrayObject.GetType()
			// (obj_builtin_farray.go) deliberately returns OBJECT_NATIVE,
			// not a dedicated float-array kind, so glox's type() reports
			// "builtin" for it too -- not a claim that it literally *is* a
			// bare native function, just glox's own established behavior
			// this port matches rather than "corrects".
			return "builtin"
		case .Regex_Pattern, .Regex_Match:
			// Matches glox's own type() exactly -- RegexPatternObject/
			// RegexMatchObject.GetType() (obj_builtin_regex_*.go) both
			// deliberately return OBJECT_NATIVE, same reasoning as
			// Float_Array above.
			return "builtin"
		case .Process:
			// Matches glox's own type() exactly -- ProcessObject.GetType()
			// (obj_builtin_process.go) also returns OBJECT_NATIVE.
			return "builtin"
		case .Physics_World:
			// Matches glox's own type() exactly -- PhysicsWorldObject.GetType()
			// (obj_builtin_physics_world.go) also returns OBJECT_NATIVE.
			return "builtin"
		case .Window:
			// Matches glox's own type() exactly -- WindowObject.GetType()
			// (obj_builtin_window.go) also returns OBJECT_NATIVE.
			return "builtin"
		case .Image, .Texture, .Render_Texture, .Shader, .Camera, .Batch, .Batch_Instanced:
			// Matches glox's own type() exactly -- ImageObject/TextureObject/
			// RenderTextureObject/ShaderObject/CameraObject/BatchObject.GetType()
			// (obj_builtin_image.go, obj_builtin_texture.go,
			// obj_builtin_render_texture.go, obj_builtin_shader.go,
			// obj_builtin_camera.go, obj_builtin_batch.go) all return
			// OBJECT_NATIVE.
			return "builtin"
		}
	}
	return ""
}

@(private = "file")
type_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 {
		runtime_error(vm, "Single argument expected.")
		return core.NIL_VALUE
	}
	return core.make_string_value(type_name(vm.stack[arg_stack_ptr]))
}

@(private = "file")
len_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 {
		runtime_error(vm, "Invalid argument count to len.")
		return core.NIL_VALUE
	}
	val := vm.stack[arg_stack_ptr]
	if val.type != .Obj {
		runtime_error(vm, "Invalid argument type to len.")
		return core.NIL_VALUE
	}
	#partial switch val.obj_type {
	case .String:
		return core.make_int_value(core.string_length(core.as_string(val)))
	case .List:
		return core.make_int_value(core.list_length(core.as_list(val)))
	}
	runtime_error(vm, "Invalid argument type to len.")
	return core.NIL_VALUE
}

@(private = "file")
append_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 2 {
		runtime_error(vm, "Invalid argument count to append.")
		return core.NIL_VALUE
	}
	val := vm.stack[arg_stack_ptr]
	if val.type != .Obj || val.obj_type != .List {
		runtime_error(vm, "Argument 1 to append must be list.")
		return core.NIL_VALUE
	}
	l := core.as_list(val)
	if l.is_tuple {
		runtime_error(vm, "Tuples are immutable")
		return core.NIL_VALUE
	}
	core.list_append(l, vm.stack[arg_stack_ptr + 1])
	return val
}

@(private = "file")
float_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 {
		runtime_error(vm, "Single argument expected.")
		return core.NIL_VALUE
	}
	arg := vm.stack[arg_stack_ptr]
	#partial switch arg.type {
	case .Float:
		return arg
	case .Int:
		return core.make_float_value(f64(core.as_int(arg)))
	case .Obj:
		if arg.obj_type == .String {
			f, ok := strconv.parse_f64(core.string_get(core.as_string(arg)))
			if !ok {
				runtime_error(vm, "Could not parse string into float.")
				return core.NIL_VALUE
			}
			return core.make_float_value(f)
		}
	}
	runtime_error(vm, "Argument must be number or valid string")
	return core.NIL_VALUE
}

@(private = "file")
int_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 {
		runtime_error(vm, "Single argument expected.")
		return core.NIL_VALUE
	}
	arg := vm.stack[arg_stack_ptr]
	#partial switch arg.type {
	case .Int:
		return arg
	case .Float:
		return core.make_int_value(int(core.as_float(arg)))
	case .Obj:
		if arg.obj_type == .String {
			i, ok := strconv.parse_int(core.string_get(core.as_string(arg)))
			if !ok {
				runtime_error(vm, "Could not parse string into int.")
				return core.NIL_VALUE
			}
			return core.make_int_value(i)
		}
	}
	runtime_error(vm, "Argument must be number or valid string.")
	return core.NIL_VALUE
}

@(private = "file")
rand_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	return core.make_float_value(rand.float64())
}

@(private = "file")
replace_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 3 {
		runtime_error(vm, "Invalid argument count to replace.")
		return core.NIL_VALUE
	}
	target := vm.stack[arg_stack_ptr]
	from := vm.stack[arg_stack_ptr + 1]
	to := vm.stack[arg_stack_ptr + 2]
	if !core.is_string(target) || !core.is_string(from) || !core.is_string(to) {
		runtime_error(vm, "Invalid argument type to replace.")
		return core.NIL_VALUE
	}
	return core.string_replace(core.as_string(target), core.as_string(from), core.as_string(to))
}

// format ports glox's FormatBuiltIn (Go's fmt.Sprintf over converted
// Lox values). Odin's core:fmt verbs are otherwise a close match for
// Go's, with one default that differs enough to break the exact
// expected output the ported test suite checks: a bare `%f` with no
// explicit precision is 3 decimal places in Odin vs. Go's 6 -- see
// rewrite_bare_percent_f below for the (deliberately narrow, not a
// general printf reimplementation) fix.
@(private = "file")
format_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc < 1 {
		runtime_error(vm, "format expects at least 1 argument")
		return core.NIL_VALUE
	}
	template_val := vm.stack[arg_stack_ptr]
	if !core.is_string(template_val) {
		runtime_error(vm, "format template must be a string")
		return core.NIL_VALUE
	}
	template := rewrite_bare_percent_f(core.string_get(core.as_string(template_val)))
	defer delete(template)

	// `any` only ever stores a pointer to its underlying value, never a
	// copy -- boxing each converted value on the heap (freed below,
	// once aprintf has consumed them) instead of returning `any` from
	// a helper proc, which would silently wrap the address of that
	// proc's own temporary and dangle the moment it returned. Found by
	// an actual segfault on the very first `format(...)` smoke test.
	args := make([dynamic]any, 0, argc - 1)
	defer delete(args)
	boxes := make([dynamic]rawptr, 0, argc - 1)
	defer {
		for p in boxes {
			free(p)
		}
		delete(boxes)
	}
	for i in 1 ..< argc {
		v := vm.stack[arg_stack_ptr + i]
		#partial switch v.type {
		case .Int:
			p := new(int)
			p^ = core.as_int(v)
			append(&args, p^)
			append(&boxes, rawptr(p))
		case .Float:
			p := new(f64)
			p^ = core.as_float(v)
			append(&args, p^)
			append(&boxes, rawptr(p))
		case .Bool:
			p := new(bool)
			p^ = core.as_bool(v)
			append(&args, p^)
			append(&boxes, rawptr(p))
		case .Nil:
			append(&args, nil)
		case .Obj:
			p := new(string)
			p^ = core.string_get(core.as_string(v)) if v.obj_type == .String else core.value_to_string(v)
			append(&args, p^)
			append(&boxes, rawptr(p))
		case:
			p := new(string)
			p^ = core.value_to_string(v)
			append(&args, p^)
			append(&boxes, rawptr(p))
		}
	}

	result := fmt.aprintf(template, ..args[:])
	defer delete(result)
	return core.make_string_value(result)
}

@(private = "file")
rewrite_bare_percent_f :: proc(template: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	i := 0
	for i < len(template) {
		c := template[i]
		if c != '%' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		// Copy the '%' and scan the verb: flags/width/precision chars
		// followed by exactly one letter. Only a bare `%f` (no '.'
		// precision already present) gets `.6` inserted.
		start := i
		i += 1
		for i < len(template) && !is_verb_letter(template[i]) {
			i += 1
		}
		if i >= len(template) {
			strings.write_string(&b, template[start:i])
			break
		}
		verb := template[start:i+1]
		if template[i] == 'f' && !strings.contains(verb, ".") {
			strings.write_string(&b, verb[:len(verb) - 1])
			strings.write_string(&b, ".6f")
		} else {
			strings.write_string(&b, verb)
		}
		i += 1
	}
	return strings.to_string(b)
}

@(private = "file")
is_verb_letter :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private = "file")
range_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc < 1 || argc > 3 {
		runtime_error(vm, "range expects 1 to 3 arguments")
		return core.NIL_VALUE
	}
	start, end, step := 0, 0, 1
	switch argc {
	case 1:
		end = core.as_int(vm.stack[arg_stack_ptr])
	case 2:
		start = core.as_int(vm.stack[arg_stack_ptr])
		end = core.as_int(vm.stack[arg_stack_ptr + 1])
	case 3:
		start = core.as_int(vm.stack[arg_stack_ptr])
		end = core.as_int(vm.stack[arg_stack_ptr + 1])
		step = core.as_int(vm.stack[arg_stack_ptr + 2])
	}
	if step == 0 {
		runtime_error(vm, "step cannot be zero")
		return core.NIL_VALUE
	}
	it := core.make_int_iterator_object(start, end, step)
	gc_track(vm, &it.obj)
	return core.make_object_value(&it.obj)
}

@(private = "file")
vec2_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 2 {
		runtime_error(vm, "vec2 expects 2 arguments (x,y)")
		return core.NIL_VALUE
	}
	x, y := vm.stack[arg_stack_ptr], vm.stack[arg_stack_ptr + 1]
	if !core.is_number(x) || !core.is_number(y) {
		runtime_error(vm, "vec2 arguments must be numbers")
		return core.NIL_VALUE
	}
	v := core.make_vec2_value(core.as_float(x), core.as_float(y))
	gc_track(vm, v.obj)
	return v
}

@(private = "file")
vec3_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 3 {
		runtime_error(vm, "vec3 expects 3 arguments (x,y,z)")
		return core.NIL_VALUE
	}
	x, y, z := vm.stack[arg_stack_ptr], vm.stack[arg_stack_ptr + 1], vm.stack[arg_stack_ptr + 2]
	if !core.is_number(x) || !core.is_number(y) || !core.is_number(z) {
		runtime_error(vm, "vec3 arguments must be numbers")
		return core.NIL_VALUE
	}
	v := core.make_vec3_value(core.as_float(x), core.as_float(y), core.as_float(z))
	gc_track(vm, v.obj)
	return v
}

@(private = "file")
vec4_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 4 {
		runtime_error(vm, "vec4 expects 4 arguments (x,y,z,w)")
		return core.NIL_VALUE
	}
	x := vm.stack[arg_stack_ptr]
	y := vm.stack[arg_stack_ptr + 1]
	z := vm.stack[arg_stack_ptr + 2]
	w := vm.stack[arg_stack_ptr + 3]
	if !core.is_number(x) || !core.is_number(y) || !core.is_number(z) || !core.is_number(w) {
		runtime_error(vm, "vec4 arguments must be numbers")
		return core.NIL_VALUE
	}
	v := core.make_vec4_value(core.as_float(x), core.as_float(y), core.as_float(z), core.as_float(w))
	gc_track(vm, v.obj)
	return v
}
