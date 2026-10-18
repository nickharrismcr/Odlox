# Missing type annotations in lox_examples/

802 function/method/lambda definitions across 88 files; **601** have at least one gap.
1046 unannotated parameters; 172 value-returning definitions with no `-> T`.

Not counted: `*rest` params (grammar has no annotation slot), `__init__` return types, and a missing `->` on a definition with no `return <expr>` (there is no nil/void return type).

## Per-file summary

| File | Defs | With gaps | Untyped params | Missing return |
|---|---|---|---|---|
| manic_miner/willy.lox | 33 | 30 | 77 | 1 |
| btree/btree.lox | 31 | 28 | 31 | 18 |
| manic_miner/game.lox | 26 | 23 | 36 | 0 |
| manic_miner/cavern.lox | 29 | 22 | 53 | 3 |
| defender/game/game_controller.lox | 24 | 21 | 27 | 3 |
| defender/player/player.lox | 22 | 20 | 30 | 2 |
| jetpac/extract_jetpac.lox | 18 | 18 | 36 | 7 |
| defender/npc/lander.lox | 22 | 18 | 19 | 1 |
| game_of_life.lox | 17 | 17 | 26 | 5 |
| jetpac/jetman.lox | 22 | 17 | 31 | 4 |
| defender/npc/human.lox | 23 | 17 | 18 | 1 |
| tile_planes.lox | 19 | 16 | 30 | 5 |
| jetpac/alien.lox | 17 | 16 | 70 | 1 |
| jetpac/skool.lox | 16 | 16 | 31 | 8 |
| cube_stack_fly2.lox | 20 | 15 | 20 | 10 |
| game_of_life_multi_zone.lox | 14 | 14 | 21 | 1 |
| jetpac/rocket.lox | 16 | 13 | 27 | 1 |
| grids.lox | 16 | 12 | 19 | 6 |
| manic_miner/display.lox | 15 | 12 | 38 | 0 |
| jetpac/display.lox | 15 | 12 | 38 | 0 |
| jetpac/item.lox | 13 | 12 | 40 | 1 |
| defender/game/entity_mgr.lox | 37 | 12 | 10 | 6 |
| ascii_city.lox | 12 | 11 | 25 | 10 |
| manic_miner/demo.lox | 11 | 10 | 14 | 0 |
| manic_miner/extract_cavern.lox | 10 | 10 | 25 | 8 |
| jetpac/laser.lox | 11 | 10 | 13 | 4 |
| defender/game/bonus.lox | 13 | 10 | 9 | 2 |
| defender/npc/npc.lox | 14 | 9 | 13 | 0 |
| box2d_demo.lox | 10 | 8 | 10 | 4 |
| fireworks.lox | 7 | 7 | 13 | 3 |
| mandelbox_shader.lox | 7 | 7 | 11 | 7 |
| snakes.lox | 11 | 7 | 13 | 3 |
| jetpac/assets.lox | 8 | 7 | 7 | 4 |
| 3d_balls_physics_shaders.lox | 6 | 6 | 8 | 2 |
| manic_miner/assets.lox | 7 | 6 | 6 | 4 |
| jetpac/platform.lox | 6 | 6 | 11 | 3 |
| defender/world/mountains.lox | 11 | 6 | 4 | 2 |
| defender/npc/baiter.lox | 6 | 6 | 6 | 0 |
| manic_miner/intro.lox | 8 | 5 | 4 | 3 |
| jetpac/game.lox | 8 | 5 | 6 | 0 |
| manic_miner/sna.lox | 4 | 4 | 6 | 4 |
| jetpac/hud.lox | 4 | 4 | 4 | 0 |
| defender/game/fx.lox | 4 | 4 | 5 | 0 |
| defender/game/game_sound.lox | 12 | 4 | 3 | 2 |
| defender/game/score.lox | 7 | 4 | 3 | 1 |
| kaleido.lox | 5 | 3 | 7 | 0 |
| manic_miner/font.lox | 3 | 3 | 14 | 1 |
| manic_miner/game_sprite.lox | 5 | 3 | 4 | 0 |
| jetpac/explosion.lox | 6 | 3 | 2 | 2 |
| jetpac/extract_sfx.lox | 3 | 3 | 2 | 2 |
| jetpac/font.lox | 3 | 3 | 14 | 1 |
| jetpac/jetman_controller.lox | 4 | 3 | 4 | 1 |
| jetpac/spawner.lox | 4 | 3 | 3 | 1 |
| defender/game/event.lox | 4 | 3 | 3 | 0 |
| defender/npc/bullet.lox | 7 | 3 | 2 | 1 |
| manic_miner/extract_start_screen.lox | 2 | 2 | 6 | 2 |
| manic_miner/spectrum_attr.lox | 2 | 2 | 3 | 2 |
| manic_miner/spectrum_screen.lox | 2 | 2 | 4 | 2 |
| jetpac/game_sprite.lox | 4 | 2 | 3 | 0 |
| jetpac/spectrum_attr.lox | 2 | 2 | 3 | 2 |
| defender/main.lox | 2 | 2 | 1 | 1 |
| defender/world/collide.lox | 3 | 2 | 2 | 0 |
| defender/game/text.lox | 7 | 2 | 2 | 0 |
| defender/npc/bomber.lox | 2 | 2 | 2 | 0 |
| defender/npc/pod.lox | 3 | 2 | 2 | 0 |
| defender/npc/swarmer.lox | 2 | 2 | 2 | 0 |
| defender/player/laser.lox | 12 | 2 | 2 | 0 |
| donut.lox | 2 | 1 | 2 | 0 |
| mandel_shader.lox | 1 | 1 | 1 | 1 |
| triangle3_batch_demo.lox | 1 | 1 | 1 | 1 |
| manic_miner/extract_font.lox | 1 | 1 | 1 | 1 |
| manic_miner/willy_controller.lox | 2 | 1 | 1 | 0 |
| jetpac/game_sound.lox | 11 | 1 | 1 | 0 |
| defender/world/stars.lox | 6 | 1 | 0 | 1 |
| defender/game/levels.lox | 2 | 1 | 1 | 0 |
| defender/game/radar.lox | 2 | 1 | 3 | 0 |
| defender/npc/bullets.lox | 5 | 1 | 1 | 0 |
| cobweb-bifurc.lox | 0 | 0 | 0 | 0 |
| julia.lox | 0 | 0 | 0 | 0 |
| textured_batch_demo2.lox | 0 | 0 | 0 | 0 |
| manic_miner/dump_sprites.lox | 0 | 0 | 0 | 0 |
| manic_miner/game_sound.lox | 13 | 0 | 0 | 0 |
| manic_miner/main.lox | 0 | 0 | 0 | 0 |
| jetpac/dump_sprites.lox | 0 | 0 | 0 | 0 |
| jetpac/main.lox | 0 | 0 | 0 | 0 |
| defender/config.lox | 2 | 0 | 0 | 0 |
| defender/world/camera.lox | 3 | 0 | 0 | 0 |
| defender/player/controller.lox | 2 | 0 | 0 | 0 |

