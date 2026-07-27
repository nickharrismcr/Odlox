package core

// Window_Object: the Lox-facing handle for raylib's window/graphics
// context. Ported from glox's obj_builtin_window.go's Graphics struct,
// minus the lazily-built unit-cube mesh (3D drawing is out of scope for
// this pass -- see vm/gfx_window.odin's header comment). raylib's own
// window/OpenGL-context state is process-global (InitWindow/
// CloseWindow), so this struct is mostly a lightweight marker plus the
// width/height a script asked for; the actual raylib calls live in
// vm/gfx_window.odin's invoke_builtin_window, same split as every other
// native object type in this port.
Window_Object :: struct {
	using obj: Obj,
	width:     int,
	height:    int,
	closed:    bool, // latched by .close() so a second call is a no-op, not a second CloseWindow()
}

make_window_object :: proc(width, height: int) -> ^Window_Object {
	o := new(Window_Object)
	o.obj.type = .Window
	o.width = width
	o.height = height
	return o
}
