# Missing type annotations in lox_examples/

802 function/method/lambda definitions across 88 files; **62** still have a gap
(42 unannotated parameters, 20 value-returning definitions with no `-> T`), down from 601
(1046 parameters, 172 returns). Every remaining gap is a value the annotation syntax cannot
name; each is listed below under the reason.

Not counted: `*rest` params (grammar has no annotation slot), `__init__` return types, a
missing `->` on a definition with no `return <expr>` (there is no nil/void return type), and
functions declared with `fun` (3d_balls_physics_shaders.lox, cobweb-bifurc.lox, kaleido.lox).

## Remaining gaps

### Function values (no function-type syntax)

Returned closures and callback parameters.

- defender/game/bonus.lox: L66 `BonusDisplay.on_caught`, L72 `BonusDisplay.on_saved` (return)
- defender/game/entity_mgr.lox: L111 `EntityMgr.on_level_finish`, L117 `EntityMgr.on_level_start` (return)
- defender/game/event.lox: L9 `EventDispatcher.on`, L18 `EventDispatcher.off` (`listener`)
- defender/game/game_controller.lox: L99 `on_lander_killed`, L105 `on_player_die`, L111 `on_player_start` (return)
- defender/game/game_sound.lox: L102 `GameSound.handler_for`, L109 `GameSound.on_bullet_fire` (return)
- defender/game/score.lox: L43 `Score.handler_for` (return)
- defender/main.lox: L35 `make_event_logger` (return)
- defender/world/mountains.lox: L34 `Mountain.on_level_finish`, L40 `Mountain.on_level_start` (return)
- fireworks.lox: L28 `init` (return)
- game_of_life.lox: L423 `draw_random_line`, L444 `draw_random_box`, L460 `draw_random_block`,
  L473 `randomise_with` (`value_fn`); L517 `Strategy.__init__` (`randomise_fn`)
- game_of_life_multi_zone.lox: L191 `add_param_field` (`apply`)

### Event payloads of any type

`EventDispatcher.emit` passes whatever the emitter supplies (an entity, a vec2, or nil).

- defender/game/event.lox: L30 `EventDispatcher.emit` (`data`)
- defender/game/entity_mgr.lox: L112, L118 `handler` (`e`)
- defender/game/game_controller.lox: L100, L106, L112 `handler` (`e`)
- defender/game/game_sound.lox: L103 `on_event` (`data`)
- defender/main.lox: L36 `log` (`data`)
- defender/world/mountains.lox: L35, L41 `handler` (`e`)
- jetpac/extract_jetpac.lox: L282 `write_json` (`value`: a list or a dict)

### float_array values (no type name)

- game_of_life_multi_zone.lox: L222 `set_wrapped_val`, L228 `draw_random_line`, L248 `draw_random_box`,
  L263 `draw_random_block` (`arr`)
- jetpac/assets.lox, manic_miner/assets.lox: L10 `decode_pixel_rows`, L30 `decode_byte_rows`,
  `SpriteAssets.get` (return)
- jetpac/display.lox: L160, manic_miner/display.lox: L153 `Display.blit_sprite` (`sprite`)
- manic_miner/cavern.lox: L374 `Cavern.guardian_hit` (`willy_img`)
- manic_miner/willy.lox: L175 `draw_footprint` (`img`)

### The `Sound` class

jetpac/game_sound.lox and manic_miner/game_sound.lox each declare `class Sound`, but `Sound`
resolves to the native sound type, which takes precedence over class names.

- jetpac: alien.lox L109, game.lox L52, item.lox L74, jetman.lox L66, rocket.lox L92 (`sound`)
- manic_miner: demo.lox L128, game.lox L411, intro.lox L96, willy.lox L85 (`sound`)

### Game or Demo

manic_miner/game.lox's HUD helpers are called with both a `Game` and a `Demo` (from
demo.lox), and the two classes share no superclass.

- manic_miner/game.lox: L100 `draw_name_row`, L108 `draw_score_row`, L119 `draw_oxygen_row_background`,
  L133 `draw_oxygen_bar_fill`, L164 `draw_static_hud`, L174 `draw_lives` (`g`)

## Unresolved class annotations

Some annotations name a class that cannot be imported without creating an import cycle (the
runtime rejects circular imports). The name is written for documentation; the checker treats it
as dynamic.

- jetpac: `Game` and `Score` (game.lox imports every other jetpac module), used in alien.lox,
  hud.lox, rocket.lox, spawner.lox; `Rocket` in item.lox (rocket.lox imports item).
