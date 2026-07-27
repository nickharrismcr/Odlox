package core

import rl "vendor:raylib"

// Render_Texture_Object wraps a raylib off-screen render target (an
// FBO). Ported from glox's obj_builtin_render_texture.go, including its
// persistent array_texture used by draw_array_fast (vm/gfx_texture.odin):
// recreating (Load/Unload) a texture every frame races with the GPU
// driver's double-buffered pipeline -- the new texture can reuse an ID
// still referenced by an in-flight draw from the previous frame,
// producing stray stale-colour pixels. Updating one long-lived texture
// in place avoids that, same reasoning as glox's own arrayTexture field.
Render_Texture_Object :: struct {
	using obj:      Obj,
	width, height:  int,
	render_texture: rl.RenderTexture2D,
	freed:          bool, // idempotent-unload guard, same convention as Texture_Object

	array_texture:       rl.Texture2D,
	array_texture_w:     int,
	array_texture_h:     int,
	array_texture_valid: bool,
}

make_render_texture_object :: proc(width, height: int) -> ^Render_Texture_Object {
	rt := rl.LoadRenderTexture(i32(width), i32(height))
	o := new(Render_Texture_Object)
	o.obj.type = .Render_Texture
	o.width = width
	o.height = height
	o.render_texture = rt
	return o
}

render_texture_unload :: proc(rt: ^Render_Texture_Object) {
	if rt.freed {
		return
	}
	rt.freed = true
	rl.UnloadRenderTexture(rt.render_texture)
	if rt.array_texture_valid {
		rl.UnloadTexture(rt.array_texture)
	}
}