## Details

### lox_examples/3d_balls_physics_shaders.lox

- L128 `MovingObject.__init__` — params: id, size, color
- L144 `MovingObject.get_collision_radius` — return type (returns a value)
- L149 `MovingObject.should_explode` — return type (returns a value)
- L154 `MovingObject.explode` — params: world
- L163 `MovingObject.apply_explosion_force` — params: world, explosion_pos, explosion_force
- L209 `MovingObject.add_shadow` — params: shadow_batch

### lox_examples/ascii_city.lox

- L73 `floor_i` — params: v; return type (returns a value)
- L79 `frac` — params: v; return type (returns a value)
- L83 `mod_floor` — params: a, b; return type (returns a value)
- L90 `hash01` — params: x, y, seed; return type (returns a value)
- L95 `is_street` — params: m; return type (returns a value)
- L99 `cell_height` — params: mx, my; return type (returns a value)
- L114 `fog` — params: t; return type (returns a value)
- L121 `to_shade` — params: lum; return type (returns a value)
- L128 `ground_lum` — params: wx, wy; return type (returns a value)
- L145 `wall_lum` — params: ndl, u, z, t, mx, my; return type (returns a value)
- L161 `render_frame` — params: pos_x, pos_y, cam_z, yaw, pitch

### lox_examples/box2d_demo.lox

- L39 `to_screen` — params: pos, offset_x; return type (returns a value)
- L50 `Scene1.__init__` — params: offset_x
- L140 `Scene1.regular_remaining` — return type (returns a value)
- L144 `Scene1.draw` — params: win
- L169 `Scene2.__init__` — params: offset_x
- L194 `Scene2.add_ramp` — params: cx, cy, half_len, angle; return type (returns a value)
- L236 `Scene2.is_done` — return type (returns a value)
- L240 `Scene2.draw` — params: win

### lox_examples/btree/btree.lox

- L45 `write_text` — params: path, text
- L54 `read_text` — params: path; return type (returns a value)
- L61 `split_lines` — params: text; return type (returns a value)
- L69 `read_lines` — params: path; return type (returns a value)
- L74 `data_lines` — params: lines; return type (returns a value)
- L86 `parse_ints` — params: text; return type (returns a value)
- L102 `Node.__init__` — params: leaf
- L112 `Node.position` — params: key; return type (returns a value)
- L120 `Node.overfull` — return type (returns a value)
- L127 `Node.split` — return type (returns a value)
- L148 `Index.__init__` — params: file, key_parts
- L165 `Index.key_of` — params: line; return type (returns a value)
- L175 `Index.add_row` — params: row
- L188 `Index.add` — params: key, row
- L202 `Index.insert` — params: node, key, row; return type (returns a value)
- L233 `Index.find_rows` — params: key; return type (returns a value)
- L252 `Index.get` — params: key; return type (returns a value)
- L266 `Index.in_order` — return type (returns a value)
- L271 `Index.height` — return type (returns a value)
- L290 `Index.check` — params: node, lo, hi, depth, leaf_depth
- L332 `Index.save` — params: base
- L381 `static Index.open` — params: base; return type (returns a value)
- L439 `Index.key_len` — return type (returns a value)
- L451 `Index.dump_node` — params: node, indent
- L465 `InOrderIter.__init__` — params: index
- L473 `InOrderIter.__iter__` — return type (returns a value)
- L484 `InOrderIter.push_left` — params: node
- L496 `InOrderIter.__next__` — return type (returns a value)

### lox_examples/cube_stack_fly2.lox

- L63 `createColoredTextures` — params: count; return type (returns a value)
- L114 `even` — params: value; return type (returns a value)
- L132 `Batches.get_random_batch` — return type (returns a value)
- L146 `Batches.draw` — params: cam
- L157 `Cube.__init__` — params: position
- L160 `Cube.add_to_batch` — params: batch; return type (returns a value)
- L170 `Stack.__init__` — params: gridX, gridZ, height, cubeBatches
- L196 `Grid.__init__` — params: size, cubeBatch
- L213 `Grid.isValidStreetPosition` — params: gridX, gridZ; return type (returns a value)
- L221 `Grid.isAtBoundary` — params: gridX, gridZ; return type (returns a value)
- L236 `Controller.__init__` — params: grid
- L265 `Controller.gridToWorld` — params: gridPos; return type (returns a value)
- L273 `Controller.distance_to_edge` — params: gridPos, direction; return type (returns a value)
- L401 `Controller.directionToAngle` — params: direction; return type (returns a value)
- L405 `Controller.getCamera` — return type (returns a value)

