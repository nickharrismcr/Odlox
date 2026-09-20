# CLAUDE.md — lox_examples/jetpac

Guidance specific to this subdirectory. The root `CLAUDE.md` (doc/comment style, `.lox` linting,
trailing-comma gotcha, Odin test runner, per-frame allocation discipline) still applies everywhere
in this tree; this file adds context local to the Jetpac reimplementation. Built following
`docs/plans/jetpac-port.md`, the plan this pattern was proven against
(`lox_examples/manic_miner`) doc — read that plan for the design rationale behind decisions
summarized here.

## What this is

A Lox reimplementation of Ultimate Play the Game's 1983 ZX Spectrum game Jetpac: the same
256x192 1-bit bitmap + 32x24 ink/paper attribute display as `manic_miner` (`display.lox`), driving
Jetman's fly/walk movement, a rocket built from modules and fuel pods carried up from the ground,
meteors, a laser, and score/lives. **Level 1 only** — one alien type (meteor), no level cycling, no
2-player, no menu/loading screen. See "Out of scope" in the plan for the full list of seams left
for later.

Run it with:

```
bin/odlox.exe lox_examples/jetpac/main.lox
```

Controls: LEFT/RIGHT to thrust or walk, UP or SPACE to thrust upward, ENTER to fire. ESC quits.
`main.lox` runs at `TARGET_FPS = 25` — a tuned starting point against video of the original, not a
transcribed rate (the ROM's own 50Hz interrupt processes only one actor per tick, a completely
different execution model — see "Per-tick phase ordering" in the plan).

## File map

**Runtime game code**, in dependency order:
- `main.lox` — window/presentation loop only. Owns the one `game_sound.Sound` (a single audio
  device for the whole process) and the `game.Game` it drives. `Game.__init__(sound)` requires a
  real `Sound`, not `nil` — `Jetman.spawn()` fires a cue (`pickup_item()`, "played when Jetman
  appears on-screen") from inside `Game.__init__` itself, before `tick()` is ever called.
- `game.lox` — `Game`: one play session (platforms/Jetman/Rocket/items/aliens/lasers/explosions,
  score, lives). `tick(win)` runs the established clear-all / move-all / draw-all phase order every
  frame (see `state_running`-equivalent inline in `tick()`) plus `step_death()`'s
  die/explode/wait/respawn flow. No `running`/`die`/`game_over` state-machine split like
  manic_miner's `game.lox` — death is a single free function checking `jetman.is_dead()`'s edge,
  since there's no cavern-reload step to gate on.
- `jetman.lox` — `Jetman`: fly/walk states (`state_fly`/`state_walk`/`state_dying`,
  `enter_fly`/`enter_walk`/`enter_dying`), physics constants named after their disassembly source
  (`VEL_ACCEL`, `MAX_VEL_X_FLYING`, `SCREEN_TOP_Y`, ...). `j.update_func` holds the current state;
  `is_dead()` compares it to `state_dying`. Horizontal position wraps mod 256 (an 8-bit-byte side
  effect on real hardware, not a deliberate design choice). `kill()` is the one entry point for
  anything that ends Jetman's life (alien contact today; falling too far/air-out would call it too,
  neither is in scope).
- `jetman_controller.lox` — `Controller`: polls input once per frame into `left`/`right`/`thrust`/
  `fire` flags (`fire` edge-triggered, matching `defender/player/controller.lox`'s own convention
  for a discrete "one shot per press" action). The only keyboard poll during play.
- `rocket.lox` — `Rocket`: `state_on_pad`/`state_taking_off`/`state_landing`, mirroring the skool's
  own move values $09/$0A/$0B. Owns `modules` (1..3), `fuel` (0..6), the flame animation, and
  `colour_bands()` (magenta for collected fuel, white above). Reaching `FUEL_PODS_NEEDED` (6)
  auto-triggers takeoff; reaching `ROCKET_LAUNCH_TOP_Y` loops back to `state_landing` rather than
  advancing a level (level cycling is out of scope), so the pad/build/launch cycle repeats
  indefinitely instead of stopping after one.
