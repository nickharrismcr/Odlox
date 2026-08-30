# Shader-based attribute compositing for the Manic Miner display

**Status**: design only, not yet implemented.

## Context

`lox_examples/manic_miner/display.lox`'s `Display` class implements a ZX
Spectrum-style bitmap-plus-attribute display: a 1-bit pixel bitmap and a
32x24 grid of 8x8-cell ink/paper colours. Colour resolution currently
happens entirely on the CPU, in Lox. `plot(x, y, bit)` looks up the target
cell's current ink/paper colour and writes a resolved RGBA value into a
fourth `screen` float_array; `set_attr(cx, cy, ink, paper)` (called by
`blit_sprite()` for every cell a sprite overlaps) re-resolves all 64 pixels
of that cell against the bitmap; `begin_flash()`/`flash_ink()` (Willy's
death sequence) resolve, or re-resolve, large spans of the screen per tick.
Only the final, already-resolved `screen` buffer reaches the GPU, via
`render_texture.draw_array_fast()`. `benchmarks/lox/spectrum_bench.lox` and
`spectrum_bench_realistic.lox` time exactly this per-pixel CPU fill pattern
as the cost driver, separately from the GPU upload.

This plan moves colour resolution onto the GPU. Three CPU-side source
buffers — pixel bitmap, ink attribute grid, paper attribute grid — each
upload to their own small texture unchanged, with no per-pixel/per-cell
cross-lookup on the CPU; a fragment shader composites them into the final
image every frame. `plot()`, `set_attr()`, and the flash methods drop their
resolve loops entirely: recolouring an attribute cell becomes O(1) (was
O(64)), a full-screen flash tick becomes O(cells) (was O(screen) or O(cached
ink pixels)), and plotting a pixel no longer touches attribute data.

Scope is `lox_examples/manic_miner/display.lox` plus one native addition it
depends on (`Shader.set_value_texture`, below). No other example uses this
attribute-cell pattern. `Display`'s public method surface — used by
`game.lox`, `main.lox`, `cavern.lox`, `game_sprite.lox` — is unchanged.

## Current data flow

```
bitmap    : float_array(256,192)  0.0/1.0 ink bit, written by plot()/blit_sprite()
attr_ink  : float_array(32,24)    packed-rgba per 8x8 cell
attr_paper: float_array(32,24)    packed-rgba per 8x8 cell
screen    : float_array(256,192)  resolved packed-rgba per pixel -- CPU cost lives here
rt        : render_texture(256,192)

plot(x,y,bit)            -> bitmap.set + attr lookup + screen.set        O(1), 2 lookups
set_attr(cx,cy,ink,pap)  -> attr_ink/attr_paper.set + 64-pixel resolve   O(64)
begin_flash()/flash_ink  -> full/cached-pixel resolve passes             O(screen) / O(ink px)
upload()                 -> rt.draw_array_fast(screen)
draw(win,...)            -> win.draw_texture_pro(rt, ...)
```

## New data flow

```
bitmap    : float_array(256,192)  packed-rgba: WHITE (16777215) for a set bit, 0 for clear
                                   (same convention as attr_ink/attr_paper, see Design decisions)
attr_ink  : float_array(32,24)    packed-rgba per 8x8 cell   -- unchanged
attr_paper: float_array(32,24)    packed-rgba per 8x8 cell   -- unchanged
bitmap_rt : render_texture(256,192)
ink_rt    : render_texture(32,24)   FILTER_POINT + WRAP_CLAMP on its texture
paper_rt  : render_texture(32,24)   FILTER_POINT + WRAP_CLAMP on its texture
rt        : render_texture(256,192)  -- final composited output, unchanged role/size
composite : shader()  -- loaded once, GLSL below

plot(x,y,bit)            -> bitmap.set(x,y, bit != 0.0 ? WHITE : 0.0)      O(1), no attr touch
set_attr(cx,cy,ink,pap)  -> attr_ink.set + attr_paper.set                 O(1), no pixel touch
begin_flash()            -> attr_paper.clear(BLACK)                       O(1)
flash_ink(ink)           -> attr_ink.clear(ink)                           O(1)
upload()                 -> bitmap_rt.draw_array_fast(bitmap) every frame;
                             ink_rt/paper_rt re-uploaded only when attr_dirty (below)
                          -> composite shader draws bitmap_rt into rt, sampling ink_rt/paper_rt
draw(win,...)             -> win.draw_texture_pro(rt, ...)                unchanged
```