### lox_examples/defender/game/bonus.lox

- L19 `Bonus.update` — params: player
- L25 `Bonus.draw` — params: cam
- L34 `BonusDisplay.__init__` — params: img250, img500
- L58 `BonusDisplay.attach` — params: events
- L62 `BonusDisplay.on_caught` — return type (returns a value)
- L63 `BonusDisplay/handler` — params: h
- L68 `BonusDisplay.on_saved` — return type (returns a value)
- L69 `BonusDisplay/handler` — params: h
- L75 `BonusDisplay.update` — params: player
- L95 `BonusDisplay.draw` — params: cam

### lox_examples/defender/game/entity_mgr.lox

- L29 `EntityMgr.__init__` — params: config
- L106 `EntityMgr.on_level_finish` — return type (returns a value)
- L107 `EntityMgr/handler` — params: e
- L112 `EntityMgr.on_level_start` — return type (returns a value)
- L113 `EntityMgr/handler` — params: e
- L128 `EntityMgr.get_all` — return type (returns a value)
- L131 `EntityMgr.add_to_queue` — params: entity
- L184 `EntityMgr.pick_a_human` — return type (returns a value)
- L204 `EntityMgr/check` — params: e; return type (returns a value)
- L218 `EntityMgr/is_human` — params: e; return type (returns a value)
- L393 `EntityMgr.check_collisions` — params: player, cam
- L444 `EntityMgr.draw` — params: g, cam

### lox_examples/defender/game/event.lox

- L9 `EventDispatcher.on` — params: listener
- L18 `EventDispatcher.off` — params: listener
- L30 `EventDispatcher.emit` — params: data

### lox_examples/defender/game/fx.lox

- L13 `explosion_init` — params: p
- L22 `explosion_update` — params: p
- L41 `explosion` — params: emitters
- L47 `draw` — params: emitters, cam

### lox_examples/defender/game/game_controller.lox

- L58 `GameController.__init__` — params: cfg, entities, ship, ship_img, smartbomb_img
- L95 `GameController.on_lander_killed` — return type (returns a value)
- L96 `GameController/handler` — params: e
- L101 `GameController.on_player_die` — return type (returns a value)
- L102 `GameController/handler` — params: e
- L107 `GameController.on_player_start` — return type (returns a value)
- L108 `GameController/handler` — params: e
- L122 `GameController.update` — params: input
- L128 `GameController.draw` — params: font
- L142 `GameController.draw_intro` — params: font
- L203 `draw_centered` — params: font
- L207 `enter_intro` — params: g
- L211 `state_intro` — params: g, input
- L223 `enter_level_start` — params: g
- L255 `state_level_start` — params: g, input
- L259 `enter_level` — params: g
- L263 `state_level` — params: g, input
- L269 `enter_level_finish` — params: g
- L278 `state_level_finish` — params: g, input
- L286 `enter_game_over` — params: g
- L291 `state_game_over` — params: g, input

### lox_examples/defender/game/game_sound.lox

- L90 `GameSound.attach` — params: events, cam
- L100 `GameSound.handler_for` — return type (returns a value)
- L101 `GameSound/on_event` — params: data
- L107 `GameSound.on_bullet_fire` — return type (returns a value)

### lox_examples/defender/game/levels.lox

- L27 `apply_level` — params: cfg

### lox_examples/defender/game/radar.lox

- L27 `Radar.draw` — params: cam, entities, mountains

### lox_examples/defender/game/score.lox

- L22 `Score.__init__` — params: font
- L33 `Score.attach` — params: events
- L40 `Score.handler_for` — return type (returns a value)
- L41 `Score/on_kill` — params: entity

### lox_examples/defender/game/text.lox

- L15 `Font.__init__` — params: img
- L55 `ColourCycle.__init__` — params: palette

### lox_examples/defender/main.lox

- L35 `make_event_logger` — return type (returns a value)
- L36 `log` — params: data

### lox_examples/defender/npc/baiter.lox

- L10 `Baiter.__init__` — params: img
- L27 `state_wait` — params: e
- L34 `enter_materialize` — params: e
- L44 `state_materialize` — params: e
- L54 `enter_chase` — params: e
- L62 `state_chase` — params: e

### lox_examples/defender/npc/bomber.lox

- L14 `Bomber.__init__` — params: img
- L24 `state_bomb` — params: e

### lox_examples/defender/npc/bullet.lox

- L7 `Bullet.__init__` — params: img
- L15 `Bullet.position` — return type (returns a value)
- L41 `Bullet.draw` — params: cam

### lox_examples/defender/npc/bullets.lox

- L33 `BulletPool.draw` — params: cam

### lox_examples/defender/npc/human.lox

- L15 `Human.__init__` — params: img
- L38 `Human.position` — return type (returns a value)
- L48 `Human.grab` — params: carrier
- L57 `Human.catch_by` — params: player
- L96 `Human.draw` — params: cam
- L107 `draw_normal` — params: e, cam
- L114 `draw_dispersed` — params: e, cam
- L123 `state_walk` — params: e
- L130 `enter_grabbed` — params: e
- L136 `state_grabbed` — params: e
- L145 `enter_dropping` — params: e
- L153 `state_dropping` — params: e
- L167 `enter_caught` — params: e
- L173 `state_caught` — params: e
- L187 `enter_walking` — params: e
- L194 `enter_dying` — params: e
- L206 `state_dying` — params: e