- `item.lox` — `Item`: one class for rocket modules, fuel pods and collectibles, distinguished by
  `kind`. States `state_falling`/`state_carried`/`state_docking`/`state_idle`. **Exactly two `Item`
  instances exist** (`game.lox`'s `rocket_item`/`collectible_item`), matching the skool's own
  `$5D38`/`$5D40` RAM slots, each doing double duty: `RocketReset` ($60A7) copies 24 bytes — the
  rocket record plus *both* the top-module and middle-module templates — into `$5D30` in one shot,
  so `$5D38` (the address `ItemNewFuelPod`/`CollectRocketItem` call "rocket module object") starts
  out holding the **top** module and `$5D40` (`ItemNewCollectible`'s own "collectible object")
  starts out holding the **middle** module — confirmed against actual gameplay footage: all three
  rocket pieces (base + both modules, on separate platforms) are visible from frame one, not
  delivered one at a time. `init_module()` seeds both, once, at `Game` construction — not a spawn
  gate, never called again. Each slot only becomes available for its *other* job (fuel pod /
  collectible respectively, via `spawn_fuel_pod`/`spawn_collectible`, called by `spawner.lox`) once
  its pre-seeded module has actually been delivered, since delivery despawns the same `Item`
  instance those functions later reuse — don't add a third "spawn a module" path expecting it to
  coexist with a fourth pickup kind; there are only ever two module deliveries, total, per game.
- `alien.lox` — `Alien` + `state_meteor`: a fixed 6-slot pool, allocated once and reused (never
  reallocated — see the root `CLAUDE.md`'s per-frame allocation discipline). `state_meteor` is the
  only state in this scope; `ALIEN_STATE_BY_LEVEL` is the seam for the other 7 alien types, paired
  with a level-specific sprite table once a second level exists. Kill order: laser hit, then
  platform collision, then Jetman proximity. Bare Jetman contact is a **mutual** kill — the skool's
  own alien-side handler only ever destroys the alien with no points, but the point of touching an
  alien at all is that it costs Jetman too, so this port kills both (see `alien.lox`'s own comment
  for the ROM line this diverges from).
- `laser.lox` — `LaserPool`: 4 preallocated beam slots. Simplified from the ROM's per-pixel
  fading-pulse animation (`LaserBeamAnimate`, genuinely intricate self-modifying Z80) into one
  moving line segment per beam. `check_hit(x, y)` is the alien-side collision test, consuming the
  beam on a hit. `plot_clamped`/`set_attr_clamped` bounds-check every `Display.plot`/`set_attr`
  call — unlike `blit_sprite`, those don't clip themselves, and a beam's tail can be off-screen for
  a tick after its leading edge (tracked separately) has already wrapped past the edge.
- `explosion.lox` — `Explosion`: the shared 3-frame big/medium/small cycle, used for both alien
  kills and Jetman's own death. A small pool (`game.lox`'s `EXPLOSION_COUNT`), not one per owner.
- `spawner.lox` — `Spawner`: the ROM's `NewActor` ($6971). Advances a timer and calls
  `item.lox`'s own `spawn_fuel_pod`/`spawn_collectible` on the ROM's timing (`(255-timer)%16==0` /
  `timer%128==0`) — **not** a module spawn; there isn't one (see `item.lox`'s own entry above).
  Meteor spawning has no ROM-equivalent cadence to match (aliens aren't item-slot-gated), so its
  interval is this port's own tuning.
- `hud.lox` — `draw_static`/`draw`: score and lives, along the top strip (rows 0-7) rather than a
  below-play row like manic_miner's — Jetpac's platforms already use the whole 192px screen height,
  so there's no spare strip below play. `draw_lives` blanks its icon strip before redrawing every
  tick (a preallocated blank buffer, not a fresh allocation) so a lost life is actually erased.
- `game_sound.lox` — `Sound`: wraps `modules/sound_mgr.SoundManager` with one named method per cue
  (`thrust(y)`, `rocket_build()`, `pickup_fuel()`, `pickup_item()`, `laser()`, `explode_alien()`,
  `explode_player()`), a `mute` constructor flag, `update()`, `close()`. `thrust(y)` buckets Y into
  one of 8 pitch samples and uses `SoundManager.play_if_not`, so holding thrust doesn't restart the
  clip every tick (the port's own ~200ms-per-retrigger stand-in for the ROM's actual ~15ms-per-tick
  beeper toggle — document this deviation again if the bucket count or retrigger behavior changes).
  The two death cues share an exclusivity group so an alien kill can't talk over Jetman's own.
  **`sound` is threaded through actor constructors**, not passed per-call: `Jetman`/`Item`/`Rocket`/
  `Alien` all take it and store `this.sound`, matching `willy.lox`'s own `this.sound` in
  manic_miner. `LaserPool` doesn't — `game.lox`'s own fire call site plays `laser()` directly, since
  `LaserPool` has no per-beam constructor call site to hand a reference to.

**Shared Spectrum-format decoding / sprite base** (no game-state dependencies):
- `display.lox` — started as a verbatim copy of `manic_miner`'s (see that directory's own
  `CLAUDE.md` for the GPU-composited display design, `docs/plans/shader-attribute-compositing.md`).
  **One divergence since**: `blit_sprite()` gained an `or_blit: bool = false` parameter -- when
  true, a sprite's own transparent (0-bit) pixels leave the destination alone instead of
  force-clearing it to black. Jetpac's own rocket/item sprites have real transparent gaps within
  their bounding box (e.g. `rocket_u1_bottom`'s legs), which punched black holes through whatever
  platform art was underneath every time they were drawn -- manic_miner's willy.lox sidesteps the
  same problem with its own bespoke `draw_footprint`/OR-blit logic; `or_blit` is this codebase's
  equivalent, generalized onto `Display` itself since more than one entity kind needed it here
  (see `game_sprite.lox`'s own `or_blit` field, set by `Jetman`/`Item`, and `rocket.lox`'s direct
  calls). Default stays `false` -- most callers, including every sprite's own `clear()`, still want
  the original force-write so erasing actually erases. `spectrum_attr.lox` / `font.lox` are
  unmodified verbatim copies.
- `game_sprite.lox` — `Sprite`: manic_miner's own base, adapted per the plan — dropped the
  bounce-between-fixed-bounds "moving" logic (no Jetpac entity moves that way; owning classes set
  `x`/`y` themselves), kept the erase-then-draw save-under machinery and frame cycling. `draw()`
  **resizes `blank` whenever the drawn image's own size changes**, not just once — `Item` reuses one
  instance across differently-sized sprites (module tiles vs fuel pod vs each collectible), which
  broke with the original once-only allocation (see `item.lox`'s own history for the bug this fixed).
- `platform.lox` — `Platforms`: `draw(disp, lib)` (mirrors `DrawPlatforms` $7638: a left tile at
  `x - (width & ~3) + 16`, `(width>>2)-4` middle tiles, then a right tile) and `collide(x, old_y,
  new_y, height)` (position-based, like `PlatformCollision` $75FC, but **not** that routine's own
  raw `abs(actorX - platformX) < width` test — the ROM's own collision zone doesn't actually agree
  with `DrawPlatforms`' tile span for the same `x`/`width`, which read as a real bug once played
  (collisions registering well outside the visible platform); `collide()`'s horizontal test uses
  the same `left_x`/`span_px` `draw()` computes instead, so collision always matches what's on
  screen. Vertical test still uses the **actor's own height**, not the platform's, as a reach zone
  below the platform's `y`, per the ROM). `landed`/`head_bump` are only honoured while actually
  travelling that direction — `PlatformCollision`'s real ~2px landing window is smaller than
  `jetmanLeavePlatform`'s own liftoff hop, so without that guard a takeoff immediately re-lands the
  same tick (see `platform.lox`'s own comment on `collide()` before changing the landing test).
  **`draw()` is called every tick**, first in the draw phase (`game.lox`'s `tick()`), not once at
  level init — `Display.blit_sprite` always force-overwrites, so any sprite that crossed a platform
  since the last redraw would otherwise leave it permanently damaged.

**Offline tools** (not run as part of the game):
- `skool.lox` — `Skool`: parses `jetpac.skool` into a flat 65536-entry memory image
  (`mem[addr] == -1` means "never disassembled" — a read raises rather than yielding a plausible
  zero) plus `labels`/`addr_to_label` tables. Game-independent; would move to `modules/` if a second
  disassembly is ever ported. **Actor sprites are stored bottom-row-first, not top-down** — see
  `extract_jetpac.lox`'s own header on `reverse_rows()` before touching sprite extraction; this
  bit the first pass here (screenshots showed Jetman/rocket/items upside down while the font and
  platform tiles, which use a different ROM draw routine, looked fine).
- `extract_jetpac.lox` — `odlox.exe extract_jetpac.lox jetpac.skool`. Writes
  `assets/jetpac_sprites.json` (45 sprites), `assets/font_sprites.json` (60 glyphs, ASCII 32-91),
  `data/jetpac_static.json` (platforms, item drop columns, default actor states, collectible
  sprite-table offsets) — every value read from the skool by label, none typed in by hand. Rerun
  after any sprite/static-data change and diff the JSON (`git diff --exit-code`); a diff limited to
  key *order* (not values) is the known `dict.keys()` iteration-order non-determinism, not a
  regression — check values, not raw text, if that comes up again.
- `extract_sfx.lox` — `odlox.exe extract_sfx.lox jetpac.skool`. Writes `data/sfx.json`: a cue table
  of `{name, kind, pitch, cycles, src}`. Only `explosion_sfx_defaults` ($6810) is read from the
  skool (a real `defb` table); every other cue's pitch/duration is an immediate inside a `c$` code
  block `skool.lox` deliberately doesn't disassemble, so those are a hand-copied `CUES` table in
  this file, each entry naming its own skool label/address — extend that table, not `skool.lox`
  itself, if another SFX routine needs adding.
- `tools/render_sfx.py` — `python tools/render_sfx.py [data/sfx.json] [assets]`. stdlib only
  (`wave`/`struct`/`math`) — Lox's `os.write` can't produce binary WAV data (it unescapes a literal
  `\n` into a real newline byte, corrupting anything binary). Reads `data/sfx.json`, writes
  `assets/*.wav`, using `PlaySquareWav2`'s own timing model (`half_period_s = pitch*13/3_500_000`,
  a real Z80 T-state count at 3.5MHz — not an approximation). Three cue `kind`s: `"tone"` (fixed
  pitch, N cycles), `"sweep_up"` (pitch climbs one cycle per step), `"explosion"` (4 repeats 20ms
  apart, each a full sweep down to pitch 1).
- `dump_sprites.lox` — copied verbatim from `manic_miner`. `odlox.exe dump_sprites.lox
  assets/jetpac_sprites.json` prints every sprite as `#`/`.` ASCII art — the fastest way to catch a
  decode direction/order bug (see the `skool.lox` entry above) before it reaches a screenshot.
- `assets.lox` — copied verbatim from `manic_miner`.

**Data**:
- `assets/jetpac_sprites.json` / `assets/font_sprites.json` — generated by `extract_jetpac.lox`, not
  hand-edited.
- `assets/*.wav` (14 files: `thrust_0`..`thrust_7`, `rocket_build`, `pickup_fuel`, `pickup_item`,
  `laser_fire`, `death_enemy`, `death_player`) — generated by `tools/render_sfx.py`, not hand-edited.
- `data/jetpac_static.json` / `data/sfx.json` — generated by `extract_jetpac.lox` /
  `extract_sfx.lox` respectively, not hand-edited.

The source `jetpac.skool` (a disassembly of copyrighted commercial firmware) is gitignored — see
the repo `.gitignore`'s entry, worded like manic_miner's own `.sna`/`.rom` treatment. Fetch it with:

```
curl -O https://raw.githubusercontent.com/mrcook/jetpac-disassembly/master/jetpac.skool
```

## Conventions worth knowing before editing

- **State machines are function-pointer based**, matching manic_miner: `jetman.lox`'s
  `state_fly`/`state_walk`/`state_dying`, `rocket.lox`'s `state_on_pad`/`state_taking_off`/
  `state_landing`, `item.lox`'s `state_falling`/`state_carried`/`state_docking`/`state_idle`, and
  `alien.lox`'s `state_meteor`/`state_idle` all reassign an `update_func`-style field rather than
  branching on a state enum every tick. Every state function in a given class shares one call
  signature even when a particular state ignores most of the arguments (`state_idle`/`state_dying`
  taking the full parameter list and using none of it is expected, not a bug — lox_lsp's
  "declared but never used" warning on those is the documented false-positive class from the root
  `CLAUDE.md`, not a lead to chase).
- **Position-based collision, not pixel-based** — `platform.lox`'s `collide()` and the various
  Jetman/item/alien proximity checks (`ALIEN_HIT_DX`/`ALIEN_HIT_DY`) all compare raw x/y coordinates
  against fixed thresholds, exactly as `PlatformCollision`'s own disassembly comment states
  ("collision detection is location based not pixel/colour based") — a collision can register
  before the sprites visually touch, or not register a near-miss overlap. Don't "fix" this to be
  pixel-perfect without checking whether a script is relying on the ROM's own tolerance.
- **Two different sprite draw conventions coexist** in the ROM, and matter every time a new sprite
  category is extracted: `DrawCharPixels` ($7126, steps down the screen) draws the font and
  platform/life-icon tiles top-row-first; `MaskSprite` ($7705, steps up via
  `ScreenPosOnePixelAbove`) draws every "Actor" sprite (anything with the 3-byte/1-byte header —
  Jetman, rocket parts, items, explosions, aliens) bottom-row-first. `extract_jetpac.lox`'s
  `reverse_rows()` is the fix for the second category only; a new Actor-shaped sprite needs it, a
  new tile-shaped one doesn't.
- **Deliberate simplifications from the ROM**, each documented at its own call site, not just here:
  Jetman's fly/walk physics (accelerate/brake/flip, gravity, screen bounce) are reimplemented in
  named constants rather than transliterated Z80; the laser is one moving line segment per beam,
  not a per-pixel fading pulse; explosion/death SFX are rendered as fixed clips, not the ROM's
  live per-tick frequency sweep; the rocket loops pad→launch→pad instead of advancing a level.
  None of these need to become more ROM-accurate without a specific reason — they were chosen
  because the exact ROM behavior was either ambiguous even to the disassembly's own annotator
  ("needs more work!", "No hit ???" appear in `jetpac.skool` itself around `PlatformCollisionVertical`)
  or not worth the fidelity for a single-level port.

## Verification

- **Extractors are deterministic** in content (not raw JSON key order — see the `extract_jetpac.lox`
  entry above). Re-run and check values, not text diff, if this needs re-confirming.
- **Lint every new/edited `.lox` file** with lox_lsp's `src/lint-cli.ts` per the root `CLAUDE.md`.
  Treat anything outside the two documented false-positive classes (shadowing; this directory's
  uniform state-function signatures) as real.
- **`bin/run_tests.sh`/`bin/test_odin.sh` don't apply** — this directory touches only
  `lox_examples/`, no `src/` natives.
- No headless test harness is checked in for this example (manic_miner doesn't have one either);
  verification during development was a mix of a scratch Lox script driving `jetman.step()`/
  `item.step()`/`alien.step()` etc. directly with synthetic input (to check physics/state-machine
  behavior in isolation, fast, no window needed) and `win.screenshot()` (to catch what only shows up
  visually — sprite orientation, colour banding, HUD layout). Both are worth reaching for again over
  guessing from source reading alone, particularly for anything touching sprite decode order,
  collision thresholds, or render/erase (`clear()`) correctness.
