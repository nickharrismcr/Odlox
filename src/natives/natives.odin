package natives

import "../vm"

// natives is the raylib-backed native-object/function package -- the
// counterpart of vm's own define_builtins for everything that isn't a
// core-language builtin (window/2D drawing, texture/shader/batch/camera/
// render_texture/image/physics_world, and float_array/vec2/vec3/vec4
// methods beyond basic arithmetic). See docs/ARCHITECTURE.md's Native/
// builtin functions section for the package-boundary design this plugs
// into: natives imports vm directly, taking a concrete ^vm.VM, rather
// than an abstract context interface (Odin has no structural interfaces
// the way Go's core.VMContext relies on) -- vm never imports natives
// back, so the dependency graph stays a strict DAG (core <- compiler <-
// vm <- natives, with main at the top wiring everything together).
//
// This file is intentionally just the registration entry point and
// nothing else -- ROADMAP.md's Phase 6b is what actually populates it,
// starting with window/2D drawing (raylib's smallest surface, and the
// one with the most existing _ns-suffixed test coverage able to
// validate non-graphics logic before graphics itself is wired up).
// core.Builtin_Fn/vm.define_builtin (the same registration mechanism
// vm's own core builtins already use) are what each native function
// added here will be registered through -- see core/obj_native.odin's
// doc comment for why Builtin_Fn's own `vm` parameter is an opaque
// rawptr rather than ^vm.VM (core sits below vm in the package graph
// and can't name that type), and vm/builtins.odin's define_builtin for
// the wrapper that casts it back on this package's behalf.

// define_natives registers every native (raylib-backed) object/function
// with v -- called from main.odin right after vm.define_builtins, the
// same way that proc's own doc comment describes. colour_utils/gfx/
// physics (this file's siblings) are the first real content: colour_utils
// in full, gfx/physics only as much as doesn't need raylib itself yet
// (see gfx.odin/physics.odin's own doc comments for exactly what's still
// missing and why).
define_natives :: proc(v: ^vm.VM) {
	register_colour_utils(v)
	register_gfx(v)
	register_physics(v)
	register_inspect(v)
	register_re(v)
	register_pickle(v)
	register_process(v)
}