`flash_ink_pixels` caching is deleted: the shader recomputes the full
composite every frame from `attr_ink`/`attr_paper`/`bitmap`, so there is
nothing left to cache.

## Design decisions

### Bitmap encoding

`bitmap` switches from raw 0.0/1.0 to the same packed-rgba convention as
`attr_ink`/`attr_paper` (WHITE = `encode_rgba(255,255,255)` = 16777215.0 for
a set pixel; 0.0 for clear is unchanged under either convention). This puts
all three source buffers on one convention and lets the shader test
`texture0.r` directly against a clean 0.0/1.0, instead of relying on
`render_texture.draw_array_fast`'s incidental low-byte packing of small
integers if raw 0.0/1.0 were uploaded as-is (`draw_array_fast` treats every
cell as a packed-RGB int; a raw 1.0 would decode to a barely-nonzero blue
channel, not a documented value).

- `plot(x, y, bit)`: store `WHITE` if `bit != 0.0`, else `0.0`.
- `get_pixel(x, y)`: keeps its `-> float` contract of 0.0/1.0 — normalize on
  read (return `1.0` if the stored value is nonzero, else `0.0`).
- `blit_sprite()`: currently writes `this.bitmap.set(px, py, sprite.get(...))`
  directly, bypassing `plot()`. Route it through `plot()` so the encoding
  happens in one place. `rotate_row_left/right`/`shift_rows_down` already
  call `plot()` and need no change; re-plotting an already-encoded value
  stays idempotent (`!= 0.0`/`== 0.0` is preserved either way).

### Attribute upload cadence

Attribute changes (`set_attr`, flash) are far rarer than per-frame pixel
plots. `upload()` re-uploads `ink_rt`/`paper_rt` and rebinds their shader
texture uniforms only when a new `attr_dirty` flag is set, cleared once
consumed. `bitmap_rt` still uploads every frame, since pixels change via
animation. The uniform locations for `inkTex`/`paperTex` only strictly need
rebinding when the underlying texture ID changes (only on the very first
upload at a given size), but rebinding on every attr-dirty upload is
simplest and the cost is negligible at 32x24.

## Native addition: `Shader.set_value_texture`

`src/natives/gfx_shader.odin` exposes `set_value_float/vec2/vec3/vec4` but
nothing for a `sampler2D` uniform (no `SetShaderValueTexture` call anywhere
in `src/natives/`). The composite shader needs two bound textures
(`inkTex`, `paperTex`) beyond the one raylib auto-binds to `texture0` from
the primary draw call, so this is a required addition:

```odin
case "set_value_texture":
    // 2 args: location (int), texture (Texture or RenderTexture)
    loc_val, tex_val := vm.peek(v, 1), vm.peek(v, 0)
    // validate loc_val is_int
    tex: rl.Texture2D
    switch {
    case is_texture_value(tex_val):
        tex = texture_data_of(tex_val).texture
    case is_render_texture_value(tex_val):
        tex = render_texture_data_of(tex_val).render_texture.texture
    case:
        // runtime_error: expects a Texture or RenderTexture
    }
    rl.SetShaderValueTexture(s.shader, c.int(core.as_int(loc_val)), tex)
```

`is_texture_value`/`texture_data_of`/`is_render_texture_value`/
`render_texture_data_of` are already package-private helpers in
`src/natives/gfx_texture.odin` (already used across files, e.g. by
`gfx_batch_instanced.odin`), so `gfx_shader.odin` calls them directly — no
new plumbing beyond the new `case` and error handling in the same style as
the existing `set_value_*` cases.

## Composite fragment shader

Reuses the standard fullscreen-quad vertex shader already duplicated across
`mandel_shader.lox`/`game_of_life_multi_zone.lox` (`mvp * vertexPosition`,
pass through `vertexTexCoord`/`vertexColor`). New fragment shader, embedded
as a Lox string literal in `display.lox`, matching the in-file convention
used by other shader-owning scripts in this codebase:

```glsl
#version 330
in vec2 fragTexCoord;
out vec4 finalColor;

uniform sampler2D texture0;  // bitmap_rt: WHITE = ink bit set, BLACK = clear
uniform sampler2D inkTex;    // ink_rt, 32x24, FILTER_POINT + WRAP_CLAMP
uniform sampler2D paperTex;  // paper_rt, 32x24, FILTER_POINT + WRAP_CLAMP

void main() {
    float bit = texture(texture0, fragTexCoord).r;
    vec4 ink = texture(inkTex, fragTexCoord);
    vec4 paper = texture(paperTex, fragTexCoord);
    finalColor = mix(paper, ink, bit);
}
```

