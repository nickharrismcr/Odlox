package core

import rl "vendor:raylib"

// Render_Texture_Object wraps a raylib off-screen render target (an
// FBO). Ported from glox's obj_builtin_render_texture.go -- minus the
// persistent arrayTexture used by draw_array_fast (not implemented in
// this pass, see gfx_window.odin's header comment on deferred scope).
Render_Texture_Object :: struct {
	using obj:      Obj,
	width, height:  int,
	render_texture: rl.RenderTexture2D,
	freed:          bool, // idempotent-unload guard, same convention as Texture_Object
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
}
