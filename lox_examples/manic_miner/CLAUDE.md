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

`cavern_index` defaults to 3 (`main.lox`). Controls: LEFT/RIGHT to walk, UP or SPACE to jump, ESC
to quit. `main.lox` runs at a fixed `TARGET_FPS = 15` — Manic Miner's own original tick rate, not
this engine's usual 60fps target (see `game_sprite.lox` for the movement/animation code this rate
drives).

## File map

**Runtime game code**, in dependency order:
- `main.lox` — window/presentation loop only. Owns nothing but the `win`/`Display` frame
  lifecycle and HUD text; all session state lives in `game.Game`.
- `game.lox` — `Game`: one play session (cavern, Willy, controller, sprite assets, Display).
  `running`/`die`/`game_over` state machine.
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

**Data**:
- `willy_sprites.json` — Willy's 8 named frames (`willy_right_0..3`, `willy_left_0..3`).
- `font_sprites.json` — generated: the ROM font's 96 glyphs, one `"pixel"`-type sprite per
  character. Produced by `extract_font.lox`, not hand-edited.
- `caverns/` — generated: `cavern_N.json` (layout grid, tile names, conveyor/portal/guardian
  records, `willy_start`, cavern `name`) + `cavern_N_sprites.json` (tile/guardian/portal graphics),
  one pair per cavern, indices 0-19. Produced by `extract_cavern.lox`, not hand-edited.

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
