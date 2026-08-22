package natives

import "../vm"

// natives is the raylib-backed native-object/function package -- the
// counterpart of vm's define_builtins for everything that isn't a
// core-language builtin. natives imports vm directly, taking a concrete
// ^vm.VM; vm never imports natives back, so the dependency graph stays a
// strict DAG (core <- compiler <- vm <- natives). Builtin_Fn's `vm`
// parameter is an opaque rawptr rather than ^vm.VM since core sits below
// vm in the package graph.

// define_natives registers every native object/function with v -- called
// from main.odin right after vm.define_builtins. Most modules it registers
// are raylib-backed (colour_utils, gfx, sound); physics and box2d are not
// (physics is hand-rolled, box2d wraps vendor:box2d). Each module is
// implemented in its own sibling file; see that file's own doc comment for
// what it covers.
define_natives :: proc(v: ^vm.VM) {
	register_colour_utils(v)
	register_gfx(v)
	register_physics(v)
	register_box2d(v)
	register_inspect(v)
	register_re(v)
	register_pickle(v)
	register_process(v)
	register_socket(v)
	register_sound(v)
}