### lox_examples/defender/npc/lander.lox

- L11 `Lander.__init__` — params: img
- L32 `Lander.position` — return type (returns a value)
- L50 `Lander.draw` — params: cam
- L86 `state_materialize` — params: e
- L94 `enter_descend` — params: e
- L102 `state_descend` — params: e
- L115 `enter_search` — params: e
- L123 `state_search` — params: e
- L142 `enter_grab` — params: e
- L154 `state_grab` — params: e
- L166 `enter_abduct` — params: e
- L173 `state_abduct` — params: e
- L186 `enter_mutated` — params: e
- L206 `state_mutated` — params: e
- L250 `enter_die` — params: e
- L270 `state_die` — params: e
- L278 `draw_exp` — params: e, cam
- L285 `draw_` — params: e, cam

### lox_examples/defender/npc/npc.lox

- L17 `NPC.__init__` — params: img
- L53 `NPC.draw` — params: cam
- L74 `NPC.fire_bullet_at` — params: player
- L81 `draw_normal` — params: e, cam
- L89 `draw_dispersed` — params: e, cam
- L96 `enter_die` — params: e
- L112 `state_die` — params: e
- L127 `aim_bullet_at` — params: e, player
- L155 `seek_player` — params: e, player

### lox_examples/defender/npc/pod.lox

- L8 `Pod.__init__` — params: img
- L21 `state_drift` — params: e

### lox_examples/defender/npc/swarmer.lox

- L10 `Swarmer.__init__` — params: img
- L25 `state_chase` — params: e

### lox_examples/defender/player/laser.lox

- L76 `Laser.draw` — params: cam
- L136 `LaserPool.draw` — params: cam

### lox_examples/defender/player/player.lox

- L33 `Player.__init__` — params: img, thrust_img, shipw_img, config
- L109 `Player.handle_input` — params: input
- L132 `Player.fire` — params: input
- L142 `Player.smart_bomb` — params: input
- L148 `Player.update` — params: input
- L154 `Player.camera_x` — return type (returns a value)
- L158 `Player.draw` — params: cam
- L221 `state_safe_start` — params: e, input
- L235 `enter_safe_start` — params: e
- L248 `state_play` — params: e, input
- L260 `move` — params: e, input
- L306 `enter_hyperspace` — params: e
- L320 `state_hyperspace` — params: e, input
- L335 `random_hyperspace_pos` — params: e
- L347 `far_from_npcs` — params: e, x, y; return type (returns a value)
- L363 `enter_die` — params: e
- L380 `state_die` — params: e, input
- L389 `enter_explode` — params: e
- L405 `state_explode` — params: e, input
- L414 `enter_play` — params: e

### lox_examples/defender/world/collide.lox

- L9 `entity_box` — params: e
- L13 `laser_box` — params: l

### lox_examples/defender/world/mountains.lox

- L28 `Mountain.attach` — params: events
- L32 `Mountain.on_level_finish` — return type (returns a value)
- L33 `Mountain/handler` — params: e
- L38 `Mountain.on_level_start` — return type (returns a value)
- L39 `Mountain/handler` — params: e
- L92 `Mountain.draw` — params: cam

### lox_examples/defender/world/stars.lox

- L11 `Star.get` — return type (returns a value)

### lox_examples/donut.lox

- L54 `render_frame` — params: A, B

### lox_examples/fireworks.lox

- L17 `move` — params: particle
- L27 `init` — params: col1, col2; return type (returns a value)
- L38 `<lambda>` — params: particle
- L50 `random_vec_2D` — params: xmin, xmax, ymin, ymax; return type (returns a value)
- L54 `queue_random_emitter` — params: width, height, delay
- L63 `make_stars` — return type (returns a value)
- L74 `update_stars` — params: stars, batch

### lox_examples/game_of_life.lox

- L377 `load_step` — params: src; return type (returns a value)
- L401 `set_resolution` — params: s
- L417 `set_wrapped_px` — params: rt, x, y, col
- L423 `draw_random_line` — params: rt, value_fn
- L444 `draw_random_box` — params: rt, value_fn
- L460 `draw_random_block` — params: rt, value_fn
- L473 `randomise_with` — params: rt, value_fn
- L486 `randomise` — params: rt
- L487 `<lambda>` — return type (returns a value)
- L493 `randomise_multistate` — params: rt
- L494 `<lambda>` — return type (returns a value)
- L497 `randomise_immigration` — params: rt
- L498 `<lambda>` — return type (returns a value)
- L506 `randomise_quadlife` — params: rt
- L507 `<lambda>` — return type (returns a value)
- L517 `Strategy.__init__` — params: name, step_shader, birth_mask, survival_mask, display_shader, tint_colour, randomise_fn
- L546 `activate_strategy` — params: index

### lox_examples/game_of_life_multi_zone.lox

- L190 `add_param_field` — params: y, label_text, initial, loc, apply; return type (returns a value)
- L193 `<lambda>` — params: w, text
- L205 `<lambda>` — params: v
- L206 `<lambda>` — params: v
- L207 `<lambda>` — params: v
- L208 `<lambda>` — params: v
- L209 `<lambda>` — params: v
- L210 `<lambda>` — params: v
- L211 `<lambda>` — params: v
- L221 `set_wrapped_val` — params: arr, x, y
- L227 `draw_random_line` — params: arr
- L247 `draw_random_box` — params: arr
- L262 `draw_random_block` — params: arr
- L274 `randomise` — params: rt

### lox_examples/grids.lox

