package core

import rl "vendor:raylib"

// Window_Object: the Lox-facing handle for raylib's window/graphics
// context. raylib's own window/OpenGL-context state is process-global
// (InitWindow/CloseWindow), so this struct is mostly a lightweight
// marker plus the width/height a script asked for, and the lazily-built
// shared unit-cube mesh/material `cube_rotated`/`cube_wires_rotated`
// need (raylib has no DrawCube overload that takes a rotation, so those
// draw an arbitrarily rotated box via DrawMesh with a transform matrix
// instead -- one shared unit cube serves every box regardless of size,
// scaled at draw time); the actual raylib calls live in
// vm/gfx_window.odin's invoke_builtin_window, same split as every other
// native object type here.
Window_Object :: struct {
	using obj: Obj,
	width:     int,
	height:    int,
	closed:    bool, // latched by .close() so a second call is a no-op, not a second CloseWindow()
	show_fps:  bool, // toggled by .show_fps(bool) -- see gfx_window.odin's "end" case

	cube_mesh:       rl.Mesh,
	cube_material:   rl.Material,
	cube_mesh_ready: bool,
}

make_window_object :: proc(width, height: int) -> ^Window_Object {
	o := new(Window_Object)
	o.obj.type = .Window
	o.width = width
	o.height = height
	return o
}

// window_cube_model lazily creates and caches a shared unit cube mesh +
// default material -- see this file's own header comment for why. Never
// explicitly unloaded: Window_Object as a whole has no GC-triggered GPU
// teardown at all (see vm/gc.odin's `.Window` case) -- process exit
// tears down the whole GL context regardless.
window_cube_model :: proc(w: ^Window_Object) -> (rl.Mesh, rl.Material) {
	if !w.cube_mesh_ready {
		w.cube_mesh = rl.GenMeshCube(1, 1, 1)
		if w.cube_mesh.vaoId == 0 {
			rl.UploadMesh(&w.cube_mesh, false)
		}
		w.cube_material = rl.LoadMaterialDefault()
		w.cube_mesh_ready = true
	}
	return w.cube_mesh, w.cube_material
}
