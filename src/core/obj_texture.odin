package core

import rl "vendor:raylib"

// Texture_Object wraps a GPU-loaded raylib texture, optionally sliced
// into `frames` equal-width horizontal animation frames (frame N
// occupies x in [(N-1)*frame_width, N*frame_width)). Ported from
// glox's obj_builtin_texture.go.
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
	for f := start_frame; f <= end_frame; f += 1 {
		x1 := f32((f - 1) * o.frame_width)
		append(&o.frame_rects, rl.Rectangle{x1, 0, f32(o.frame_width), f32(h)})
	}
	return o
}

// make_texture_object_from_texture2d wraps an already-loaded GPU
// texture (e.g. one pulled from a RenderTexture) as a single-frame,
// non-animated Texture_Object -- not used by anything in this pass
// (RenderTexture.get_texture() isn't implemented yet), but kept as the
// exact constructor shape glox's own MakeTextureObjectFromTexture2D
// uses, for when that lands.
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
// core/obj_regex.odin's Regex_Pattern_Object, etc.
texture_unload :: proc(t: ^Texture_Object) {
	if t.freed {
		return
	}
	t.freed = true
	rl.UnloadTexture(t.texture)
}