- L10 `Siner.__init__` — params: min, max, rate
- L24 `Siner.get` — return type (returns a value)
- L30 `Bouncer.__init__` — params: min, max, dx
- L47 `Bouncer.copy` — return type (returns a value)
- L50 `Bouncer.get` — return type (returns a value)
- L53 `Bouncer.set` — params: value
- L71 `ColourShift.get` — return type (returns a value)
- L85 `Grid.__init__` — params: cx, cy, size, cells, angle, col, speed
- L95 `Grid.copy` — return type (returns a value)
- L98 `Grid.update` — params: x, y, size
- L109 `Grid.draw` — params: scale
- L141 `enumerate` — params: list; return type (returns a value)

### lox_examples/jetpac/alien.lox

- L85 `wrap_x` — params: x; return type (returns a value)
- L93 `alien_near_jetman` — params: alien, jetman
- L106 `Alien.__init__` — params: sound
- L131 `Alien.step` — params: jetman, platforms, lasers, score, explosions
- L140 `hide` — params: alien
- L150 `kill_alien` — params: alien, explosions, score, points
- L164 `contact_kill` — params: alien, jetman, explosions, score
- L173 `jetfighter_self_destruct` — params: alien, explosions, score
- L185 `state_meteor` — params: alien, jetman, platforms, lasers, score, explosions
- L219 `state_squidgy` — params: alien, jetman, platforms, lasers, score, explosions
- L255 `state_sphere` — params: alien, jetman, platforms, lasers, score, explosions
- L311 `state_crossed_ship` — params: alien, jetman, platforms, lasers, score, explosions
- L358 `state_ufo` — params: alien, jetman, platforms, lasers, score, explosions
- L422 `state_jetfighter` — params: alien, jetman, platforms, lasers, score, explosions
- L480 `state_idle` — params: alien, jetman, platforms, lasers, score, explosions
- L502 `spawn_alien` — params: alien, x, y, vx, vy, colour, level

### lox_examples/jetpac/assets.lox

- L10 `decode_pixel_rows` — params: rows; return type (returns a value)
- L30 `decode_byte_rows` — params: data, width_px; return type (returns a value)
- L62 `SpriteAssets.load` — params: path
- L81 `SpriteAssets.get` — params: name; return type (returns a value)
- L89 `SpriteAssets.get_x_offset` — params: name
- L93 `SpriteAssets.has` — params: name
- L97 `SpriteAssets.names` — return type (returns a value)

### lox_examples/jetpac/display.lox

- L108 `Display.clear` — params: ink, paper
- L117 `Display.plot` — params: x, y, bit
- L121 `Display.get_pixel` — params: x, y
- L129 `Display.set_attr` — params: cx, cy, ink, paper
- L144 `Display.flash_ink` — params: ink
- L160 `Display.blit_sprite` — params: sprite, x, y, ink, paper
- L197 `Display.rotate_row_left` — params: x, y, width, amount
- L208 `Display.rotate_row_right` — params: x, y, width, amount
- L223 `Display.shift_rows_down` — params: x, y, width, height
- L234 `Display.get_ink` — params: cx, cy
- L238 `Display.get_paper` — params: cx, cy
- L258 `Display.draw` — params: win, x, y, w, h

### lox_examples/jetpac/explosion.lox

- L24 `explosion_colours` — return type (returns a value)
- L35 `random_explosion_colour` — return type (returns a value)
- L50 `Explosion.spawn` — params: x, y

### lox_examples/jetpac/extract_jetpac.lox

- L27 `reverse_rows` — params: data, bytes_per_row, height; return type (returns a value)
- L49 `emit_byte_sprite` — params: sk, label, name, sprites
- L64 `emit_alien_sprite` — params: sk, label, name, sprites
- L73 `emit_tile_sprite` — params: sk, label, name, sprites
- L99 `emit_jetman_sprites` — params: sk, sprites
- L113 `emit_rocket_sprites` — params: sk, sprites
- L137 `emit_item_sprites` — params: sk, sprites
- L150 `emit_alien_sprites` — params: sk, sprites
- L164 `emit_explosion_sprites` — params: sk, sprites
- L170 `emit_tile_sprites` — params: sk, sprites
- L177 `emit_font_sprites` — params: sk; return type (returns a value)
- L198 `extract_platforms` — params: sk; return type (returns a value)
- L210 `record_from_bytes` — params: rec, field_names; return type (returns a value)
- L225 `item_label_to_name_map` — return type (returns a value)
- L241 `extract_collectible_sprites` — params: sk; return type (returns a value)
- L257 `extract_static` — params: sk; return type (returns a value)
- L275 `ensure_dir` — params: path
- L281 `write_json` — params: path, value

### lox_examples/jetpac/extract_sfx.lox

- L53 `thrust_pitch` — params: bucket; return type (returns a value)
- L59 `build_thrust_cues` — return type (returns a value)
- L67 `ensure_dir` — params: path

### lox_examples/jetpac/font.lox

- L10 `draw_text` — params: disp, font, text, x, y, ink, paper
- L22 `strip_spaces` — params: s; return type (returns a value)
- L36 `draw_text_centred` — params: disp, font, text, y, ink, paper

### lox_examples/jetpac/game.lox

- L46 `Score.add` — params: points
- L52 `Game.__init__` — params: sound
- L107 `Game.spawn_explosion` — params: x, y
- L124 `Game.tick` — params: win
- L200 `step_death` — params: g

### lox_examples/jetpac/game_sound.lox

- L48 `Sound.thrust` — params: y

### lox_examples/jetpac/game_sprite.lox

- L50 `Sprite.clear` — params: disp
- L64 `Sprite.draw` — params: disp, lib

