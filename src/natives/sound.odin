package natives

import "../core"
import "../vm"
import "core:strings"
import rl "vendor:raylib"

// sound: audio device management plus Sound/Music construction and
// method dispatch. Unlike every other native object kind in this
// codebase, Sound/Music need no case in core/object.odin's Object_Type,
// object_to_string, vm/gc.odin's free_object/object_size/blacken_object,
// or vm/call.odin's invoke() -- everything specific to these two kinds
// lives in this one file.

Sound_Data :: struct {
	sound: rl.Sound,
	freed: bool, // idempotent-unload guard, same convention as Texture_Object/Shader_Object
}

Music_Data :: struct {
	music: rl.Music,
	freed: bool,
}

@(private = "file")
sound_vtable := core.Userdata_Vtable {
	tag    = "sound",
	free   = sound_data_free,
	invoke = sound_invoke,
}

@(private = "file")
music_vtable := core.Userdata_Vtable {
	tag    = "music",
	free   = music_data_free,
	invoke = music_invoke,
}

// sound_unload stops s before unloading it -- unloading a still-playing
// clip risks the audio mixer thread reading from a buffer this call is
// about to free out from under it. Reachable not just from a script's
// own .unload() call but from a GC sweep too (via sound_data_free, the
// vtable's free callback), which has no way to know whether s happened
// to still be playing at the moment it became unreachable.
@(private = "file")
sound_unload :: proc(s: ^Sound_Data) {
	if s.freed {
		return
	}
	s.freed = true
	rl.StopSound(s.sound)
	rl.UnloadSound(s.sound)
}

// music_unload: same reasoning as sound_unload above, for a streamed clip.
@(private = "file")
music_unload :: proc(m: ^Music_Data) {
	if m.freed {
		return
	}
	m.freed = true
	rl.StopMusicStream(m.music)
	rl.UnloadMusicStream(m.music)
}

@(private = "file")
sound_data_free :: proc(data: rawptr) {
	s := cast(^Sound_Data)data
	sound_unload(s)
	free(s)
}

@(private = "file")
music_data_free :: proc(data: rawptr) {
	m := cast(^Music_Data)data
	music_unload(m)
	free(m)
}

@(private)
register_sound :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "sound")
	vm.define_builtin(v, "sound", "init", sound_init)
	vm.define_builtin(v, "sound", "close", sound_close)
	vm.define_builtin(v, "sound", "is_ready", sound_is_ready)
	vm.define_builtin(v, "sound", "set_master_volume", sound_set_master_volume)
	vm.define_builtin(v, "sound", "get_master_volume", sound_get_master_volume)
	vm.define_builtin(v, "sound", "load", sound_load)
	vm.define_builtin(v, "sound", "load_music", sound_load_music)
}

// audio_device_ready tracks whether the audio device has been opened:
// sound.load()/sound.load_music() require one, checked here rather than
// in the invoke callbacks below since it's a natives-package-level
// constructor concern, not something the object itself needs to know. A
// package-level flag assumes a single VM per process, the same
// assumption natives/gfx.odin's window_created makes.
@(private = "file")
audio_device_ready: bool

// sound_init is idempotent -- a second call while the device is already
// open is a no-op rather than a second rl.InitAudioDevice() call. A
// script that constructs more than one SoundManager (each calling
// sound.init() itself) or otherwise calls init() more than once must
// not re-initialize the device out from under any already-loaded Sound/
// Music objects.
@(private = "file")
sound_init :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 0 {
		vm.runtime_error(v, "init() takes no arguments.")
		return core.NIL_VALUE
	}
	if audio_device_ready {
		return core.NIL_VALUE
	}
	rl.SetTraceLogLevel(.NONE)
	rl.InitAudioDevice()
	audio_device_ready = true
	return core.NIL_VALUE
}

// sound_close is idempotent for the same reason sound_init is -- a
// second call, or a call with no matching init(), is a no-op rather
// than an unbalanced rl.CloseAudioDevice() call.
@(private = "file")
sound_close :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 0 {
		vm.runtime_error(v, "close() takes no arguments.")
		return core.NIL_VALUE
	}
	if !audio_device_ready {
		return core.NIL_VALUE
	}
	rl.CloseAudioDevice()
	audio_device_ready = false
	return core.NIL_VALUE
}

@(private = "file")
sound_is_ready :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 0 {
		vm.runtime_error(v, "is_ready() takes no arguments.")
		return core.NIL_VALUE
	}
	return core.make_bool_value(bool(rl.IsAudioDeviceReady()))
}

