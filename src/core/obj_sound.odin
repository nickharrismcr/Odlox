package core

import rl "vendor:raylib"

// Sound_Object wraps a fully-decoded raylib clip (rl.Sound) -- short
// effects played via .play(), which may overlap with themselves and any
// other Sound.
Sound_Object :: struct {
	using obj: Obj,
	sound:     rl.Sound,
	freed:     bool, // idempotent-unload guard, same convention as Texture_Object/Shader_Object
}

// Music_Object wraps a streamed raylib clip (rl.Music) -- longer audio
// (background music, ambient loops) decoded incrementally rather than
// held fully in memory. Playback only advances while .update() is
// polled; see vm/sound.odin's own doc comment.
Music_Object :: struct {
	using obj: Obj,
	music:     rl.Music,
	freed:     bool,
}

make_sound_object :: proc(s: rl.Sound) -> ^Sound_Object {
	o := new(Sound_Object)
	o.obj.type = .Sound
	o.sound = s
	return o
}

make_music_object :: proc(m: rl.Music) -> ^Music_Object {
	o := new(Music_Object)
	o.obj.type = .Music
	o.music = m
	return o
}

sound_unload :: proc(s: ^Sound_Object) {
	if s.freed {
		return
	}
	s.freed = true
	rl.UnloadSound(s.sound)
}

music_unload :: proc(m: ^Music_Object) {
	if m.freed {
		return
	}
	m.freed = true
	rl.UnloadMusicStream(m.music)
}