### lox_examples/jetpac/hud.lox

- L27 `draw_static` — params: g
- L36 `draw_score` — params: g
- L44 `draw_lives` — params: g
- L51 `draw` — params: g

### lox_examples/jetpac/item.lox

- L54 `attr_colour` — params: attr; return type (returns a value)
- L59 `near_jetman` — params: item, jetman
- L72 `Item.__init__` — params: sound
- L90 `Item.step` — params: jetman, rocket, platforms, score
- L107 `init_module` — params: item, key, sprite, static_data
- L130 `spawn_fuel_pod` — params: item, jetman, rocket, static_data
- L153 `spawn_collectible` — params: item, jetman, static_data
- L180 `is_top_module` — params: item
- L194 `state_falling` — params: item, jetman, rocket, platforms, score
- L228 `state_carried` — params: item, jetman, rocket, platforms, score
- L244 `state_docking` — params: item, jetman, rocket, platforms, score
- L264 `state_idle` — params: item, jetman, rocket, platforms, score

### lox_examples/jetpac/jetman.lox

- L32 `wrap_x` — params: x; return type (returns a value)
- L46 `accel_or_flip` — params: vel, want_this_dir, max_vel; return type (returns a value)
- L62 `Jetman.__init__` — params: sound
- L82 `Jetman.spawn` — params: static_data
- L101 `Jetman.step` — params: input, platforms
- L154 `Jetman.draw` — params: disp, lib
- L175 `walk_shift` — params: j; return type (returns a value)
- L180 `current_sprite_name` — params: j; return type (returns a value)
- L195 `enter_fly` — params: j
- L199 `enter_walk` — params: j
- L204 `enter_dying` — params: j
- L213 `fly_horizontal` — params: j, input
- L248 `fly_vertical` — params: j, input
- L279 `state_fly` — params: j, input, platforms
- L305 `state_walk` — params: j, input, platforms
- L333 `state_dying` — params: j, input, platforms
- L338 `state_boarding` — params: j, input, platforms

### lox_examples/jetpac/jetman_controller.lox

- L19 `key_const` — params: win, name; return type (returns a value)
- L75 `Controller.load_keys` — params: win
- L85 `Controller.update` — params: win

### lox_examples/jetpac/laser.lox

- L73 `beam_colours` — return type (returns a value)
- L86 `build_marks` — return type (returns a value)
- L104 `rand_range` — params: lo, hi; return type (returns a value)
- L110 `plot_clamped` — params: disp, x, y, v
- L116 `new_beam` — return type (returns a value)
- L147 `LaserPool.fire` — params: jetman, lib
- L172 `LaserPool.clear` — params: disp
- L188 `LaserPool.update` — params: platforms
- L210 `LaserPool.draw` — params: disp
- L273 `LaserPool.check_hit` — params: x, y

### lox_examples/jetpac/platform.lox

- L31 `platform_span` — params: rec; return type (returns a value)
- L47 `platform_colours` — params: attr; return type (returns a value)
- L56 `Platforms.__init__` — params: static_data
- L69 `Platforms.draw` — params: disp, lib
- L99 `Platforms.collide` — params: x, old_y, new_y, height; return type (returns a value)
- L128 `Platforms.blocks_point` — params: x, y

### lox_examples/jetpac/rocket.lox

- L50 `row_ink` — params: rocket, row_top_y, white, magenta, flash_on; return type (returns a value)
- L74 `near_jetman` — params: rocket, jetman
- L89 `Rocket.__init__` — params: static_data, sound
- L133 `Rocket.step` — params: jetman, game
- L142 `Rocket.clear` — params: disp
- L155 `Rocket.draw` — params: disp, lib
- L210 `enter_on_pad` — params: r
- L214 `enter_taking_off` — params: r
- L218 `enter_landing` — params: r
- L233 `state_on_pad` — params: r, jetman, game
- L244 `animate_flame` — params: r
- L255 `state_taking_off` — params: r, jetman, game
- L276 `state_landing` — params: r, jetman, game

### lox_examples/jetpac/skool.lox

- L28 `parse_hex` — params: token; return type (returns a value)
- L62 `strip_comment` — params: s; return type (returns a value)
- L67 `store_defb` — params: sk, addr, content
- L75 `store_defw` — params: sk, addr, content
- L84 `store_defs` — params: sk, addr, content
- L95 `store_defm` — params: sk, addr, content
- L111 `apply_pending_labels` — params: sk, addr, pending_labels
- L122 `parse_line` — params: sk, line, pending_labels
- L163 `parse_file` — params: sk, path
- L181 `Skool.__init__` — params: path
- L191 `Skool.byte` — params: addr; return type (returns a value)
- L199 `Skool.bytes` — params: addr, count; return type (returns a value)
- L207 `Skool.word` — params: addr; return type (returns a value)
- L211 `Skool.addr_of` — params: label; return type (returns a value)
- L219 `Skool.bytes_at_label` — params: label, count; return type (returns a value)
- L226 `Skool.label_at` — params: addr; return type (returns a value)

### lox_examples/jetpac/spawner.lox

- L32 `alien_colour` — params: slot; return type (returns a value)
- L42 `Spawner.tick` — params: g
- L71 `spawn_alien_if_free` — params: g

### lox_examples/jetpac/spectrum_attr.lox

- L11 `colour_to_rgba` — params: value, bright; return type (returns a value)
- L32 `decode_attribute` — params: byte; return type (returns a value)

### lox_examples/kaleido.lox

- L13 `TextureSampler.__init__` — params: tex, sampleWidth, sampleHeight
- L49 `Pen.__init__` — params: width, height, margin
- L103 `Pen.draw` — params: canvas

