package core

import rl "vendor:raylib"

// Camera_Object wraps a raylib 3D camera. Ported from glox's
// obj_builtin_camera.go -- always perspective projection with a 45°
// default field of view, matching glox's own constructor exactly (glox
// exposes no way to change projection mode or construct an orthographic
// camera, so this port doesn't invent one either).
Camera_Object :: struct {
	using obj: Obj,
	camera:    rl.Camera3D,
}

make_camera_object :: proc(position, target, up: rl.Vector3) -> ^Camera_Object {
	o := new(Camera_Object)
	o.obj.type = .Camera
	o.camera = rl.Camera3D {
		position   = position,
		target     = target,
		up         = up,
		fovy       = 45.0,
		projection = .PERSPECTIVE,
	}
	return o
}
