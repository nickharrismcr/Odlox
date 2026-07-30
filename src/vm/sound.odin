package vm

import "../core"
import rl "vendor:raylib"

// sound.odin: method dispatch for Sound_Object and Music_Object.
// Construction lives in natives/sound.odin, matching the split every
// other native object type uses.

invoke_builtin_sound :: proc(vm: ^VM, s: ^core.Sound_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "play":
		if arg_count != 0 {
			runtime_error(vm, "play() takes no arguments.")
			return false
		}
		rl.PlaySound(s.sound)
		result = core.NIL_VALUE
	case "stop":
		if arg_count != 0 {
			runtime_error(vm, "stop() takes no arguments.")
			return false
		}
		rl.StopSound(s.sound)
		result = core.NIL_VALUE
	case "pause":
		if arg_count != 0 {
			runtime_error(vm, "pause() takes no arguments.")
			return false
		}
		rl.PauseSound(s.sound)
		result = core.NIL_VALUE
	case "resume":
		if arg_count != 0 {
			runtime_error(vm, "resume() takes no arguments.")
			return false
		}
		rl.ResumeSound(s.sound)
		result = core.NIL_VALUE
	case "is_playing":
		if arg_count != 0 {
			runtime_error(vm, "is_playing() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.IsSoundPlaying(s.sound)))
	case "set_volume":
		v, ok := sound_read_f32_arg(vm, arg_count, "set_volume")
		if !ok {
			return false
		}
		rl.SetSoundVolume(s.sound, v)
		result = core.NIL_VALUE
	case "set_pitch":
		v, ok := sound_read_f32_arg(vm, arg_count, "set_pitch")
		if !ok {
			return false
		}
		rl.SetSoundPitch(s.sound, v)
		result = core.NIL_VALUE
	case "set_pan":
		v, ok := sound_read_f32_arg(vm, arg_count, "set_pan")
		if !ok {
			return false
		}
		rl.SetSoundPan(s.sound, v)
		result = core.NIL_VALUE
	case "unload":
		if arg_count != 0 {
			runtime_error(vm, "unload() takes no arguments.")
			return false
		}
		core.sound_unload(s)
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined Sound method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}

invoke_builtin_music :: proc(vm: ^VM, m: ^core.Music_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "play":
		if arg_count != 0 {
			runtime_error(vm, "play() takes no arguments.")
			return false
		}
		rl.PlayMusicStream(m.music)
		result = core.NIL_VALUE
	case "stop":
		if arg_count != 0 {
			runtime_error(vm, "stop() takes no arguments.")
			return false
		}
		rl.StopMusicStream(m.music)
		result = core.NIL_VALUE
	case "pause":
		if arg_count != 0 {
			runtime_error(vm, "pause() takes no arguments.")
			return false
		}
		rl.PauseMusicStream(m.music)
		result = core.NIL_VALUE
	case "resume":
		if arg_count != 0 {
			runtime_error(vm, "resume() takes no arguments.")
			return false
		}
		rl.ResumeMusicStream(m.music)
		result = core.NIL_VALUE
	// update polls the stream's decode buffer -- raylib only advances a
	// Music's playback position while this is called, so a script's own
	// per-frame loop is responsible for calling it every frame a Music is
	// playing (see modules/sound_mgr.lox's own update()).
	case "update":
		if arg_count != 0 {
			runtime_error(vm, "update() takes no arguments.")
			return false
		}
		rl.UpdateMusicStream(m.music)
		result = core.NIL_VALUE
	case "is_playing":
		if arg_count != 0 {
			runtime_error(vm, "is_playing() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.IsMusicStreamPlaying(m.music)))
	case "set_volume":
		v, ok := sound_read_f32_arg(vm, arg_count, "set_volume")
		if !ok {
			return false
		}
		rl.SetMusicVolume(m.music, v)
		result = core.NIL_VALUE
	case "set_pitch":
		v, ok := sound_read_f32_arg(vm, arg_count, "set_pitch")
		if !ok {
			return false
		}
		rl.SetMusicPitch(m.music, v)
		result = core.NIL_VALUE
	case "set_pan":
		v, ok := sound_read_f32_arg(vm, arg_count, "set_pan")
		if !ok {
			return false
		}
		rl.SetMusicPan(m.music, v)
		result = core.NIL_VALUE
	case "seek":
		v, ok := sound_read_f32_arg(vm, arg_count, "seek")
		if !ok {
			return false
		}
		rl.SeekMusicStream(m.music, v)
		result = core.NIL_VALUE
	case "time_played":
		if arg_count != 0 {
			runtime_error(vm, "time_played() takes no arguments.")
			return false
		}
		result = core.make_float_value(f64(rl.GetMusicTimePlayed(m.music)))
	case "time_length":
		if arg_count != 0 {
			runtime_error(vm, "time_length() takes no arguments.")
			return false
		}
		result = core.make_float_value(f64(rl.GetMusicTimeLength(m.music)))
	case "set_looping":
		if arg_count != 1 {
			runtime_error(vm, "set_looping() expects 1 argument (bool).")
			return false
		}
		b_val := peek(vm, 0)
		if !core.is_bool(b_val) {
			runtime_error(vm, "set_looping() argument must be a bool.")
			return false
		}
		m.music.looping = core.as_bool(b_val)
		result = core.NIL_VALUE
	case "is_looping":
		if arg_count != 0 {
			runtime_error(vm, "is_looping() takes no arguments.")
			return false
		}
		result = core.make_bool_value(m.music.looping)
	case "unload":
		if arg_count != 0 {
			runtime_error(vm, "unload() takes no arguments.")
			return false
		}
		core.music_unload(m)
		result = core.NIL_VALUE
	case:
		runtime_error(vm, "Undefined Music method '%s'.", name)
		return false
	}
	collapse_call(vm, arg_count, result)
	return true
}

// sound_read_f32_arg reads the single numeric argument every volume/
// pitch/pan/seek-shaped method above takes, reporting a runtime_error
// under method_name on arity/type mismatch.
@(private = "file")
sound_read_f32_arg :: proc(vm: ^VM, arg_count: int, method_name: string) -> (f32, bool) {
	if arg_count != 1 {
		runtime_error(vm, "%s() expects 1 argument.", method_name)
		return 0, false
	}
	v := peek(vm, 0)
	if !core.is_number(v) {
		runtime_error(vm, "%s() argument must be a number.", method_name)
		return 0, false
	}
	return f32(core.as_float(v)), true
}