### lox_examples/mandel_shader.lox

- L166 `split_double` — params: a; return type (returns a value)

### lox_examples/mandelbox_shader.lox

- L230 `vec3_add` — params: a, b; return type (returns a value)
- L233 `vec3_sub` — params: a, b; return type (returns a value)
- L236 `vec3_scale` — params: v, s; return type (returns a value)
- L239 `vec3_cross` — params: a, b; return type (returns a value)
- L242 `vec3_length` — params: v; return type (returns a value)
- L245 `vec3_normalize` — params: v; return type (returns a value)
- L311 `update_detail_level` — params: cam_pos; return type (returns a value)

### lox_examples/manic_miner/assets.lox

- L10 `decode_pixel_rows` — params: rows; return type (returns a value)
- L30 `decode_byte_rows` — params: data, width_px; return type (returns a value)
- L61 `SpriteAssets.load` — params: path
- L79 `SpriteAssets.get` — params: name; return type (returns a value)
- L83 `SpriteAssets.has` — params: name
- L87 `SpriteAssets.names` — return type (returns a value)

### lox_examples/manic_miner/cavern.lox

- L59 `make_guardian_sprite` — params: g, movement_type, image_list, frames; return type (returns a value)
- L140 `Cavern.load_from_dict` — params: d
- L191 `Cavern.load` — params: path
- L215 `Cavern.get_tile` — params: x, y; return type (returns a value)
- L224 `Cavern.tile_type_at` — params: px, py
- L241 `Cavern.tile_blocks` — params: px, py
- L253 `Cavern.tile_supports_landing` — params: px, py
- L268 `Cavern.tile_is_platform` — params: px, py
- L288 `Cavern.tick_crumble` — params: disp, lib, px, py
- L309 `Cavern.redraw_tile_cell` — params: disp, lib, cx, cy
- L322 `Cavern.collect_item_at` — params: disp, lib, px, py, pw, ph; return type (returns a value)
- L342 `Cavern.collect_all_items` — params: disp, lib
- L371 `Cavern.guardian_hit` — params: lib, willy_img, wx, wy
- L405 `Cavern.draw` — params: disp, lib
- L440 `Cavern.draw_portal` — params: disp, lib
- L467 `Cavern.clear_eugene` — params: disp
- L477 `Cavern.draw_eugene` — params: disp, lib
- L505 `Cavern.set_portal_flash` — params: disp, lib, tick
- L520 `Cavern.draw_items` — params: disp, lib, tick
- L542 `Cavern.animate_conveyor` — params: disp
- L565 `Cavern.clear_guardians` — params: disp
- L580 `Cavern.draw_guardians` — params: disp, lib

### lox_examples/manic_miner/demo.lox

- L30 `load_cavern` — params: d, cavern_index
- L48 `refresh_hud` — params: d
- L53 `enter_show` — params: d
- L61 `state_show` — params: d, win
- L86 `enter_flash` — params: d
- L95 `flash_cavern_ink` — params: d, ink
- L107 `state_flash` — params: d, win
- L121 `enter_next_cavern` — params: d
- L128 `Demo.__init__` — params: sound
- L142 `Demo.tick` — params: win

### lox_examples/manic_miner/display.lox

- L108 `Display.clear` — params: ink, paper
- L117 `Display.plot` — params: x, y, bit
- L121 `Display.get_pixel` — params: x, y
- L129 `Display.set_attr` — params: cx, cy, ink, paper
- L144 `Display.flash_ink` — params: ink
- L153 `Display.blit_sprite` — params: sprite, x, y, ink, paper
- L186 `Display.rotate_row_left` — params: x, y, width, amount
- L197 `Display.rotate_row_right` — params: x, y, width, amount
- L212 `Display.shift_rows_down` — params: x, y, width, height
- L223 `Display.get_ink` — params: cx, cy
- L227 `Display.get_paper` — params: cx, cy
- L247 `Display.draw` — params: win, x, y, w, h

### lox_examples/manic_miner/extract_cavern.lox

- L42 `bytes_to_pixel_rows` — params: data, width; return type (returns a value)
- L66 `read_ascii` — params: bytes, addr, length; return type (returns a value)
- L79 `read_tiles` — params: bytes, addr, prefix; return type (returns a value)
- L106 `read_terminated_records` — params: bytes, addr, record_size, max_count; return type (returns a value)
- L129 `read_fixed_slots` — params: bytes, addr, record_size, count; return type (returns a value)
- L145 `extract_global_sprites` — params: bytes, out_dir
- L146 `read_sprite16` — params: addr, name; return type (returns a value)
- L164 `extract_one` — params: bytes, index, out_dir
- L295 `read_horizontal_guardians` — params: addr; return type (returns a value)
- L327 `read_vertical_guardians` — params: addr; return type (returns a value)

### lox_examples/manic_miner/extract_font.lox

- L19 `bytes_to_pixel_rows` — params: data; return type (returns a value)

### lox_examples/manic_miner/extract_start_screen.lox

- L27 `bytes_to_screen_pixel_rows` — params: bytes, base, height; return type (returns a value)
- L58 `read_attr_rows` — params: bytes, base, rows; return type (returns a value)

### lox_examples/manic_miner/font.lox

- L10 `draw_text` — params: disp, font, text, x, y, ink, paper
- L22 `strip_spaces` — params: s; return type (returns a value)
- L36 `draw_text_centred` — params: disp, font, text, y, ink, paper

### lox_examples/manic_miner/game.lox

