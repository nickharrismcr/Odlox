# Sound (`sound` native module + a reusable Lox sound-manager library)

Design record for adding audio support to odlox. There's no existing precedent inside this codebase to
extend — grounded instead in a direct audit of `d:\odin\defender` (a separate, working Odin/raylib game
that already solves this problem), odlox's own established native-object pattern, and Odin's `vendor:raylib`
audio bindings — not assumed.

**Status**: shipped (`ROADMAP.md`'s Phase 10 section). Two things surfaced during implementation that this
design didn't anticipate — a real compile error in the manager library's first draft (`for x in y` isn't
valid Lox syntax for collection iteration; it's `foreach (x in y)`) and `sound.init()` needing the same
`rl.SetTraceLogLevel(.NONE)` call `win.init()` already makes, or raylib's own trace logging pollutes stdout.
Both fixed; see `ROADMAP.md`'s Phase 10 section for the full account.

## Comment conventions for the implementation

This codebase's source comments describe its own current architecture and behavior as plain fact, never as
a comparison to another codebase (glox, `defender`, or otherwise) — see `ROADMAP.md`'s Phase 9 section. A
genuine external-API constraint (e.g. "raylib requires X to be called every frame") is fine to state as
fact, since it's true regardless of what any other project does; a framing like "unlike `defender`, this
does X" or "ported from `defender`'s Y" is not. This design doc's own research notes below reference
`defender` freely (it's the design source), but that framing must not carry into the actual source comments
this plan leads to.

## Why this, why now

odlox has raylib-backed graphics (`gfx`) and a hand-rolled physics engine (`physics`), but no audio at all.
`d:\odin\defender` solves the same problem twice, in two clearly separable layers: a thin wrapper around
raylib's own sound/music API, and a "manager" layer of game-level policy on top of it (exclusivity groups so
a limited number of overlapping effects don't step on each other, event-driven triggering, a mute switch,
per-frame music-stream polling). The direction here follows that same split exactly: the thin raylib wrapper
becomes a **native `sound` object/module**, following the existing `gfx`/`physics` native-module pattern;
the manager-level policy becomes **ordinary Lox code** — a reusable library module, not native — so it can
be read, modified, and reused by any script without touching Odin at all, the same way
`particle_sys.lox`/`sprite.lox` already build higher-level behavior on top of thinner natives.

## Current state (verified directly against source)

**`d:\odin\defender\src\sound.odin`** (the concrete reference for what "manager" means here): a
`Sound_Mgr{sounds: [Sound_Id]rl.Sound, background: rl.Music, thruster: rl.Music}`, all loaded once from a
fixed compile-time path table at startup. `sound_play` implements **mono-group exclusivity**: a
`SOUND_GROUP` table maps some sound IDs to a nonzero group int; playing a grouped sound first stops every
*other* currently-playing sound in that same group (emulating a limited hardware voice count — e.g. firing
the laser cuts off a currently-playing death sound). Ungrouped sounds (group 0) overlap freely.
`sound_play_if_not` re-triggers a one-shot clip only if it isn't already playing (used for "buzz while
visible" NPC loops). `update_music`, called once per frame, polls `rl.UpdateMusicStream` for both music
streams and edge-triggers a thruster loop on/off a player state flag. A compile-time `MUTE` bool is checked
at the top of every exported proc as a full kill switch. All assets are `.wav`; no other format is exercised.
None of this — the grouping, the event mapping, the per-frame update orchestration — touches anything raylib
doesn't already expose as a plain function call; it's pure policy on top of primitives.

**odlox's existing native-object pattern** (confirmed via `Window`/`Texture`/`Shader`), a three-layer split
to replicate exactly:
1. `core/obj_<name>.odin` — the struct (`using obj: Obj`, registered as an `Object_Type` tag in
   `core/object.odin`) plus a `make_<name>_object` constructor.
2. `vm/<name>.odin` — `invoke_builtin_<name>(vm, obj, method_name, arg_count) -> bool`, a big `switch
   method_name` wired into `vm/call.odin`'s central invoke dispatch (`case .<Tag>: return
   invoke_builtin_<name>(...)`).
3. `natives/<module>.odin` — a `Builtin_Fn`-shaped constructor (`argc, arg_stack_ptr, vm_ptr: rawptr`,
   `vm.native_vm(vm_ptr)`, argument type-checking via `core.is_*`, `vm.runtime_error(...)` on bad input,
   never a crash) registered via `vm.define_builtin(v, "<module>", "<name>", ctor)` inside a
   `register_<module>` called from `natives/natives.odin`'s `define_natives`.

**Idempotent GPU/OS-resource teardown** (confirmed via `Texture_Object`/`Shader_Object`): one `freed: bool`
field, one shared unload proc (`texture_unload`, `shader_unload`) checked-and-set at its top before doing
the real `rl.Unload*` call, invoked from *both* a script-level `.unload()` method (`vm/gfx_texture.odin`)
**and** `vm/gc.odin`'s `free_object` sweep case — whichever runs first wins, never a double-free. `Window`
is the *only* existing exception (no per-object GPU resource, a process-global GL context instead, so no GC
case at all) — `Sound`/`Music` are per-instance resources like `Texture`/`Shader`, so they follow the normal
(non-Window) pattern: a real `free_object`/`object_size` case each.

**`vendor:raylib`'s audio surface** (confirmed by reading the actual binding): `InitAudioDevice`/
`CloseAudioDevice`/`IsAudioDeviceReady`/`SetMasterVolume`/`GetMasterVolume` (device-global, no handle);
`LoadSound`/`UnloadSound`/`PlaySound`/`StopSound`/`PauseSound`/`ResumeSound`/`IsSoundPlaying`/
`SetSoundVolume`/`SetSoundPitch`/`SetSoundPan` (`Sound` — fully decoded, short clips); `LoadMusicStream`/
`UnloadMusicStream`/`PlayMusicStream`/`StopMusicStream`/`PauseMusicStream`/`ResumeMusicStream`/
`IsMusicStreamPlaying`/`UpdateMusicStream`/`SeekMusicStream`/`SetMusicVolume`/`SetMusicPitch`/`SetMusicPan`/
`GetMusicTimeLength`/`GetMusicTimePlayed` (`Music` — streamed, must have `UpdateMusicStream` polled every
frame or playback stalls — a raylib contract, not a design choice). No separate library/build flag is
needed: audio ships through the exact same `foreign import` block as graphics (`bin/build.sh` has no
`--target`/audio-specific flag today and needs none).

**Existing "is the device ready" guard precedent**: `natives/gfx.odin`'s `window_created: bool`
(package-level, single-VM-per-process assumption already documented there) gates `gfx.texture()` on a
window existing. A new `audio_device_ready: bool` in the sound natives file mirrors this exactly, gating
`sound.load()`/`sound.load_music()`.

## Design

### Native layer: a new `sound` module (parallel to `gfx`/`physics`, not nested under `gfx`)

A script that wants audio but no window shouldn't need to import graphics — matches the existing
one-module-per-concern convention (`math`, `physics`, `re`, ...).

**`core/obj_sound.odin`** (new) — two small structs, same file since both are tiny and tightly related:
```odin
Sound_Object :: struct {
	using obj: Obj,
	sound:     rl.Sound,
	freed:     bool, // idempotent-unload guard, shared by .unload() and GC -- see vm/gc.odin's free_object
}
Music_Object :: struct {
	using obj: Obj,
	music:     rl.Music,
	freed:     bool,
}
make_sound_object :: proc(s: rl.Sound) -> ^Sound_Object { ... o.obj.type = .Sound ... }
make_music_object :: proc(m: rl.Music) -> ^Music_Object { ... o.obj.type = .Music ... }
sound_unload :: proc(s: ^Sound_Object) { if s.freed { return }; s.freed = true; rl.UnloadSound(s.sound) }
music_unload :: proc(m: ^Music_Object) { if m.freed { return }; m.freed = true; rl.UnloadMusicStream(m.music) }
```
Add `Sound`/`Music` to `Object_Type` (`core/object.odin`), `object_to_string` cases (`"<sound>"`/`"<music>"`),
`as_sound`/`as_music` accessors (`core/value.odin`).

**`vm/sound.odin`** (new) — `invoke_builtin_sound`/`invoke_builtin_music`, wired into `vm/call.odin`'s
dispatch (`case .Sound:` / `case .Music:`), same shape as `invoke_builtin_texture`:
- Sound methods: `.play()`, `.stop()`, `.pause()`, `.resume()`, `.is_playing()`, `.set_volume(v)`,
  `.set_pitch(v)`, `.set_pan(v)`, `.unload()`.
- Music methods: same playback/volume/pitch/pan set, plus `.update()` (a thin wrapper over
  `UpdateMusicStream` — raylib requires this to be polled every frame for streamed playback to advance at
  all, so **the script's own per-frame loop must call it**), `.seek(pos)`, `.time_played()`,
  `.time_length()`, `.set_looping(b)`/`.is_looping()`, `.unload()`.

**`vm/gc.odin`** — `object_size` cases (`size_of(core.Sound_Object)`/`size_of(core.Music_Object)`, no extra
backing array to account for) and `free_object` cases calling `sound_unload`/`music_unload` (idempotent,
same as Texture/Shader).

**`natives/sound.odin`** (new) — `register_sound(v: ^vm.VM)`:
```odin
vm.make_builtin_module(v, "sound")
vm.define_builtin(v, "sound", "init", sound_init)                   // rl.InitAudioDevice, sets audio_device_ready
vm.define_builtin(v, "sound", "close", sound_close)                 // rl.CloseAudioDevice
vm.define_builtin(v, "sound", "is_ready", sound_is_ready)           // rl.IsAudioDeviceReady
vm.define_builtin(v, "sound", "set_master_volume", sound_set_master_volume)
vm.define_builtin(v, "sound", "get_master_volume", sound_get_master_volume)
vm.define_builtin(v, "sound", "load", sound_load)                   // -> Sound_Object; requires audio_device_ready
vm.define_builtin(v, "sound", "load_music", sound_load_music)       // -> Music_Object; requires audio_device_ready
```
`sound_load`/`sound_load_music` call `rl.LoadSound`/`rl.LoadMusicStream` synchronously (unlike `Window`,
there's no "construct now, initialize later" split needed — loading a clip has no separate
resource-acquisition step to defer), then check `rl.IsSoundValid`/`rl.IsMusicValid` and raise a catchable
`vm.runtime_error` on a bad path/format rather than returning a broken handle. `audio_device_ready` is a
package-level `@(private = "file") bool`, same single-VM-per-process assumption `window_created` already
documents.

### Lox layer: a reusable sound-manager library, `modules/sound_mgr.lox`

Data-driven (no hardcoded sound-ID enum), so any script can reuse it:
```lox
import sound

class SoundManager {
	init() {
		this.sounds = {}   // name -> Sound object
		this.groups = {}   // name -> group id (0/absent = no exclusivity)
		this.music = {}    // key -> Music object
		this.muted = false
	}

	load(name, path, group=0) {
		this.sounds[name] = sound.load(path)
		if group != 0 { this.groups[name] = group }
	}

	load_music(key, path) {
		this.music[key] = sound.load_music(path)
	}

	play(name) {
		if this.muted { return }
		group = this.groups.get(name, 0)
		if group != 0 {
			for other in this.groups.keys() {
				if other != name and this.groups[other] == group {
					this.sounds[other].stop()
				}
			}
		}
		this.sounds[name].stop()
		this.sounds[name].play()
	}

	play_if_not(name) {
		if !this.muted and !this.sounds[name].is_playing() { this.sounds[name].play() }
	}

	stop(name) { this.sounds[name].stop() }

	play_music(key) { if !this.muted { this.music[key].play() } }
	stop_music(key) { this.music[key].stop() }

	// Call once per frame from the game's own loop -- streamed playback
	// only advances while this is polled.
	update() {
		for key in this.music.keys() { this.music[key].update() }
	}

	set_muted(m) {
		this.muted = m
		if m {
			for name in this.sounds.keys() { this.sounds[name].stop() }
			for key in this.music.keys() { this.music[key].stop() }
		}
	}
}
```
This covers the same policy surface described in "Current state" above (grouping/exclusivity,
play-if-not-playing, a mute kill-switch, per-frame music polling) as plain Lox, generalized from a fixed
enum/table to runtime dicts a script populates itself. A further layer mapping a game-specific event queue
to sound names is intentionally *not* part of this reusable library — that's application logic specific to
one game, same reason `particle_sys.lox` doesn't try to bundle a specific game's spawn logic.

### Scenario walkthrough

| Scenario | Native layer | Lox layer |
|---|---|---|
| One-shot SFX, no exclusivity | `sound.load(path)` once, `.play()` per trigger (raylib allows overlapping `PlaySound` calls on one handle) | `mgr.load("laser", "laser.wav")`, `mgr.play("laser")` |
| Two SFX that should never overlap (mono group) | N/A — pure Lox policy | `mgr.load("laser", ..., group=1)`, `mgr.load("explosion", ..., group=1)` |
| Looping ambience while a condition holds | `.is_playing()` check + `.play()` | `mgr.play_if_not("engine_hum")` called every frame the engine runs |
| Background music | `sound.load_music(path)`, `.play()` once, `.update()` every frame | `mgr.play_music("bg")`, `mgr.update()` from the game loop |
| Mute toggle | N/A | `mgr.set_muted(true)` stops everything currently playing and silences future `.play()` calls |
| No window, audio only | `sound.init()` has no dependency on `gfx.window()` | n/a |

## Implementation order

1. `core/obj_sound.odin` + `Object_Type`/`object_to_string`/`value.odin` accessor wiring — no VM/natives yet,
   just the data shape (mirrors how the pool-allocator/bytecode-cache designs front-loaded their own
   lowest-risk, no-integration piece first).
2. `vm/sound.odin`'s `invoke_builtin_sound`/`invoke_builtin_music` + `vm/call.odin`'s two new dispatch cases
   + `vm/gc.odin`'s `object_size`/`free_object` cases.
3. `natives/sound.odin`'s `register_sound` + the `audio_device_ready` guard, wired into
   `natives/natives.odin`'s `define_natives`.
4. Smoke-test the native layer directly from a `.lox` script (no manager yet) — load, play, check
   `is_playing()`, unload, close.
5. `modules/sound_mgr.lox` — the reusable manager library, tested against the same smoke script extended to
   exercise grouping/mute/music update.

## Verification

Audio playback can't be asserted on from here any more than graphics could (the same "screen-based testing,
standing limitation" this project already accepted for `gfx`) — the achievable bar is: correct API call
sequencing, no crash, no hang, no orphaned process, under a bounded timeout, plus whatever *can* be asserted
structurally (`is_playing()`/`is_ready()` booleans, volume/pitch getters if exposed, `time_length()` against
a known test clip's real duration).

- A tiny WAV fixture needs to be committed for the test suite (nothing suitable exists in the repo today) —
  a short synthetic tone/silence clip, small enough to commit permanently, under
  `tests/new_tests/lox/assets/` or similar.
- A pytest-level smoke test (`tests/new_tests/lox/sound_smoke.lox` + driver), run under a bounded timeout,
  covering: `sound.init()` → `sound.load()` → `.play()` → `.is_playing()` → `.stop()` → `.unload()` →
  `sound.close()`, and the same shape for `sound.load_music()`/`.update()`.
- A `SoundManager` smoke test exercising grouping (two grouped sounds, assert only one reports
  `is_playing()` after both are triggered) and the mute switch (assert `is_playing()` is false after
  `set_muted(true)`).
- Both build modes (`bin/build.sh` / `--release`) compiling clean; full `pytest` suite held at its current
  baseline plus the new tests, cold and warm (bytecode-cache interaction: a module using this library still
  needs to survive a cache round trip, same as any other module — no special-casing expected, but worth
  confirming once implemented).

### Critical files
- New: `src/core/obj_sound.odin`, `src/vm/sound.odin`, `src/natives/sound.odin`, `modules/sound_mgr.lox`
- Modified: `src/core/object.odin` (`Object_Type` tags), `src/core/value.odin` (accessors), `src/vm/call.odin`
  (dispatch cases), `src/vm/gc.odin` (`object_size`/`free_object` cases), `src/natives/natives.odin`
  (`register_sound` wiring)