Sampling `inkTex`/`paperTex` at the same normalized `fragTexCoord` as the
256x192 bitmap works because they're only 32x24 texels: with `FILTER_POINT`
+ `WRAP_CLAMP` (via the existing `.get_texture().set_filter_mode(...)`/
`.set_wrap_mode(...)` methods, the same pattern `game_of_life_multi_zone.lox`
already uses), the GPU's own texture-coordinate mapping quantizes each
fragment to its containing 8x8 cell — no manual cell-index math needed in
the shader.

Per-frame sequence in `Display.upload()`/`draw()`:

```
bitmap_rt.draw_array_fast(bitmap)
if (attr_dirty) {
    ink_rt.draw_array_fast(attr_ink)
    paper_rt.draw_array_fast(attr_paper)
    composite.set_value_texture(ink_loc, ink_rt)
    composite.set_value_texture(paper_loc, paper_rt)
    attr_dirty = false
}
win.begin_texture_mode(rt)
win.begin_shader_mode(composite)
win.draw_texture_pro(bitmap_rt, 0, 0, W, H, 0, 0, W, H, 0, 0, 0, WHITE)  // binds texture0
win.end_shader_mode()
win.end_texture_mode()
```

## Files to change

- `src/natives/gfx_shader.odin` — add `set_value_texture` (above).
- `lox_examples/manic_miner/display.lox` — add `bitmap_rt`/`ink_rt`/
  `paper_rt`/`composite`/`attr_dirty` fields and their construction
  (including `FILTER_POINT`/`WRAP_CLAMP` on ink/paper textures and the
  embedded GLSL); rewrite `plot`, `set_attr`, `begin_flash`, `flash_ink`,
  `blit_sprite`, `get_pixel`, `upload`, `clear`; delete the `screen` field
  and `flash_ink_pixels` caching.
- No changes expected to `cavern.lox`, `game.lox`, `main.lox`,
  `game_sprite.lox`, `spectrum_attr.lox` — they only use `Display`'s public
  methods (`plot`, `set_attr`, `blit_sprite`, `begin_flash`, `flash_ink`,
  `clear`, `get_pixel`, `get_ink`, `get_paper`, `upload`, `draw`,
  `rotate_row_left/right`, `shift_rows_down`), whose signatures and
  observable behaviour are unchanged.

## Verification

- `bin/test_odin.sh` — Odin unit tests still pass after the
  `gfx_shader.odin` addition (regression check; no existing test exercises
  `gfx`/shader natives directly).
- `bin/run_tests.sh` — the ported pytest suite against a freshly built
  `bin/odlox.exe`, confirming native dispatch for the new
  `set_value_texture` case doesn't break the rest of the `gfx` cluster.
- Run `lox_examples/manic_miner/main.lox` directly and visually confirm:
  cavern tiles render with correct ink/paper per cell, sprite blitting
  still shows attribute-clash bleed onto neighbouring cells, Willy's death
  flash still cycles ink correctly, conveyor/crumbling-floor animations
  (routed through `plot()`) still render correctly.
- Lint the edited file per `CLAUDE.md`:
  `npx ts-node src/lint-cli.ts lox_examples/manic_miner/display.lox` (from
  `lox_lsp`).
- `benchmarks/lox/spectrum_bench.lox`/`spectrum_bench_realistic.lox` hand-roll
  the old fill pattern independently of `Display`, so they're a reference
  baseline, not something this change modifies. A new benchmark exercising
  `Display.set_attr`/`begin_flash` at scale would give a concrete
  O(pixels)->O(cells) comparison for the commit/PR description.

## Risks / open questions

1. GPU texture-sampling correctness across `FILTER_POINT` edge cases at cell
   boundaries needs a visual check against the existing `game_of_life_multi_zone.lox`
   precedent, which relies on the same filter/wrap combination.
2. `render_texture.draw_array_fast`'s persistent-texture-reuse design (see
   `docs/ARCHITECTURE.md`'s "Non-obvious decisions" section) already avoids
   the driver double-buffering race for a texture recreated every frame;
   this plan doesn't introduce any new per-frame texture allocation, so the
   same guarantee should carry over unchanged, but is worth confirming once
   implemented.