@(private = "file")
sound_set_master_volume :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "set_master_volume() expects 1 argument (volume).")
		return core.NIL_VALUE
	}
	vol_val := v.stack[arg_stack_ptr]
	if !core.is_number(vol_val) {
		vm.runtime_error(v, "set_master_volume() argument must be a number.")
		return core.NIL_VALUE
	}
	rl.SetMasterVolume(f32(core.as_float(vol_val)))
	return core.NIL_VALUE
}

@(private = "file")
sound_get_master_volume :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 0 {
		vm.runtime_error(v, "get_master_volume() takes no arguments.")
		return core.NIL_VALUE
	}
	return core.make_float_value(f64(rl.GetMasterVolume()))
}

// sound_load loads and fully decodes a short clip. A failed/invalid load
// (bad path, unsupported format) raises a catchable Lox runtime_error
// rather than crashing the process, matching how native failures are
// surfaced throughout the natives package.
@(private = "file")
sound_load :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if !audio_device_ready {
		vm.runtime_error(v, "Cannot load sound: sound.init() has not been called.")
		return core.NIL_VALUE
	}
	if argc != 1 {
		vm.runtime_error(v, "load() expects 1 argument (filename).")
		return core.NIL_VALUE
	}
	filename_val := v.stack[arg_stack_ptr]
	if !core.is_string(filename_val) {
		vm.runtime_error(v, "load() argument must be a string.")
		return core.NIL_VALUE
	}
	cfilename := strings.clone_to_cstring(core.string_get(core.as_string(filename_val)))
	defer delete(cfilename)
	snd := rl.LoadSound(cfilename)
	if !rl.IsSoundValid(snd) {
		vm.runtime_error(v, "Failed to load sound from '%s'.", core.string_get(core.as_string(filename_val)))
		return core.NIL_VALUE
	}
	data := new(Sound_Data)
	data.sound = snd
	o := core.make_userdata_object(&sound_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

// sound_load_music loads a stream-backed clip -- see music_invoke's
// "update" case for the per-frame polling this requires.
@(private = "file")
sound_load_music :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if !audio_device_ready {
		vm.runtime_error(v, "Cannot load music: sound.init() has not been called.")
		return core.NIL_VALUE
	}
	if argc != 1 {
		vm.runtime_error(v, "load_music() expects 1 argument (filename).")
		return core.NIL_VALUE
	}
	filename_val := v.stack[arg_stack_ptr]
	if !core.is_string(filename_val) {
		vm.runtime_error(v, "load_music() argument must be a string.")
		return core.NIL_VALUE
	}
	cfilename := strings.clone_to_cstring(core.string_get(core.as_string(filename_val)))
	defer delete(cfilename)
	mus := rl.LoadMusicStream(cfilename)
	if !rl.IsMusicValid(mus) {
		vm.runtime_error(v, "Failed to load music from '%s'.", core.string_get(core.as_string(filename_val)))
		return core.NIL_VALUE
	}
	data := new(Music_Data)
	data.music = mus
	o := core.make_userdata_object(&music_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

// sound_invoke: method dispatch for Sound_Data, called through
// sound_vtable.invoke by vm/call.odin's invoke() -- vm never knows this
// proc, or Sound_Data, exist; it only ever sees the vtable pointer
// stored on the Userdata_Object.
@(private = "file")
sound_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	s := cast(^Sound_Data)data
	result: core.Value
	switch name {
	case "play":
		if arg_count != 0 {
			vm.runtime_error(v, "play() takes no arguments.")
			return false
		}
		rl.PlaySound(s.sound)
		result = core.NIL_VALUE
	case "stop":
		if arg_count != 0 {
			vm.runtime_error(v, "stop() takes no arguments.")
			return false
		}
		rl.StopSound(s.sound)
		result = core.NIL_VALUE
	case "pause":
		if arg_count != 0 {
			vm.runtime_error(v, "pause() takes no arguments.")
			return false
		}
		rl.PauseSound(s.sound)
		result = core.NIL_VALUE
	case "resume":
		if arg_count != 0 {
			vm.runtime_error(v, "resume() takes no arguments.")
			return false
		}
		rl.ResumeSound(s.sound)
		result = core.NIL_VALUE
	case "is_playing":
		if arg_count != 0 {
			vm.runtime_error(v, "is_playing() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.IsSoundPlaying(s.sound)))
	case "set_volume":
		vol, ok := sound_read_f32_arg(v, arg_count, "set_volume")
		if !ok {
			return false
		}
		rl.SetSoundVolume(s.sound, vol)
		result = core.NIL_VALUE
	case "set_pitch":
		vol, ok := sound_read_f32_arg(v, arg_count, "set_pitch")
		if !ok {
			return false
		}
		rl.SetSoundPitch(s.sound, vol)
		result = core.NIL_VALUE
	case "set_pan":
		vol, ok := sound_read_f32_arg(v, arg_count, "set_pan")
		if !ok {
			return false
		}
		rl.SetSoundPan(s.sound, vol)
		result = core.NIL_VALUE
	case "unload":
		if arg_count != 0 {
			vm.runtime_error(v, "unload() takes no arguments.")
			return false
		}
		sound_unload(s)
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Undefined Sound method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}

// music_invoke: method dispatch for Music_Data, same shape as
// sound_invoke above.
@(private = "file")
music_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	m := cast(^Music_Data)data
	result: core.Value
	switch name {
	case "play":
		if arg_count != 0 {
			vm.runtime_error(v, "play() takes no arguments.")
			return false
		}
		rl.PlayMusicStream(m.music)
		result = core.NIL_VALUE
	case "stop":
		if arg_count != 0 {
			vm.runtime_error(v, "stop() takes no arguments.")
			return false
		}
		rl.StopMusicStream(m.music)
		result = core.NIL_VALUE
	case "pause":
		if arg_count != 0 {
			vm.runtime_error(v, "pause() takes no arguments.")
			return false
		}
		rl.PauseMusicStream(m.music)
		result = core.NIL_VALUE
	case "resume":
		if arg_count != 0 {
			vm.runtime_error(v, "resume() takes no arguments.")
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
			vm.runtime_error(v, "update() takes no arguments.")
			return false
		}
		rl.UpdateMusicStream(m.music)
		result = core.NIL_VALUE
	case "is_playing":
		if arg_count != 0 {
			vm.runtime_error(v, "is_playing() takes no arguments.")
			return false
		}
		result = core.make_bool_value(bool(rl.IsMusicStreamPlaying(m.music)))
	case "set_volume":
		vol, ok := sound_read_f32_arg(v, arg_count, "set_volume")
		if !ok {
			return false
		}
		rl.SetMusicVolume(m.music, vol)
		result = core.NIL_VALUE
	case "set_pitch":
		vol, ok := sound_read_f32_arg(v, arg_count, "set_pitch")
		if !ok {
			return false
		}
		rl.SetMusicPitch(m.music, vol)
		result = core.NIL_VALUE
	case "set_pan":
		vol, ok := sound_read_f32_arg(v, arg_count, "set_pan")
		if !ok {
			return false
		}
		rl.SetMusicPan(m.music, vol)
		result = core.NIL_VALUE
	case "seek":
		vol, ok := sound_read_f32_arg(v, arg_count, "seek")
		if !ok {
			return false
		}
		rl.SeekMusicStream(m.music, vol)
		result = core.NIL_VALUE
	case "time_played":
		if arg_count != 0 {
			vm.runtime_error(v, "time_played() takes no arguments.")
			return false
		}
		result = core.make_float_value(f64(rl.GetMusicTimePlayed(m.music)))
	case "time_length":
		if arg_count != 0 {
			vm.runtime_error(v, "time_length() takes no arguments.")
			return false
		}
		result = core.make_float_value(f64(rl.GetMusicTimeLength(m.music)))
	case "set_looping":
		if arg_count != 1 {
			vm.runtime_error(v, "set_looping() expects 1 argument (bool).")
			return false
		}
		b_val := vm.peek(v, 0)
		if !core.is_bool(b_val) {
			vm.runtime_error(v, "set_looping() argument must be a bool.")
			return false
		}
		m.music.looping = core.as_bool(b_val)
		result = core.NIL_VALUE
	case "is_looping":
		if arg_count != 0 {
			vm.runtime_error(v, "is_looping() takes no arguments.")
			return false
		}
		result = core.make_bool_value(m.music.looping)
	case "unload":
		if arg_count != 0 {
			vm.runtime_error(v, "unload() takes no arguments.")
			return false
		}
		music_unload(m)
		result = core.NIL_VALUE
	case:
		vm.runtime_error(v, "Undefined Music method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}

// sound_read_f32_arg reads the single numeric argument every volume/
// pitch/pan/seek-shaped method above takes, reporting a runtime_error
// under method_name on arity/type mismatch.
@(private = "file")
sound_read_f32_arg :: proc(v: ^vm.VM, arg_count: int, method_name: string) -> (f32, bool) {
	if arg_count != 1 {
		vm.runtime_error(v, "%s() expects 1 argument.", method_name)
		return 0, false
	}
	val := vm.peek(v, 0)
	if !core.is_number(val) {
		vm.runtime_error(v, "%s() argument must be a number.", method_name)
		return 0, false
	}
	return f32(core.as_float(val)), true
}
