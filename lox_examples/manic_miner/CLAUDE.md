# CLAUDE.md — lox_examples/manic_miner

Guidance specific to this subdirectory. The root `CLAUDE.md` (doc/comment style, `.lox` linting,
trailing-comma gotcha, Odin test runner, per-frame allocation discipline) still applies everywhere
in this tree; this file adds context local to the Manic Miner reimplementation.

## What this is

A Lox reimplementation of the ZX Spectrum game Manic Miner: a 256x192 1-bit pixel bitmap plus a
32x24 grid of 8x8-cell ink/paper colour attributes (`display.lox`'s `Display` class), driving
cavern/tile rendering, item/conveyor/portal/guardian animation, and Willy's movement, collision,
and death sequence.

Run it with:

```
bin/odlox.exe lox_examples/manic_miner/main.lox [cavern_index]
```

`cavern_index` defaults to 0 (`main.lox`). Controls: LEFT/RIGHT to walk, UP or SPACE to jump, ESC
to quit. `main.lox` runs at a fixed `TARGET_FPS = 15` — Manic Miner's own original tick rate, not
this engine's usual 60fps target (see `game_sprite.lox` for the movement/animation code this rate
drives). Starts on the title screen (`intro.Intro`) — press ENTER to begin play.

## File map

**Runtime game code**, in dependency order:
- `main.lox` — window/presentation loop only. Owns the one `game_sound.Sound` (there's a single
  audio device for the whole process), passing it into both an `intro.Intro` (run to completion
  first) and the `game.Game` that follows. Owns nothing else but the `win`/`Display` frame lifecycle
  and HUD text; all session state lives in `game.Game` (and, before that, `intro.Intro`).
- `intro.lox` — `Intro`: the title screen. Draws the cached `start_screen.json`/
  `start_screen_sprites.json` (produced by `extract_start_screen.lox`) into its own `Display` once
  at `__init__`, starts the shared `Sound`'s looping intro tune, then `tick(win)` polls it
  (`Sound.update()`) and watches for ENTER (`is_done()`, which also stops the tune) — same
  `__init__`/`tick(win)` shape as `game.Game`, so `main.lox` drives either the same way.
- `game.lox` — `Game`: one play session (cavern, Willy, controller, sprite assets, Display, the
  shared `Sound`). `running`/`die`/`game_over` state machine; `tick()` polls `Sound.update()` every
  frame, `state_running()` advances the tune one tick, and `enter_die`/`enter_portal`/
  `enter_game_over` each fire their own one-shot cue.
- `cavern.lox` — `Cavern`: one level's layout/tiles/items/conveyors/portals/guardians, loaded
  from the `caverns/` data below.
- `game_sprite.lox` — `Sprite`: animated/movable sprite, frame cycling, `Display.blit_sprite`
  based draw/erase. Base class for guardians (via `cavern.lox`) and for Willy.
- `willy.lox` — Willy: subclasses `game_sprite.Sprite`; movement/jump/collision against a
  `Cavern`; its own `state_*`/`enter_*` state machine (same convention as `game.lox`).
- `willy_controller.lox` — `Controller`: polls input once per frame into `left`/`right`/`jump`
  flags (same convention as `defender/player/controller.lox`).
- `assets.lox` — `SpriteAssets`: loads sprite graphics from JSON (`"pixel"` ASCII-row or `"byte"`
  packed-MSB ROM-shaped data) into `float_array`s keyed by name.
- `display.lox` — `Display`: the bitmap+attribute compositor. See "GPU-composited display" below.
- `font.lox` — `draw_text(disp, font, text, x, y, ink, paper)`: draws text in the ZX Spectrum ROM's
  built-in 8x8 font via `Display.blit_sprite`, one glyph every 8px. Stateless -- caller owns the
  `SpriteAssets` (loaded from `font_sprites.json`, see "Data" below). Not yet wired into
  `main.lox`'s HUD, which still uses `win.text()`'s own font.
- `game_sound.lox` — `Sound`: wraps `modules/sound_mgr.SoundManager` with one named method per cue
  (`play_next_tune_note`, `play_willy_dying`, `play_level_end_swoop`, `play_game_over_swoop`,
  `play_intro_tune`/`stop_intro_tune`). Named `game_sound.lox`, not `sound.lox`, because `sound` is
  itself the native module (see `lox_examples/defender/game/game_sound.lox`'s identical naming for
  the same reason). The background tune is a sequence of short one-shot note samples rather than a
  synthesized waveform -- real beeper hardware just toggles a bit, so there's nothing to
  synthesize; sampling the tune's own fixed notes stands in for it instead. `TUNE_TABLE` is the
  disassembly's actual 64-value tune data (address 34188, its play routine at 34574); each entry
  plays across 2 `play_next_tune_note()` calls before advancing, matching the real routine's own
  timing. Its raw values are timer periods, not pitches -- a *higher* value is a *lower* note --
  so `TUNE_NOTE_VALUES` orders every distinct value from lowest note (highest period) to highest
  note (lowest period), and sample `tune_0` is always the lowest note regardless of table order.
  Wired into `game.lox`/`intro.lox` (see above) and sourced under `assets/`: `tune_0.wav`..
  `tune_6.wav`, `die.wav`, `air.wav` (level-end swoop), `game-over.wav` (game-over swoop), and
  `tune.wav` (intro tune) -- `SOUND_PATHS`/the `load_music` call in `Sound.__init__` are the map
  from cue name to actual filename, which don't all match the cue name (`air.wav`/`game-over.wav`
  are reused/renamed clips, not new files matching their method names). `main.lox`'s `MUTE_SOUND`
  is `false` now that these exist; `in-game-tune.wav`/`jumping.wav` are sourced but not wired to
  any cue yet.