- L93 `enter_running` — params: g
- L100 `draw_name_row` — params: g
- L108 `draw_score_row` — params: g
- L119 `draw_oxygen_row_background` — params: g
- L133 `draw_oxygen_bar_fill` — params: g
- L146 `update_oxygen_bar` — params: g
- L164 `draw_static_hud` — params: g
- L174 `draw_lives` — params: g
- L186 `state_running` — params: g, win
- L228 `enter_die` — params: g, win
- L239 `state_die` — params: g, win
- L265 `enter_portal` — params: g, win
- L276 `flash_cavern_ink` — params: g, ink
- L289 `state_portal` — params: g, win
- L308 `wipe_air_bar` — params: g
- L321 `load_cavern` — params: g, cavern_index
- L336 `enter_next_cavern` — params: g
- L347 `clear_cavern_area` — params: g, ink, paper
- L364 `enter_game_over` — params: g
- L384 `state_game_over` — params: g, win
- L407 `state_game_over_done` — params: g, win
- L411 `Game.__init__` — params: cavern_index, target_fps, sound
- L448 `Game.tick` — params: win

### lox_examples/manic_miner/game_sprite.lox

- L48 `Sprite.load_from_dict` — params: d
- L161 `Sprite.clear` — params: disp
- L171 `Sprite.draw` — params: disp, lib

### lox_examples/manic_miner/intro.lox

- L61 `tune_total_duration` — return type (returns a value)
- L79 `piano_key_col` — params: freq; return type (returns a value)
- L87 `attr_byte_colours` — params: byte; return type (returns a value)
- L96 `Intro.__init__` — params: sound
- L140 `Intro.tick` — params: win

### lox_examples/manic_miner/sna.lox

- L15 `load` — params: path; return type (returns a value)
- L25 `addr_to_offset` — params: addr; return type (returns a value)
- L29 `read_u8` — params: bytes, addr; return type (returns a value)
- L34 `read_u16` — params: bytes, addr; return type (returns a value)

### lox_examples/manic_miner/spectrum_attr.lox

- L11 `colour_to_rgba` — params: value, bright; return type (returns a value)
- L32 `decode_attribute` — params: byte; return type (returns a value)

### lox_examples/manic_miner/spectrum_screen.lox

- L8 `attr_addr_to_xy` — params: addr, base; return type (returns a value)
- L19 `pixel_addr_to_xy` — params: addr, base; return type (returns a value)

### lox_examples/manic_miner/willy.lox

- L29 `is_nasty` — params: tile_type
- L45 `WalkCycle.reset` — params: dx
- L52 `WalkCycle.face` — params: dx
- L81 `Willy.__init__` — params: sound
- L108 `Willy.spawn` — params: room
- L131 `Willy.step` — params: input, room, disp, lib
- L140 `Willy.clear` — params: disp
- L150 `Willy.draw` — params: disp, lib, room
- L163 `enter_walk` — params: w
- L171 `draw_footprint` — params: w, room, disp, img, x, y
- L214 `snapshot_footprint` — params: w, disp, x, y
- L234 `restore_footprint` — params: w, disp
- L255 `can_move_x` — params: w, room, dx
- L268 `handle_step_horizontal` — params: w, room, dx
- L286 `spanned_columns` — params: w; return type (returns a value)
- L298 `landed` — params: w, room, new_y
- L310 `crossing_onto_ground` — params: w, room, old_y, new_y
- L325 `hit_ceiling` — params: w, room, new_y
- L336 `snap_to_ground` — params: w, new_y
- L342 `conveyor_direction` — params: room
- L350 `touching_nasty` — params: w, room
- L369 `handle_items_and_hazards` — params: w, room, disp, lib
- L384 `tick_air` — params: w
- L397 `state_walk` — params: w, input, room, disp, lib
- L463 `enter_fall` — params: w
- L472 `state_fall` — params: w, input, room, disp, lib
- L494 `enter_jump` — params: w, dx
- L504 `state_jump` — params: w, input, room, disp, lib
- L544 `enter_dying` — params: w
- L553 `state_dying` — params: w, input, room, disp, lib

### lox_examples/manic_miner/willy_controller.lox

- L14 `Controller.update` — params: win

### lox_examples/snakes.lox

- L126 `clamp_axis` — params: v, limit; return type (returns a value)
- L147 `perpendicular_heading` — params: heading; return type (returns a value)
- L163 `Sphere.__init__` — params: pos, radius, color, speed
- L170 `Sphere.update` — params: target_pos
- L195 `Vanguard.__init__` — params: pos, heading, speed
- L246 `Swarm.__init__` — params: color
- L286 `Swarm.trail_at` — params: i; return type (returns a value)

### lox_examples/tile_planes.lox

- L7 `ceil` — params: x; return type (returns a value)
- L12 `floor` — params: x; return type (returns a value)
- L18 `Line.__init__` — params: pos, col, width, height, angle, margin
- L67 `Line.draw` — params: frame
- L73 `Tile.__init__` — params: width, height, lines, margin
- L92 `Tile.move` — params: pos
- L95 `Tile.clear` — params: col
- L98 `Tile.draw` — params: win
- L104 `Tiler.__init__` — params: scale, speed
- L114 `Tiler.add` — params: tile
- L120 `Tiler.set_speed` — params: vec2speed
- L138 `Tiler.draw` — params: win
- L178 `tile_hash` — params: i, j, seed; return type (returns a value)
- L183 `make_lines` — params: n, width, height, alpha, margin; return type (returns a value)
- L195 `get_tilers` — return type (returns a value)
- L214 `clear_tilers` — params: tilers

### lox_examples/triangle3_batch_demo.lox

- L38 `heightToColor` — params: height; return type (returns a value)

