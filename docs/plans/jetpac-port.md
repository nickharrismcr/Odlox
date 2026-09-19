# Jetpac port for odlox, following the manic_miner pattern

## Context

`lox_examples/manic_miner/` is the repo's largest worked example: a ZX Spectrum game
reimplemented in Lox on top of a `Display` class that emulates the Spectrum's 256x192
1-bit bitmap plus 32x24 ink/paper attribute grid, GPU-composited by a fragment shader.
It establishes a reusable house pattern — offline extractors that turn original game data
into checked-in JSON, a `SpriteAssets` loader, function-pointer state machines, a
clear/move/draw phase order, and one window tick per game tick.

Jetpac (Ultimate Play the Game, 1983) is a good second subject: same display model, a much
smaller data set, and `mrcook/jetpac-disassembly`'s `jetpac.skool` is a fully annotated
SkoolKit disassembly with every sprite, lookup table and constant labelled. This plan adds
`lox_examples/jetpac/` as a second example built to the same pattern, proving the pattern
generalises and giving the repo a second graphics-heavy `.lox` showcase.

Decisions already settled — do not revisit these when implementing:

- **Data source: parse `jetpac.skool` directly.** The disassembly repo ships no ROM or
  snapshot, but the skool text contains all graphics and tables as `defb`/`defw` data
  blocks, each preceded by an `@label=` line. This replaces manic_miner's `sna.lox`
  snapshot reader and gives every sprite a real name for free.
- **Scope: core loop, one alien type.** Level 1 only — Jetman fly/walk, rocket assembly
  from 3 modules, 6 fuel pods, meteors, collectibles, death and respawn. Seams left for
  the other 7 alien types, level cycling, 2-player and the menu.
- **Audio: generated `.wav` assets.** An offline tool renders the skool's square-wave
  frequency/duration pairs to `assets/*.wav`; `game_sound.lox` plays them through
  `modules/sound_mgr`, same shape as manic_miner's `Sound`.

## Reference material

Read before starting:

- `lox_examples/manic_miner/CLAUDE.md` — the pattern doc this port mirrors.
- `CLAUDE.md` (repo root) — comment ceiling (1-7 lines, target 2-4), neutral prose, no
  trailing comma in call-argument/parameter lists, no per-frame allocation, lint `.lox`
  with lox_lsp.
- `lox_examples/manic_miner/display.lox`, `assets.lox`, `game_sprite.lox`, `game.lox`,
  `willy.lox` — the code being adapted.
- `docs/plans/shader-attribute-compositing.md` — why `Display.draw` orders its
  `set_value_texture` calls inside `begin_shader_mode()`.

