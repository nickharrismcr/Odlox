package natives

import "../core"
import "../vm"
import "core:strings"
import rl "vendor:raylib"

// sound: audio device management plus Sound/Music construction. Method
// dispatch on the constructed objects lives in vm/sound.odin, matching
// the split every other native object type uses.

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
// in vm/sound.odin since it's a natives-package-level constructor
// concern, not something the object itself needs to know. A
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
	o := core.make_sound_object(snd)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

// sound_load_music loads a stream-backed clip -- see vm/sound.odin's
// Music.update() for the per-frame polling this requires.
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
	o := core.make_music_object(mus)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}
