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
a laser, and score/lives. All 8 ROM alien types cycle in by level (`alien.lox`'s `ALIEN_TYPES`,
keyed by `rocket.level % 8`) — but the screen itself doesn't change: same platforms, same
background, every level, just a fresh pad→launch→pad cycle with the next alien type. No 2-player,
no menu/loading screen. See "Out of scope" in the plan for the full list of seams left for later.

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
  neither is in scope). `draw()`'s walk-cycle position compensation is TWO independent corrections,
  not one (`walk_shift()`'s own comment, and see `assets.lox`'s `get_x_offset()`): `-walk_shift(this)`
  cancels the sub-byte pixel offset baked into whichever shift sprite is chosen (this port blits at
  an arbitrary x, so it has to undo the byte-alignment the ROM's own blitter relied on), and
  `+lib.get_x_offset(name)` adds that sprite's own fixed per-variant ROM header offset (0 for every
  right-facing shift sprite, +8 for the narrower left-facing ones). Dropping either one alone breaks
  a direction — this was a real, playtested bug (walking left was jerky, right wasn't) fixed by
  finding both corrections were needed together, not by picking one. `is_dead()`/`state_dying` gate
  Game's own death/respawn timer specifically; `is_hidden()` (also true during `state_boarding`,
  entered via `board()`) is the broader check `game.lox` uses for draw/input gating — see
  `rocket.lox`'s own `state_on_pad()` for the one caller of `board()`.
- `jetman_controller.lox` — `Controller`: polls input once per frame into `left`/`right`/`thrust`/
  `hover`/`fire` flags (`fire` edge-triggered, matching `defender/player/controller.lox`'s own
  convention for a discrete "one shot per press" action; the rest level-triggered). The only
  keyboard poll during play. Which physical key maps to which action comes from
  `data/keybinds.json` (action name -> key name, e.g. `"left": "Q"`), resolved into actual
  `win.KEY_*` constants lazily on the first `update(win)` call via `key_const()`'s name table
  (Controller is built before Game has a window to resolve constants against). `hover` isn't a
  movement key in the ROM sense -- holding it zeroes Jetman's vertical velocity for the tick
  (`fly_vertical()` in `jetman.lox`), mirroring `JetmanVelSetYMin` ($7438), which the skool notes is
  itself only ever reached as an "undocumented hover key" side effect of keyboard-row-scan timing on
  real hardware ($7400) -- this port binds that same effect deliberately.