`jetpac.skool` is the input to the extractors. It is **not** checked in (gitignore it
alongside manic_miner's `.sna`/`48.rom`); the generated JSON is what the repo carries.
Fetch it with:

```
curl -O https://raw.githubusercontent.com/mrcook/jetpac-disassembly/master/jetpac.skool
```

## Directory layout

```
lox_examples/jetpac/
  CLAUDE.md                 # subdirectory pattern doc, modelled on manic_miner's
  main.lox                  # window + stage lifecycle only
  game.lox                  # class Game: the play session
  jetman.lox                # class Jetman + fly/walk/die states
  jetman_controller.lox     # class Controller: the only keyboard poll during play
  rocket.lox                # class Rocket: modules, fuel, takeoff/landing states
  item.lox                  # class Item: module/fuel-pod/collectible lifecycle
  alien.lox                 # class Alien + meteor update; the 6-slot pool
  spawner.lox               # NewActor: timer/random advance and all spawn gating
  laser.lox                 # class LaserPool: 4 beam slots
  explosion.lox             # class Explosion: 3-frame animation + thruster smoke
  platform.lox              # the 4 static platforms: draw + collision
  hud.lox                   # score / hi-score / lives row
  assets.lox                # copied verbatim from manic_miner
  display.lox               # copied verbatim from manic_miner
  game_sprite.lox           # adapted from manic_miner (see below)
  game_sound.lox            # new: Jetpac's cue set, same Sound class shape
  font.lox                  # adapted: Jetpac's own font, not the 48K ROM font
  spectrum_attr.lox         # copied verbatim from manic_miner
  skool.lox                 # new: SkoolKit .skool data-block parser
  extract_jetpac.lox        # offline: skool -> sprite sheet + static data JSON
  extract_sfx.lox           # offline: SFX params -> data/sfx.json
  dump_sprites.lox          # copied verbatim from manic_miner
  tools/render_sfx.py       # offline: data/sfx.json -> assets/*.wav
  assets/
    jetpac_sprites.json     # generated, checked in
    font_sprites.json       # generated, checked in
    *.wav                   # generated, checked in
  data/
    jetpac_static.json      # generated, checked in
    sfx.json                # generated, checked in
```

Copied verbatim: `display.lox`, `assets.lox`, `spectrum_attr.lox`, `dump_sprites.lox`.
manic_miner's `sna.lox` and `spectrum_screen.lox` are **not** carried over — there is no
snapshot and no display-file address decoding to do, since the skool labels give sprite
locations directly.

`game_sprite.lox` is adapted rather than copied: manic_miner's `Sprite` bounces between
fixed bounds on a tile grid, which no Jetpac entity does. Keep its erase-then-draw
save-under machinery (`last_x`/`last_y`/`blank`/`erase_ink`/`erase_paper`, the lazily
allocated single `blank` buffer) and frame cycling; drop the `type == "moving"` bounce
logic. Every Jetpac entity class composes or extends this.

Naming follows the established rule: `game_sound.lox` not `sound.lox` (`sound` is the
native module), and controller input lives in its own file so the keyboard is polled in
exactly one place.

## Part 1 — `skool.lox`: the data-block parser

A `.skool` line is one of:

```
@label=gfx_gold_bar
b$7dd4 defb $00
 $7dd5 defb $02,$08
 $7dd7 defb $ff,$fc,$80,$0e,$40,$1e,$40,$1f
```

Rules the parser must honour:

- A line starts with an optional block-type letter (`b` `w` `t` `s` `g` `u` for data,
  `c` for code), or a space for a continuation line, then `$ADDR`. A `*` may prefix the
  address on a branch target. Every line carries its own address, so no accumulator is
  needed.
- Only data directives carry bytes: `defb` (bytes), `defw` (little-endian words, low byte
  first), `defm "text"` (ASCII, may be mixed with `defb` on one line), `defs N` (N zero
  bytes). `c$` blocks are disassembled mnemonics — skip them entirely.
- Lines beginning `;` are comments; `@nowarn`, `@ssub=`, `@defs=` and other `@directive=`
  lines are skipped. `@label=NAME` applies to the next address line.
- Block type is sticky: a continuation line inherits the type of the `b$`/`c$` line above.

API:

```lox
class Skool {
    __init__(path)          // parses once
    byte(addr)              // -> int
    bytes(addr, count)      // -> list of int
    word(addr)              // -> int, little-endian
    addr_of(label)          // -> int, raises if absent
    bytes_at_label(label, count)
}
```

Internals: `this.mem` is a 65536-entry list prefilled with `-1` (built once in a loop —
there is no list-repeat operator). `-1` means "this address was never disassembled", so a
stray read raises instead of yielding a plausible zero, which is the failure mode that
would otherwise produce a silently blank sprite. `this.labels` maps label to address, and
the inverse map (address to label, first label winning where two share an address, as
`sprite_lookup_tables`/`jetman_sprite_table` do) lets the extractor name sprites from the
`defw` tables rather than from hardcoded addresses.
Read the file with `os.read_all(path)` (returns the whole file as one string) and split on
newlines with `re.split`; `modules/string.lox`'s `split` walks character by character,
which is slow over a 230KB file. Hex parsing is a local `parse_hex(s)` helper — this
dialect's `int()` takes no base — and `re.findall` pulls the `\$[0-9a-f]+` tokens off a
`defb`/`defw` line.

This file is the one genuinely new piece of infrastructure. It is game-independent — if a
third Spectrum disassembly is ever ported, it moves to `modules/`.

## Part 2 — `extract_jetpac.lox`: the offline extractor

```
cd lox_examples/jetpac && ../../bin/odlox.exe extract_jetpac.lox jetpac.skool
```

Writes `assets/jetpac_sprites.json`, `assets/font_sprites.json` and
`data/jetpac_static.json`.

### Sprite slicing

Two header formats, both documented in the skool:

- **Jetman / rocket / item sprites** — 3-byte header `[x offset, width in tiles, height in
  pixels]`, then `width * height` packed bytes, MSB-first. Emit as `data_type: "byte"`
  with `"width": tiles * 8`, which `assets.decode_byte_rows` already handles.
- **Alien sprites** — 1-byte header `[height]`, always 16px wide, then `2 * height` bytes.

Sprites to emit, by label:

| Group | Labels |
| --- | --- |
| Jetman | `gfx_jetman_fly_right1`, `gfx_jetman_fly_left1`, `gfx_jetman_walk_right1`, `gfx_jetman_walk_left1` — four poses, no animation (see below) |
| Rocket | `gfx_rocket_u{1,3,4,5}_{bottom,middle,top}`, `gfx_rocket_flames1`, `gfx_rocket_flames2` |
| Items | `gfx_fuel_pod`, `gfx_gold_bar`, `gfx_radiation`, `gfx_chemical_weapon`, `gfx_plutonium`, `gfx_diamond` |
| Aliens | `gfx_meteor1`, `gfx_meteor2` (scope: level 1 only; the other 7 labels exist and can be added without touching the extractor's structure) |
| Explosions | `gfx_explosion_big`, `gfx_explosion_medium`, `gfx_explosion_small` |
| Tiles | `tile_platform_left`, `tile_platfor_mmiddle` (sic — the skool's own typo), `tile_platform_right`, `tile_life_icon` |
| Font | `system_font`, sliced into 8-byte glyphs keyed by the literal character, as manic_miner's `extract_font.lox` does |

Sprite-sheet schema is manic_miner's, unchanged:

```json
[ { "name": "jetman_fly_right_0", "data_type": "byte", "width": 16,
    "data": [16, 0, 32, 0, 216, 0, ...] } ]
```

Names in the JSON are snake_cased runtime names, not the raw skool labels — the extractor
holds the label-to-name mapping so the runtime never sees `tile_platfor_mmiddle`.

**Jetman does not animate.** `jetman_sprite_table` ($76C5) has 16 entries, but
`ActorGetSpriteAddress` ($7292) indexes it with the low bits of the *x position*
(`x & $06`), not a frame counter: entries 1..4 of each pose are the 0/2/4/6-pixel
pre-shifted copies the ROM's byte-aligned blitter needs — which is why `..._right1` is
2 tiles wide and `..._right2/3/4` are 3. `Display.blit_sprite` plots at an arbitrary x, so
the runtime needs only the four shift-0 sprites. The same applies to
`buffers_items_lookup_table` ($76F5). `gfx_meteor1`/`gfx_meteor2` **are** a real two-frame
animation (`alien_sprite_table` $690E), as is `gfx_rocket_flames1/2`.

Emit the 12 shifted variants anyway, named `..._shift2/4/6`, so the choice is auditable
from the JSON; the runtime loads only the four.

**Discovered while checking the format:** every data line in the skool carries its own
`$ADDR`, every `defb`/`defw` operand is `$hh`/`$hhhh`, and no data directive ever appears
inside a `c$` block. So the parser needs neither an address accumulator nor sticky
block-type tracking — a line is data iff its directive token is one of the four. The
sticky-block-type rule in the API sketch above can be dropped.

### Static data

`data/jetpac_static.json`, read once by `game.lox`:

```json
{
  "platforms": [ {"attr": 4, "x": 128, "y": 96,  "width": 27,  "name": "middle"},
                 {"attr": 6, "x": 120, "y": 184, "width": 136, "name": "ground"},
                 {"attr": 4, "x": 48,  "y": 72,  "width": 35,  "name": "left"},
                 {"attr": 4, "x": 208, "y": 48,  "width": 35,  "name": "right"} ],
  "item_drop_columns": [8,32,40,48,56,64,88,96,120,128,136,192,224,8,88,96],
  "default_jetman":  {"motion":1,"x":128,"y":183,"attr":71,"state":0,"vx":0,"vy":0,"height":36},
  "default_rocket":  {"move":9,"x":168,"y":183,"attr":2,"modules":1,"fuel":0,"height":28},
  "default_top_module":    {"type":4,"x":48,"y":71,"attr":71,"state":0,"sprite":16,"height":24},
  "default_middle_module": {"type":4,"x":128,"y":95,"attr":71,"state":1,"sprite":8,"height":24},
  "default_fuel_pod": {"type":4,"x":0,"y":32,"attr":67,"state":1,"sprite":24,"height":24},
  "default_item":     {"type":14,"x":0,"y":32,"attr":0,"state":0,"sprite":0,"height":24},
  "collectible_sprites": {"32":"gold_bar","34":"radiation","36":"chemical_weapon",
                          "38":"plutonium","40":"diamond"},
  "item_level_object_types": [3,17,6,7,15,5,3,15],
  "alien_sprites_by_level": [["meteor_0","meteor_1"], ["squidgy_0","squidgy_1"], "..."],
  "jump_table": {"1":"jetman_fly","2":"jetman_walk","3":"meteor","4":"item_module",
                 "8":"explosion","9":"rocket_on_pad","10":"rocket_takeoff",
                 "11":"rocket_landing","14":"item_falling","16":"laser_animate"},
  "scores": {"collectible": 250, "rocket_item": 100, "meteor": 25}
}
```

Every number is read out of the skool by the extractor (from `gfx_params_platforms`
$6003, `item_drop_positions_table` $65E9, `default_player_state` $6013,
`default_rocket_state` $601B, `default_rocket_module_state` $6033, `default_item_state`
$603B, `collectible_sprite_table` $678C), not typed in by hand — the values above are for
review, so a mismatch after extraction is a parser bug worth chasing.

Following manic_miner's rule, the data file carries **name pointers, never pixel data**.

## Part 3 — `extract_sfx.lox`: generated audio

Jetpac's SFX are beeper square waves: `PlaySquareWave1` ($67D6) and `PlaySquareWav2`
($67DB, the skool's own spelling) driven by a frequency byte and a duration byte.
`SfxSetExplodeParams` ($67FD) and `explosion_sfx_defaults` ($6810) hold the explosion
pairs; `SfxThrusters` ($67B6) derives its pitch from the actor's Y position. The remaining
cues are `SfxRocketBuild` ($67C6), `SfxPickupFuel` ($67CC), `SfxPickupItem` ($67D2) and
`SfxLaserFire` ($67E7).

**A WAV cannot be written from Lox.** `os.write` accepts a string only, and
`core/obj_file.odin`'s `file_write` rewrites the two-character sequence `\n` into a real
newline inside whatever it writes — binary output would be silently corrupted. There is no
`os.write_bytes` and no `chr()`. So the pipeline splits in two:

- `extract_sfx.lox` — reads `explosion_sfx_defaults` ($6810) from the skool and writes
  `data/sfx.json`: a cue table of `{name, kind, pitch, cycles, src}`. The remaining
  parameters are immediates inside `c$` blocks that the parser deliberately skips, so they
  live as a commented `const` table in this tool, each entry naming its skool label and
  address — the same habit as `manic_miner/game_sound.lox`'s `TUNE_TABLE`.
- `tools/render_sfx.py` — stdlib only (`wave`, `struct`, `math`), reads `data/sfx.json`
  and writes `assets/*.wav`. Precedent for a Python helper in this repo: `bin/time_lox.py`.

Adding an `os.write_bytes` native would let the whole thing stay in Lox, but that is a
`src/` change and pulls in the `bin/run_tests.sh` gate. Not worth it for one offline tool.

Timing model, from `PlaySquareWav2` ($67DB): the pitch byte is a half-period counted in
`djnz` iterations (13 T-states at 3.5 MHz), and the second byte is the cycle count, so
`half_period_s = pitch * 13 / 3500000` and `clip_len_s = cycles * 2 * half_period_s`.

Cues to emit: `thrust_0`..`thrust_7` (the thruster pitch is derived from Jetman's y and
lands in 64..127, so bucket it into 8 rather than synthesising per tick), `rocket_build`,
`pickup_fuel`, `pickup_item`, `laser_fire`, `death_player`, `death_enemy` — 15 files,
covering every sound level 1 can make.

Two deviations to document in `game_sound.lox`'s header: the ROM emits ~15 ms of thruster
per tick, where the port holds a ~200 ms clip alive with `play_if_not`; and the explosion
and laser sweeps emit one cycle per pitch step (a whole sweep is 1-11 ms), so
`death_player` becomes four such sweeps 20 ms apart rather than four separate frames.

`game_sound.lox` is a `Sound` class wrapping `modules/sound_mgr.SoundManager` with one
named method per cue (`thrust(y)`, `rocket_build()`, `pickup_fuel()`, `pickup_item()`,
`laser()`, `explode_player()`, `explode_alien()`), a `mute` constructor flag (set via
`SoundManager.no_sound` before construction), `update()` called once per tick, and
`close()`. No string cue keys at call sites. `thrust()` uses `SoundManager.play_if_not`,
which re-triggers a one-shot only when it is not already playing — that keeps the thruster
looping for as long as thrust is held without restarting it every tick. The two explosion
cues share an exclusivity group so an alien kill cannot talk over Jetman's death.

## Part 4 — runtime design

### Stage contract

`main.lox` owns the window and the single `Sound`, and drives `game.Game` through the
established contract — `__init__(sound)`, `.disp`, `tick(win)`, `is_done()`:

```
bin/odlox.exe main.lox        # run with cwd = lox_examples/jetpac
```

Asset paths stay cwd-relative (`"assets/jetpac_sprites.json"`), matching manic_miner and
`lox_examples/defender`. `Display.__init__` builds render textures, so it must be
constructed after `win.init()` — carry manic_miner's comment saying so.

`TARGET_FPS = 25`. The original runs one `MainLoop` pass per 50Hz interrupt but only
executes one jump-table entry per pass, so a straight 50fps port moves everything too
fast; 25 is the starting point to tune against video of the original, and the constant
carries a comment saying it is a tuned value, not a transcribed one.

No `Intro`/`Demo` stage in this scope. The `main.lox` loop shape still leaves room for
them (the skool's `loading_screen` at $7FB3 and `MenuScreen` at $61D5 are the seams).

### Classes

- **`Jetman`** (`jetman.lox`) — extends the adapted `Sprite`. Class body: `__init__`,
  `spawn`, `step`, `clear`, `draw`. Everything else is a module-level free function taking
  `j` first, per the pattern. States: `state_fly`, `state_walk`, `state_dying`, with
  `enter_fly`/`enter_walk`/`enter_dying`. `j.update_func` holds the current state;
  `is_dead()` compares `j.update_func == state_dying`.
- **`Rocket`** (`rocket.lox`) — states `state_on_pad`, `state_taking_off`,
  `state_landing`, mirroring the skool's `[0]` movement values $09/$0A/$0B. Owns
  `modules` (1..3) and `fuel` (0..6), the flame animation, and `colour_bands()` (magenta
  for collected fuel, white above — the skool's `UpdateRocketColour`).
- **`Item`** (`item.lox`) — one class for rocket modules, fuel pods and collectibles,
  distinguished by `kind`. States `state_falling`, `state_carried`, `state_docking`,
  `state_idle`; the skool's `[4]` values 1=new, 3=collected, 5=free-fall, 7=dropped map
  onto these. Module-level `spawn_fuel_pod(g)` and `spawn_collectible(g)` hold the
  spawn-gate conditions.
- **`Alien`** (`alien.lox`) — a fixed pool of 6 slots allocated once at startup and
  reused, never reallocated. `state_meteor` is the only update function in this scope. The
  seam for the rest is one module-level table,
  `const ALIEN_STATE_BY_LEVEL = [state_meteor, nil, nil, nil, nil, nil, nil, nil]`,
  paired with `alien_sprites_by_level` from the static JSON: adding `state_squidgy` later
  is one new function plus one table slot, with no other file touched.
- **`spawner.lox`** — the ROM's `NewActor` ($6971): advance `game_timer` and `random`,
  then `new_fuel_pod` (module slot free, `fuel < 6`, `(255 - timer) % 16 == 0`),
  `new_collectible` (item slot free, `timer % 128 == 0`) and `new_alien` (a free slot
  among the 6, `y = (timer % 128) + 40`, direction from `timer % 128 >= 64`, colour $02..$05
  from the slot index). Drop column is `item_drop_columns[random % 16]`. Kept out of the
  actor classes so the spawn gates read as one block against the ROM.
- **`LaserPool`** (`laser.lox`) — 4 preallocated beam slots, matching
  `laser_beam_params`' 4 records of `[used, y, x1..x4, length, colour]`.
- **`Explosion`** (`explosion.lox`) — the 3-frame big/medium/small cycle, used for both
  alien kills and Jetman's death, plus the thruster smoke puff.
- **`Platforms`** (`platform.lox`) — the 4 static rectangles: `draw(disp, lib)` once at
  level init, and `collide(x, y, height) -> dict` returning the skool's collision bits as
  named booleans (`landed`, `overlaps_x`, `head_bump`, `leaving`), since
  `PlatformCollision` ($75FC) packs them into register E's bits 7/3/4/2. Collision is
  position-based, not pixel-based, exactly as the original.
- **`Game`** (`game.lox`) — class body is `__init__`, `tick`, `is_done()`,
  `is_game_over()`. States `state_running`, `state_die`, `state_rocket_launch`,
  `state_game_over`; everything else is a free function taking `g`.

### Physics constants

Lifted from the skool into a `const` block in `jetman.lox`, each with the address it came
from. Position is 16-bit: high byte is the pixel row/column, low byte a sub-pixel
accumulator; velocity is added as `velocity * 8` into that 16-bit value, so effective
speed is `velocity / 32` pixels per tick.

This Lox dialect has no hex literals (`src/compiler/scanner.odin`), so constants are
decimal with the original hex in the comment — the convention
`lox_examples/manic_miner/extract_font.lox` already uses.

```lox
const VEL_ACCEL          = 8    // $73C3/$7425: 8 minus the velocity modifier
const VEL_MODIFIER       = 4    // $5DCA: 0 or 4, halving acceleration
const MAX_VEL_X_FLYING   = 64   // $40, $73D6 clamp
const MAX_VEL_X_WALKING  = 32   // $20, $757C/$75B8
const MAX_VEL_Y          = 63   // $3F, $7448 clamp
const WALK_STEP          = 1    // $75AD/$75BF: 1 pixel per tick
const SCREEN_TOP_Y       = 42   // $2A, $746B: flight clamped to 42..192
const SCREEN_BOTTOM_Y    = 192  // $C0
const JETMAN_HEIGHT      = 36   // $24, default_player_state byte 7
const ALIEN_HIT_DX       = 12   // $0C, $6E00
const ALIEN_HIT_DY       = 21   // $15, $6E14
```

Rocket/item constants (`FUEL_DOCK_Y = 176`, `MODULE_DOCK_Y = 183`,
`ROCKET_LAUNCH_TOP_Y = 40`, `ROCKET_PAD_Y = 183`, `CARRY_SNAP_DX = 6`,
`FUEL_PODS_NEEDED = 6`) live in `rocket.lox` and `item.lox` respectively.

### Per-tick phase ordering

The ROM's `main_jump_table` ($633D) is not a per-tick sequence of 18 routines. `MainLoop`
($631C) reads byte 0 of the *current* actor, computes `(v * 2) % 128`, and jumps through
the table; `NewActor` ($6971) then advances `ix` by 8 and re-enters, stopping at $5D88;
`FrameUpdate` ($692E) restarts the walk at $5D00. One frame is therefore a walk over a
flat array of 8-byte actors in address order, each dispatching on byte 0 — which is
exactly this codebase's `update_func` convention, with byte 0 as the state id:

| byte 0 | ROM routine | odlox state |
| --- | --- | --- |
| $00 | (idle slot) | `state_idle` |
| $01 | `JetmanFlyThrust` | `jetman.state_fly` |
| $02 | `JetmanWalk` | `jetman.state_walk` |
| $03 | `MeteorUpdate` | `alien.state_meteor` |
| $04 | `ItemPickup` | `item.state_module` |
| $08 | `AnimateExplosion` | `explosion.state_animate` |
| $09/$0A/$0B | `RocketUpdate`/`Takeoff`/`Landing` | `rocket.state_on_pad`/`state_takeoff`/`state_landing` |
| $0E | `ItemCheckCollect` | `item.state_falling` |
| $10 | `LaserBeamAnimate` | `laser.state_animate` |
| $05,$06,$07,$0F,$11 | the other alien types | the seam for later levels |

So `Game` builds **one ordered actor list, once, in ROM address order** — and that list is
both the update order and the z-order:

```
[ jetman, laser0..3, rocket, module_slot, item_slot, thruster_anim, alien0..5, death_anim ]
```

`state_running` then follows manic_miner's clear-all / move-all / draw-all discipline over
that list:

```lox
func state_running(g, win) {
    g.controller.update(win)
    g.sound.update()

    foreach (var a in g.actors) { a.clear(g.disp) }

    foreach (var a in g.actors) {
        var f = a.update_func
        f(a, g)
    }
    spawner.tick(g)             // the ROM's NewActor, once per frame

    foreach (var a in g.actors) { a.draw(g.disp, g.lib) }
    g.rocket.update_colour(g.disp)
    hud.draw(g)
    g.frame_count = g.frame_count + 1

    if (g.jetman.is_dead()) { enter_die(g, win); return }
    if (g.rocket.is_launching()) { enter_rocket_launch(g, win) }
}
```

Jetman is first in the list, so every alien and item collision test in the same frame sees
his current-tick position — the ROM's ordering, and the reason the list order is fixed
rather than incidental. Slots are never appended or removed: a dead actor gets
`update_func = state_idle`, exactly as the ROM writes $00 to byte 0.

The platforms are drawn once at level init, not per tick — they never move and nothing
erases them except a sprite passing over, which the save-under restore already handles.

### Allocation discipline

Per the root `CLAUDE.md`: the alien pool (6), laser pool (4), item slots (2 — the skool
has exactly one rocket-module slot and one collectible slot live at a time), explosion
slots and every `float_array` save-under buffer are allocated once in `Game.__init__` and
reused. Nothing in `state_running` constructs a list, dict or `float_array`.

## Part 5 — build order

Each step ends with something runnable or inspectable, and is one commit.

1. **`skool.lox` + a smoke test.** Parse the file, print label count and a few known
   bytes (`skool.bytes_at_label("gfx_gold_bar", 3)` must be `[0, 2, 8]`). No game code yet.
   Add `*.skool` to `.gitignore` in the same commit, worded like the existing `*.sna` and
   `*.rom` entries at lines 17-24 (a disassembly of a copyrighted commercial game, kept
   local; the committed JSON is what the repo carries).
2. **`extract_jetpac.lox` + `dump_sprites.lox`.** Generate the sprite sheet, eyeball every
   sprite as ASCII art. Commit the generated JSON.
3. **Static scene.** `display.lox`, `assets.lox`, `spectrum_attr.lox`, `font.lox`,
   `platform.lox`, a stub `main.lox`/`game.lox` that draws the four platforms, the rocket
   base and a stationary Jetman. First screenshot.
4. **`jetman.lox`.** Fly/walk states, thrust, gravity, platform collision, animation
   frames. Playable movement.
5. **`item.lox` + `rocket.lox`.** Rocket module drop, carry, dock; fuel pod spawn, carry,
   dock; rocket colour bands; takeoff and landing. The core loop closes.
6. **`alien.lox` + `spawner.lox` + `laser.lox` + `explosion.lox`.** Meteors, firing, kills,
   Jetman death and respawn, lives. Core loop complete, silent.
7. **`hud.lox`, then audio.** Score, hi-score, lives icons; then `extract_sfx.lox`,
   `data/sfx.json`, `tools/render_sfx.py`, `assets/*.wav`, `game_sound.lox`, and the
   `sound` argument threaded through the actor constructors.
8. **`CLAUDE.md`.** The subdirectory pattern doc, written last so it describes what was
   actually built — file map with what each file does and does not own, the run line, the
   extraction commands, and the conventions a future editor must match.

## Verification

- **Extractors are deterministic.** Re-running `extract_jetpac.lox` on the same
  `jetpac.skool` must produce byte-identical JSON; `git diff --exit-code data/ assets/*.json`
  after a re-run is the check. The usual cause of a diff is a `dict.keys()` iteration order
  leaking into output, so the extractor writes lists in fixed order throughout.
  `tools/render_sfx.py` gets the same treatment against `assets/*.wav`.
- **Assert inside the extractor, not only after.** Back `Skool.mem` with a 65536-entry
  list prefilled with `-1` rather than a dict, so a read of an address the disassembly
  never defined raises instead of yielding a plausible zero. Every sprite slice checks its
  whole range against that sentinel, and each `words()` table read asserts its expected
  length (16 jetman, 16 alien, 6 explosion, 21 collectible, 16 drop columns, 4 platforms).
- **Sprite decode.** `dump_sprites.lox assets/jetpac_sprites.json` prints `#`/`.` art;
  compare Jetman, the meteor, the fuel pod and the rocket sections against screenshots of
  the original. A transposed or bit-reversed decode is obvious at this stage.
- **Static data.** The extracted platform rectangles and drop columns must match the
  values tabulated in Part 2; a one-off `print` of `jetpac_data.json` against that table
  catches an address slip in the parser.
- **Runtime.** Run `bin/odlox.exe main.lox` from `lox_examples/jetpac` after `. ./setenv`
  from the repo root. Per step: platforms in the right places (3), Jetman flies and lands
  on all four platforms without sinking or sticking (4), the rocket assembles from 3
  modules and takes off after exactly 6 fuel pods (5), meteors spawn, can be shot, and
  kill Jetman on contact (6).
- **Lint.** Run lox_lsp's `src/lint-cli.ts` over every new `.lox` file, chunked to ~30
  files per invocation. Treat anything outside the documented shadowing false-positive
  class as a real finding.
- **Not the gate here.** `bin/run_tests.sh` and `bin/test_odin.sh` cover `src/` changes;
  this change touches only `lox_examples/`, so neither applies unless a native is modified.
  If the port turns out to need a new native, that is a separate change with its own
  `pytest` coverage per `src/natives/README.md`.

## Out of scope for this change

Left as clean seams, not built: the other 7 alien types (`alien_sprite_table` at $690E
already maps level to sprite pair), level cycling and the every-4-levels new-rocket rule
(`LevelNew` $6083), 2-player alternation (`PlayersSwap` $6144), the menu screen
(`MenuScreen` $61D5), the loading screen (`loading_screen` $7FB3), and joystick input.
