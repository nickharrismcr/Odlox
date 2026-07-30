package core

import rl "vendor:raylib"

// Texture_Object wraps a GPU-loaded raylib texture, optionally sliced
// into `frames` equal-width horizontal animation frames (frame N
// occupies x in [(N-1)*frame_width, N*frame_width)).
Texture_Object :: struct {
	using obj:       Obj,
	width, height:   int,
	texture:         rl.Texture2D,
	frames:          int,
	frame_width:     int,
	start_frame:     int,
	end_frame:       int,
	frame_rects:     [dynamic]rl.Rectangle,
	ticks_per_frame: int, // 0 means no animation
	ticks:           int, // ticks since last frame change
	current_frame:   int,
	freed:           bool, // idempotent-unload guard, shared by .unload() and GC -- see vm/gc.odin's free_object
	owns_texture:    bool, // false for make_texture_object_from_texture2d -- see its own doc comment
}

make_texture_object :: proc(image: rl.Image, frames, start_frame, end_frame: int) -> ^Texture_Object {
	texture := rl.LoadTextureFromImage(image)
	w, h := int(texture.width), int(texture.height)

	o := new(Texture_Object)
	o.obj.type = .Texture
	o.width = w
	o.height = h
	o.texture = texture
	o.frames = frames
	o.frame_width = w / frames
	o.start_frame = start_frame
	o.end_frame = end_frame
	o.owns_texture = true
	for f := start_frame; f <= end_frame; f += 1 {
		x1 := f32((f - 1) * o.frame_width)
		append(&o.frame_rects, rl.Rectangle{x1, 0, f32(o.frame_width), f32(h)})
	}
	return o
}

// make_texture_object_from_texture2d wraps an already-loaded GPU texture
// this Texture_Object does *not* own (e.g. render_texture.get_texture()
// pulling out the render_texture's own live rl.Texture2D) as a
// single-frame, non-animated Texture_Object. owns_texture is left false,
// so texture_unload below never calls rl.UnloadTexture on it: a script
// that calls get_texture() every frame makes the previous frame's
// wrapper unreachable and GC-collectible, and without owns_texture,
// reaping one of these transient wrappers would unload the
// render_texture's own shared GPU texture out from under it.
make_texture_object_from_texture2d :: proc(texture: rl.Texture2D) -> ^Texture_Object {
	w, h := int(texture.width), int(texture.height)
	o := new(Texture_Object)
	o.obj.type = .Texture
	o.width = w
	o.height = h
	o.texture = texture
	o.frames = 1
	o.frame_width = w
	o.start_frame = 1
	o.end_frame = 1
	o.owns_texture = false
	append(&o.frame_rects, rl.Rectangle{0, 0, f32(w), f32(h)})
	return o
}

texture_frame_rect :: proc(t: ^Texture_Object) -> rl.Rectangle {
	return t.frame_rects[t.current_frame]
}

texture_animate :: proc(t: ^Texture_Object) {
	if t.ticks_per_frame == 0 {
		return
	}
	t.ticks += 1
	if t.ticks == t.ticks_per_frame {
		t.ticks = 0
		t.current_frame = (t.current_frame + 1) % t.frames
	}
}

// texture_unload is the single place GPU teardown for a texture
// happens -- shared by the Lox-visible unload() method and GC-triggered
// cleanup, guarded by freed so whichever runs first wins, not a double
// UnloadTexture. Same convention as vm/process.odin's Process_Object,
// core/obj_regex.odin's Regex_Pattern_Object, etc. A borrowed texture
// (owns_texture == false, see make_texture_object_from_texture2d) never
// calls rl.UnloadTexture at all -- the GPU resource belongs to whatever
// created it (a render_texture, so far), and unloading it here would
// destroy that owner's still-live texture out from under it. freed is
// still set either way, so a script calling .unload() on a borrowed
// Texture is a harmless no-op rather than an error.
texture_unload :: proc(t: ^Texture_Object) {
	if t.freed {
		return
	}
	t.freed = true
	if t.owns_texture {
		rl.UnloadTexture(t.texture)
	}
}
