package core

import rl "vendor:raylib"

// Image_Object wraps a CPU-side (RAM) raylib image -- the source
// gfx.texture() loads a GPU texture from. Ported from glox's
// obj_builtin_image.go. Unlike glox, which never frees the underlying
// rl.Image once loaded (ImageObject has no GCFree/unload at all -- a
// real, undocumented gap in glox itself), this port does free it on
// collection (see vm/gc.odin's free_object) -- a strict, safe
// improvement: Image's own Lox-facing surface (width/height) never
// touches the pixel data again once a Texture has been built from it,
// so freeing it when the Image object itself becomes unreachable
// changes no observable behavior.
Image_Object :: struct {
	using obj:     Obj,
	width, height: int,
	image:         rl.Image,
}

make_image_object :: proc(width, height: int, image: rl.Image) -> ^Image_Object {
	o := new(Image_Object)
	o.obj.type = .Image
	o.width = width
	o.height = height
	o.image = image
	return o
}
