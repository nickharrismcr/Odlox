package core

import rl "vendor:raylib"

// Camera_Object wraps a raylib 3D camera. Always perspective projection
// with a 45° default field of view -- there is no way to change
// projection mode or construct an orthographic camera from Lox.
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