- `rocket.lox` — `Rocket`: `state_on_pad`/`state_taking_off`/`state_landing`, mirroring the skool's
  own move values $09/$0A/$0B. Owns `modules` (1..3), `fuel` (0..6), the flame animation, and
  `row_ink()` (`UpdateRocketColour`, $66FC: banding only once `modules==3`; bottom `fuel*8` pixels
  magenta, rest white; a full tank flashes the whole stack instead). Colours by continuous pixel-
  space math (a row's own midpoint vs. the fuel boundary Y), not a discrete per-tile "cell index" —
  `ROCKET_PAD_Y` (183) isn't a multiple of 8, so a 16px module tile's sprite actually straddles 3
  attribute rows, not a clean 2, and a discrete cell index left one of those uncorrected (a real,
  playtested bug: visible white gaps/"stripes" breaking up what should be a solid band). `draw()`
  blits every tile's *pixels* in one pass, then colours every attribute row the whole stack spans in
  a **separate** pass after — interleaving them let a later tile's own plain-white blit_sprite call
  stomp an earlier tile's already-correct override at their shared/overlapping row.
  Reaching `FUEL_PODS_NEEDED` (6) does **not** launch by itself -- `state_on_pad(r, jetman, game)`
  polls every tick for fuel>=6 AND Jetman actually touching the rocket (`near_jetman()`, a port of
  `AlienCollision` $6DE9 with the rocket's own `height` field in its asymmetric Y test), matching
  `RocketUpdate`'s ($66D0) own per-tick check. On a genuine touch, `jetman.board()` hides him (he's
  boarding, not dying -- see `jetman.lox`'s `is_hidden()`) and `game.lives` gets a bonus life
  ($66f5), *then* `enter_taking_off()` fires. `state_landing()` respawns Jetman once the rocket is
  back on the pad (no life lost -- that's the bonus he was given on the way in, not a death).
  Reaching `ROCKET_LAUNCH_TOP_Y` loops back to `state_landing` rather than truly advancing a level
  (full level cycling — new alien sets, a fresh screen — is out of scope), so the pad/build/launch
  cycle repeats indefinitely on the same screen instead of stopping after one. `this.level` DOES
  mirror the ROM's own per-cycle reset cadence though: `state_taking_off()` increments it (matching
  `RocketTakeoff`'s own `inc (hl)` on $5DF0) and only resets `modules` to 1 (re-seeding both module
  `Item` slots via `item.init_module()`) when `level%4==0` — `RocketTakeoff`'s reached-top branch
  ($66A3-$66B1) only ever resets fuel unconditionally; modules only resets via `RocketReset`
  ($60A7), which `LevelNew` ($6083) calls *only* on a level number that's a multiple of 4 ("A new
  Rocket is generated every 4 levels, otherwise it's a normal fuel collecting level") —
  `RocketModulesReset` ($6624, called every cycle) only clears item/alien/animation slots, never the
  rocket's own state. A previous version reset modules to 1 on every single cycle instead of every
  4th (a real, playtested bug) — which also happened to mask a separate bounds-check bug in the
  colouring loop above (`row_cy`/`cxi` were never clamped to the screen's attribute grid; a fully-
  built 3-module stack legitimately extends above row 0 near the top of a real launch, only reached
  once modules stopped force-resetting to 1 on every cycle) — now fixed alongside it.
- `item.lox` — `Item`: one class for rocket modules, fuel pods and collectibles, distinguished by
  `kind`. States `state_falling`/`state_carried`/`state_docking`/`state_idle`. **Exactly two `Item`
  instances exist** (`game.lox`'s `rocket_item`/`collectible_item`), matching the skool's own
  `$5D38`/`$5D40` RAM slots, each doing double duty: `RocketReset` ($60A7) copies 24 bytes — the
  rocket record plus *both* the top-module and middle-module templates — into `$5D30` in one shot,
  so `$5D38` (the address `ItemNewFuelPod`/`CollectRocketItem` call "rocket module object") starts
  out holding the **top** module and `$5D40` (`ItemNewCollectible`'s own "collectible object")
  starts out holding the **middle** module — confirmed against actual gameplay footage: all three
  rocket pieces (base + both modules, on separate platforms) are visible from frame one, not
  delivered one at a time. `init_module()` seeds both at `Game` construction, then again from
  `rocket.lox`'s `state_taking_off()` every 4th launch cycle (see that file's own `level` comment) —
  not a spawn gate in either case. Each slot only becomes available for its *other* job (fuel pod /
  collectible respectively, via `spawn_fuel_pod`/`spawn_collectible`, called by `spawner.lox`) once
  its pre-seeded module has actually been delivered, since delivery despawns the same `Item`
  instance those functions later reuse — don't add a third "spawn a module" path expecting it to
  coexist with a fourth pickup kind; there are only ever two module deliveries per build cycle.
  `spawn_fuel_pod`/`spawn_collectible` gate on `jetman.is_hidden()`, not `is_dead()` — checking
  death alone let fuel/collectibles start spawning while Jetman was still boarding a launched
  rocket (hidden but not literally dead), before he'd actually respawned.
  `spawn_fuel_pod()` picks a random column from `item_drop_columns`, same as `spawn_collectible()` —
  confirmed `ItemNewFuelPod` ($65F9) calls the exact same `ItemCalcDropColumn` ($65DB) routine
  `ItemNewCollectible` does; `default_fuel_pod`'s own `"x"` field is just the ROM's zeroed RAM
  template value (0) before `ItemNewFuelPod` ever runs, not a real spawn position.
- `alien.lox` — `Alien` + 6 `state_*` functions covering all 8 ROM alien types: a fixed 6-slot pool,
  allocated once and reused (never reallocated — see the root `CLAUDE.md`'s per-frame allocation
  discipline). `ALIEN_TYPES` (`item_level_object_types` $6A2D) maps `level % 8` to a
  {sprite(s), animation speed, `state_*` function}: Meteor → Squidgy Alien → Sphere Alien → Jet
  Fighter → UFO → Crossed Space Ship → Space Craft → Frog Alien, then repeats. Space Craft (level 6)
  and Frog Alien (level 7) have their own sprites (`alien_sprite_table` $690E) but reuse Meteor's and
  UFO's own `state_*` function respectively — confirmed both movement-code reuses directly against
  the ROM's jump-table entries, not assumed from the type names. `spawner.lox` calls `spawn_alien(...,
  game.rocket.level)`, which picks the entry and resets that type's own extra fields (see each
  `state_*` function's own header comment for what it tracks and which ROM routine it's from).
  Kill order matches the ROM for every type: laser hit, then (for Meteor/Space Craft/Jet Fighter
  only — see below) platform collision, then Jetman proximity. Bare Jetman contact is a **mutual**
  kill for every type — the skool's own alien-side handler only ever destroys the alien with no
  points, but the point of touching an alien at all is that it costs Jetman too, so this port kills
  both (`contact_kill()`). Three movement shapes, confirmed against three different jump-table
  entries each: **single-path** (Meteor/Space Craft, Jet Fighter while diving) dies outright on
  platform contact; **bounce/patrol** (Squidgy, Sphere, Crossed Ship) reverses direction on platform
  contact instead of dying — no platform-kill at all; **chaser** (UFO, Frog Alien) accelerates toward
  Jetman on each axis independently (a plain float ramp standing in for the ROM's 4-bit
  fixed-point speed nibble — see `UFO_ACCEL`/`UFO_MAX_SPEED`'s own comment for the derivation), also
  no platform-kill. Jet Fighter is the one type with two death paths: `jetfighter_self_destruct()`
  (lifetime countdown expiry, a laser hit, crossing the top-of-screen bound, or *any* platform
  contact — dormant or diving alike, both share the ROM's own movement tail) scores normally but
  skips the explosion entirely (no sprite, and its "explosion" sound is `SfxThrusters` reused, per
  the ROM's own comment on $6450) — only a direct Jetman hit goes through the normal
  `contact_kill()`. `hide()` is a *plain* deactivation (no score/sound/explosion) — `rocket.lox`'s
  `state_on_pad()` calls it on every alien the instant Jetman boards a launching rocket, mirroring
  `RocketModulesReset`'s ($6624) own raw clear of every alien slot, though the ROM only actually runs
  that at the *top* of the ascent (going into the descent), not at boarding — since Jetman is
  hidden/uninteractable for the whole round trip regardless, this port clears existing aliens a bit
  earlier so the screen stays quiet the entire time, not just partway.
- `laser.lox` — `LaserPool`: 4 preallocated beam slots. A beam is a **rigid 3-zone ensemble** —
  solid leading tip (`SOLID_LEN`), then a zone of `DASH_COUNT` short dashes with short gaps, then a
  trailing zone of `DOT_COUNT` very short dashes with longer gaps — all one colour, fixed in
  position relative to each other (`MARKS`, built once as distance-from-`front_x` pairs), each zone
  exactly `CELL_LEN` (4 character cells, 32px), `ENSEMBLE_LEN` 96px total. It's a **fixed-size
  object that reveals itself as it travels**, per the user's own description: `draw()` clamps every
  `MARKS` entry to the beam's own `traveled` distance, so the ensemble visibly grows from nothing up
  to full length over its first 96px of flight rather than rendering instantly, and — also per the
  user's own correction — it never shrinks back once shown: `update()` just deactivates a beam
  outright (no lingering state) the instant its front hits something, leaves the screen, or its own
  random max-range countdown runs out; an earlier version modelled the ROM's trailing-pulse
  catch-up ($6FC5) as a gradual tail-first collapse once the front stopped, but that read as the
  whole shot "extending then retracting", not how it should look. What's still real, confirmed ROM
  fact: the front moves a fixed step/tick ($6fd8/$6fd9 confirm 8px/ROM-tick, but `FRONT_STEP` is
  tuned down to 4 for feel — this port runs every actor every engine tick, unlike the ROM's
  one-jump-table-entry-per-50Hz-interrupt scheduling, so a literal 8px/tick reads much faster here;
  same deviation as `main.lox`'s own `TARGET_FPS` comment) and its own random max-range countdown
  (`FRONT_RANGE_MIN/MAX`, ROM: `(random&$38)|$84`). Colour is a fresh **random** pick from
  `laser_beam_colours` ($6FB2, decoded once into `BEAM_COLOURS`) every fire, applied uniformly
  across the whole ensemble. `check_hit(x, y)` tests the front (tip), not "pulse #2" (an earlier
  pass's finding for the ROM's own hit-test target, which has no clean equivalent in this
  fixed-zone model) — a gameplay-legible simplification, with an asymmetric X window
  (`HIT_DX_AHEAD`/`HIT_DX_BEHIND`) approximating $6E33-$6E53's own arithmetic. `plot_clamped`
  bounds-checks every `Display.plot` call — unlike `blit_sprite`, it doesn't clip itself.
  `fire(jetman, lib)` takes `lib` specifically to look up the gun position correctly: Jetman never
  mirrors his own sprite (separate left/right art, see `jetman.lox`'s `current_sprite_name()`), so
  `jetman.x` is always his sprite's LEFT edge — his gun when facing left, but his BACK when facing
  right; fixed by offsetting by the actual current sprite's own width when facing right (confirmed
  against `LaserBeamInit`/`LaserBeamShootRight`, $6F70/$6FB6, whose own C register ends up well to
  the right of Jetman's base X in that case).
- `explosion.lox` — `Explosion`: the shared 3-frame small/medium/large *growing* cycle
  (`explosion_sprite_table`, $68D8), used for alien kills, Jetman's own death, and Jetman's
  platform-liftoff puff (`jetman.lox`'s `launched_this_tick`, set on `state_walk()`'s WALK->FLY
  transition — mirrors `jetmanLeavePlatform`, $757F, which runs the *same* shared animation object
  used for kills, not a landing effect). Colour re-picks randomly from {red, magenta, yellow, white}
  (all bright) on every tick a frame is active, not once per explosion — matches `AnimateExplosion`
  ($687A)'s own per-tick `(random & 7) | $42`. A small pool (`game.lox`'s `EXPLOSION_COUNT`,
  `Game.spawn_explosion()`), not one shared object like the ROM's.
- `spawner.lox` — `Spawner`: the ROM's `NewActor` ($6971). Advances a timer and calls
  `item.lox`'s own `spawn_fuel_pod`/`spawn_collectible` on the ROM's timing (`(255-timer)%16==0` /
  `timer%128==0`) — **not** a module spawn; there isn't one (see `item.lox`'s own entry above).
  Alien spawning has no ROM-equivalent cadence to match (aliens aren't item-slot-gated), so its
  interval is this port's own tuning; the *type* spawned, though, is ROM-accurate —
  `spawn_alien_if_free()` passes `g.rocket.level` straight into `alien.lox`'s `spawn_alien()`, which
  picks that level's entry from `ALIEN_TYPES`. Confirmed `NewActor`'s own gate ($69BE-$69C7) applies
  equally to alien spawns as to fuel-pod/collectible ones — all three require Jetman's direction to
  be FLY or WALK — so `spawn_alien_if_free()` is also gated on `!g.jetman.is_hidden()`, matching the
  other two (a real, playtested bug: aliens kept spawning while Jetman was boarding a launching
  rocket).
- `hud.lox` — `draw_static`/`draw`: score and lives, along the top strip (rows 0-7) rather than a
  below-play row like manic_miner's — Jetpac's platforms already use the whole 192px screen height,
  so there's no spare strip below play. `draw_lives` blanks its icon strip before redrawing every
  tick (a preallocated blank buffer, not a fresh allocation) so a lost life is actually erased.
- `game_sound.lox` — `Sound`: wraps `modules/sound_mgr.SoundManager` with one named method per cue
  (`thrust(y)`, `rocket_build()`, `pickup_fuel()`, `pickup_item()`, `laser()`, `explode_alien()`,
  `explode_player()`), a `mute` constructor flag, `update()`, `close()`. `thrust(y)` buckets Y into
  one of 8 pitch samples and uses `SoundManager.play_if_not`, so holding it doesn't restart the
  clip every tick (the port's own ~200ms-per-retrigger stand-in for the ROM's actual ~15ms-per-tick
  beeper toggle — document this deviation again if the bucket count or retrigger behavior changes).
  **`thrust()`/`stop_thrust()` belong to `rocket.lox`'s `state_taking_off`/`state_landing`** (its
  real ROM home, $6690/$66B4's own per-tick `SfxThrusters` call, $67B6) — despite the name, it's
  never played for Jetman's own jetpack (`JetmanFlyThrust`/`JetmanFalling`, $739E/$7412, call no
  sound routine at all); an earlier version of this port had it wired into `jetman.lox`'s
  `fly_vertical()` instead, producing a continuous tone on every held thrust that was never part of
  the original game — a real, playtested bug, now fixed. The two death cues share an exclusivity
  group so an alien kill can't talk over Jetman's own.
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
  since the last redraw would otherwise leave it permanently damaged. `blocks_point(x, y)` is a
  simple point-in-tile-row test, used by `laser.lox` to kill a beam that's flown into a platform.

**Offline tools** (not run as part of the game):
- `skool.lox` — `Skool`: parses `jetpac.skool` into a flat 65536-entry memory image
  (`mem[addr] == -1` means "never disassembled" — a read raises rather than yielding a plausible
  zero) plus `labels`/`addr_to_label` tables. Game-independent; would move to `modules/` if a second
  disassembly is ever ported. **Actor sprites are stored bottom-row-first, not top-down** — see
  `extract_jetpac.lox`'s own header on `reverse_rows()` before touching sprite extraction; this
  bit the first pass here (screenshots showed Jetman/rocket/items upside down while the font and
  platform tiles, which use a different ROM draw routine, looked fine).
- `extract_jetpac.lox` — `odlox.exe extract_jetpac.lox jetpac.skool`. Writes
  `assets/jetpac_sprites.json` (54 sprites — the 8 alien types' own sprites among them:
  `alien_sprite_table` $690E has 2 frame pointers per level-slot, but only Meteor and Squidgy/Sphere
  Alien genuinely animate 2 frames each; the rest point both entries at the same sprite, so
  `emit_alien_sprites()` only emits one for those), `assets/font_sprites.json` (60 glyphs, ASCII 32-91),
  `data/jetpac_static.json` (platforms, item drop columns, default actor states, collectible
  sprite-table offsets) — every value read from the skool by label, none typed in by hand. Rerun
  after any sprite/static-data change and diff the JSON (`git diff --exit-code`); a diff limited to
  key *order* (not values) is the known `dict.keys()` iteration-order non-determinism, not a
  regression — check values, not raw text, if that comes up again. `emit_byte_sprite()` also captures
  each Actor sprite's own header[0] byte as `"x_offset"` (see `assets.lox`'s `get_x_offset()`) —
  0 for nearly everything but real for Jetman's own left-facing walk/fly shift variants. `JETMAN_POSES`'
  own `shift_order` matters: `jetman_sprite_table` ($76C5) lists each **left**-facing pose's 4 shift
  entries in *reverse* order (label 1 = the shift6 slot, label 4 = shift0) while right-facing poses
  list theirs straight across (label 1 = shift0) — confirmed directly against the table's own bytes,
  not assumed from label naming. Get this backwards and every left-facing walk/fly sprite silently
  points at the wrong shift's pixel data.
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
- `assets.lox` — diverged from `manic_miner`'s copy: `SpriteAssets` also tracks each sprite's
  `x_offset` (from its JSON entry, default 0) alongside its pixel data, via `get_x_offset(name)` --
  see `jetman.lox`'s `draw()` for the one consumer.

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