**Shared Spectrum-format decoding** (no game-state dependencies):
- `spectrum_attr.lox` — decodes a raw Spectrum attribute byte into `{ink, paper, bright}`;
  `colour_to_rgba()` converts an index+bright to packed RGBA. Deliberately kept local to this
  directory rather than folded into the shared `modules/colour.lox`.
- `spectrum_screen.lox` — `attr_addr_to_xy()`/`pixel_addr_to_xy()`: real Spectrum screen/attribute
  memory addressing (including the bit-interleaved bitmap layout) to pixel coordinates.

**Offline tools** (not run as part of the game):
- `sna.lox` — loads a 48K `.sna` snapshot (27-byte header + 49152-byte RAM image).
- `extract_cavern.lox` — `odlox.exe extract_cavern.lox <path.sna> <index|all> <output_dir>`.
  Extracts one or all 20 caverns (1024-byte records from address 45056) into a
  `cavern_N.json`/`cavern_N_sprites.json` pair. This is the producer side of the data pipeline
  `caverns/` and `game.lox`/`cavern.lox`/`assets.lox` consume.
- `dump_sprites.lox` — `odlox.exe dump_sprites.lox <path/to/sprites.json>`. Loads a sprite JSON via
  `assets.SpriteAssets` and prints it back as `#`/`.` ASCII art, for checking extracted sprite data
  against source.
- `extract_font.lox` — `odlox.exe extract_font.lox <path/to/48.rom> <output.json>`. Extracts the
  ROM's built-in character set (96 glyphs, ASCII 32-127, address 15616/0x3D00) into an
  `assets.lox`-compatible sprite sheet, one entry per glyph keyed by the literal character itself
  (`lib.get(text[i])` needs no `ord()`/`chr()`, which this Lox dialect doesn't have). Producer side
  of `font_sprites.json` below.
- `extract_start_screen.lox` — `odlox.exe extract_start_screen.lox <path.sna> <output_dir>`.
  Extracts the start/title screen graphic: a single contiguous 4096-byte bit-interleaved pixel run
  at 40960 (real hardware display-file layout, relocated — top two thirds of the screen, 256x128;
  the unused bottom third isn't extracted), plus its attribute cells, which are *not* similarly
  relocated as one block — the top third's row lives at 64512, the middle third's at 40448.
  Writes `start_screen.json` (attribute grid) and `start_screen_sprites.json` (the pixel bitmap, in
  `assets.lox`'s sprite-sheet shape).

**Data**:
- `willy_sprites.json` — Willy's 8 named frames (`willy_right_0..3`, `willy_left_0..3`).
- `font_sprites.json` — generated: the ROM font's 96 glyphs, one `"pixel"`-type sprite per
  character. Produced by `extract_font.lox`, not hand-edited.
- `caverns/` — generated: `cavern_N.json` (layout grid, tile names, conveyor/portal/guardian
  records, `willy_start`, cavern `name`) + `cavern_N_sprites.json` (tile/guardian/portal graphics),
  one pair per cavern, indices 0-19. Produced by `extract_cavern.lox`, not hand-edited.
- `start_screen.json` / `start_screen_sprites.json` — generated: the title screen's attribute grid
  and pixel bitmap. Produced by `extract_start_screen.lox`, not hand-edited.

The source `.sna` snapshot `extract_cavern.lox` reads from, and the `48.rom` dump `extract_font.lox`
reads from, are both gitignored (see the repo `.gitignore`'s "Raw ZX Spectrum game snapshots"/"ROM
dump" entries) — `caverns/` and `font_sprites.json` are what's actually checked in and consumed at
runtime.

## Conventions worth knowing before editing

- **State machines are function-pointer based**, not enums with a switch: `game.lox`'s
  `running`/`die`/`game_over` and `willy.lox`'s movement states both reassign an `update_func`-style
  field to `state_<name>`/`enter_<name>` procedures rather than branching on a state enum every
  tick. Match this pattern when adding a new state rather than introducing a parallel style.
- **Attribute clash is intentional, not a bug.** `Display.blit_sprite()` colours every 8x8
  attribute cell a sprite's bounding box overlaps, not just the sprite's own pixels — this
  reproduces the real hardware's colour bleed onto neighbouring cells for an unaligned sprite.
  Don't "fix" this without checking whether a script is relying on it.
- Every file here already carries a substantial `@file`/`@brief` header comment describing its own
  intent in detail — read that first rather than re-deriving behaviour from the code alone.

## GPU-composited display

`display.lox`'s bitmap/ink/paper colour resolution runs on the GPU: `plot()`/`set_attr()` only
write to their own source buffers (`bitmap`/`attr_ink`/`attr_paper`), and a fragment shader
(`Display`'s embedded `COMPOSITE_SHADER_SRC`) composites them every frame in `draw()`. See
`docs/plans/shader-attribute-compositing.md` (repo root) for the design and its one native
addition (`Shader.set_value_texture` in `src/natives/gfx_shader.odin`), including a documented
deviation from the original design around when `set_value_texture` must be called relative to
`begin_shader_mode()`. Check it before changing `display.lox`'s `plot`/`set_attr`/`begin_flash`/
`flash_ink`/`upload`/`draw`.
