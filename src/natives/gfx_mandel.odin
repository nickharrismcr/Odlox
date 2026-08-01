package natives

import "../core"
import "../vm"
import "core:math"
import "core:os"
import "core:thread"

// gfx_lox_mandel_array computes a Mandelbrot set fractal directly into
// a float_array's backing storage, fast enough to recompute every frame
// for a real-time deep-zoom animation. Registered under "gfx" like
// lox_julia_array -- see gfx_julia.odin's own header comment for the
// registration convention this shares.
//
// Argument order is (array, height, width, max_iterations, xoffset,
// yoffset, scale) -- height before width, offsets before scale. Note
// this differs from lox_julia_array's own (array, width, height, ...,
// scale, xoffset, yoffset) order.
//
// f64 precision throughout (unlike lox_julia_array's f32) is
// load-bearing: a continuous zoom (`scale` shrinking every frame) needs
// that precision for the effect not to visibly degrade into blocky
// artifacts partway through a long zoom.
//
// Parallelized the same way as lox_julia_array (see that file's header
// comment for the full reasoning: safe without VM/GC interaction since
// this whole call is one opcode and no worker thread allocates or
// touches anything GC-tracked) -- flat row bands, one per CPU core,
// each worker writing only its own disjoint row range.
@(private = "package")
gfx_lox_mandel_array :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 7 {
		vm.runtime_error(v, "lox_mandel_array() expects 7 arguments (array, height, width, max_iterations, xoffset, yoffset, scale).")
		return core.NIL_VALUE
	}
	arr_val := v.stack[arg_stack_ptr]
	h_val := v.stack[arg_stack_ptr + 1]
	w_val := v.stack[arg_stack_ptr + 2]
	max_iter_val := v.stack[arg_stack_ptr + 3]
	xoffset_val := v.stack[arg_stack_ptr + 4]
	yoffset_val := v.stack[arg_stack_ptr + 5]
	scale_val := v.stack[arg_stack_ptr + 6]

	if arr_val.type != .Obj || arr_val.obj_type != .Float_Array {
		vm.runtime_error(v, "lox_mandel_array() first argument must be a float_array.")
		return core.NIL_VALUE
	}
	if !core.is_int(h_val) {
		vm.runtime_error(v, "lox_mandel_array() height argument must be an integer.")
		return core.NIL_VALUE
	}
	if !core.is_int(w_val) {
		vm.runtime_error(v, "lox_mandel_array() width argument must be an integer.")
		return core.NIL_VALUE
	}
	if !core.is_int(max_iter_val) {
		vm.runtime_error(v, "lox_mandel_array() max_iterations argument must be an integer.")
		return core.NIL_VALUE
	}
	if !core.is_float(xoffset_val) {
		vm.runtime_error(v, "lox_mandel_array() xoffset argument must be a float.")
		return core.NIL_VALUE
	}
	if !core.is_float(yoffset_val) {
		vm.runtime_error(v, "lox_mandel_array() yoffset argument must be a float.")
		return core.NIL_VALUE
	}
	if !core.is_float(scale_val) {
		vm.runtime_error(v, "lox_mandel_array() scale argument must be a float.")
		return core.NIL_VALUE
	}

	arr := core.as_float_array(arr_val)
	height := core.as_int(h_val)
	width := core.as_int(w_val)
	max_iteration := core.as_int(max_iter_val)
	xoffset := core.as_float(xoffset_val)
	yoffset := core.as_float(yoffset_val)
	scale := core.as_float(scale_val)

	max_dim := f64(max(width, height))
	scale_over_max_dim := scale / max_dim
	half_height := f64(height) / 2
	half_width := f64(width) / 2
	is_deep_zoom := scale < 1e-5

	num_workers := clamp(os.get_processor_core_count(), 1, height)
	blocks := make([]Mandel_Block, num_workers)
	defer delete(blocks)
	threads := make([]^thread.Thread, num_workers)
	defer delete(threads)

	rows_per_worker := (height + num_workers - 1) / num_workers
	for i in 0 ..< num_workers {
		start_row := i * rows_per_worker
		end_row := min(start_row + rows_per_worker, height)
		blocks[i] = Mandel_Block {
			data                = arr.data,
			array_width         = arr.width,
			start_row           = start_row,
			end_row             = end_row,
			width               = width,
			max_iteration       = max_iteration,
			xoffset             = xoffset,
			yoffset             = yoffset,
			scale_over_max_dim  = scale_over_max_dim,
			half_height         = half_height,
			half_width          = half_width,
			is_deep_zoom        = is_deep_zoom,
		}
		threads[i] = thread.create_and_start_with_poly_data(&blocks[i], mandel_calc_block)
	}
	for t in threads {
		thread.destroy(t) // waits for the worker, then frees it -- also the join point
	}
	return core.NIL_VALUE
}

@(private = "file")
Mandel_Block :: struct {
	data:                []f64, // arr's own backing slice -- shared, but each worker only ever writes its own start_row..<end_row
	array_width:         int,
	start_row, end_row:  int,
	width:               int,
	max_iteration:       int,
	xoffset, yoffset:    f64,
	scale_over_max_dim:  f64,
	half_height:         f64,
	half_width:          f64,
	is_deep_zoom:        bool,
}

// mandel_calc_block has two performance-critical early-exit paths
// (neither changes the *result*, only how fast a point known to never
// escape gets classified):
//
//   - Main-cardioid / period-2-bulb test: closed-form membership tests
//     for the two largest regions of the set, skipping the iteration
//     loop entirely for any point they cover. Skipped once the zoom is
//     deep enough (scale < 1e-5) that the whole visible view can sit
//     inside one of those regions anyway, at which point the test
//     itself becomes the bottleneck for no benefit.
//   - Periodicity detection: once a point survives 20 iterations without
//     escaping, start comparing its current (x, y) against the values
//     one and two iterations back. A Mandelbrot orbit that returns
//     arbitrarily close to a previous value is provably cyclic and will
//     never escape, so it's reclassified as max_iteration (in the set)
//     immediately instead of spinning for however many iterations
//     remain.
@(private = "file")
mandel_calc_block :: proc(b: ^Mandel_Block) {
	for row in b.start_row ..< b.end_row {
		y0 := b.scale_over_max_dim * (f64(row) - b.half_height) + b.yoffset
		for col in 0 ..< b.width {
			x0 := b.scale_over_max_dim * (f64(col) - b.half_width) + b.xoffset

			x, y := 0.0, 0.0
			iteration := 0

			if !b.is_deep_zoom && (mandel_in_main_cardioid(x0, y0) || mandel_in_period2_bulb(x0, y0)) {
				iteration = b.max_iteration
			} else {
				periodicity_threshold :: 20
				periodicity_epsilon :: 1e-10

				prev_x, prev_y: f64
				prev2_x, prev2_y: f64
				periodicity_check_enabled := false

				for (x * x + y * y <= 4.0) && (iteration < b.max_iteration) {
					xtemp := x * x - y * y + x0
					y = 2.0 * x * y + y0
					x = xtemp
					iteration += 1

					if iteration >= periodicity_threshold {
						if !periodicity_check_enabled {
							periodicity_check_enabled = true
							prev_x, prev_y = x, y
							prev2_x, prev2_y = x, y
						} else {
							if abs(x - prev_x) < periodicity_epsilon && abs(y - prev_y) < periodicity_epsilon {
								iteration = b.max_iteration
								break
							}
							if abs(x - prev2_x) < periodicity_epsilon && abs(y - prev2_y) < periodicity_epsilon {
								iteration = b.max_iteration
								break
							}
							prev2_x, prev2_y = prev_x, prev_y
							prev_x, prev_y = x, y
						}
					}
				}
			}

			if iteration >= b.max_iteration {
				// Interior of the set: never escaped (or provably never
				// will, via the two early-exit paths above) -- flat black.
				b.data[row * b.array_width + col] = 0
			} else {
				b.data[row * b.array_width + col] = mandel_palette_color(mandel_smooth_iteration(iteration, x, y))
			}
		}
	}
}

@(private = "file")
mandel_in_main_cardioid :: proc(x, y: f64) -> bool {
	dx := x - 0.25
	q := dx * dx + y * y
	return q * (q + dx) < 0.25 * y * y
}

@(private = "file")
mandel_in_period2_bulb :: proc(x, y: f64) -> bool {
	dx := x + 1.0
	return dx * dx + y * y < 0.0625
}

// mandel_smooth_iteration turns the discrete escape-time iteration count
// into a continuous value (the "normalized"/"renormalized" iteration
// count -- standard technique, see e.g. the Wikipedia Mandelbrot set
// article's "Continuous (smooth) coloring" section) using the (x, y)
// the orbit actually escaped at. Two neighboring pixels that escape one
// iteration apart get a continuous, not integer-stepped, color as a
// result -- this is what removes the speckly noise a purely
// integer-iteration palette shows deep in a zoom, where escape times
// between adjacent pixels can differ chaotically near the boundary.
//
// Only called for points that actually escaped through the main loop
// (x*x+y*y > 4.0 on exit), so log_zn > log(2) always and neither log
// call can hit a non-positive argument.
@(private = "file")
mandel_smooth_iteration :: proc(iteration: int, x, y: f64) -> f64 {
	ln_2 :: 0.6931471805599453
	log_zn := math.ln(x * x + y * y) / 2
	nu := math.ln(log_zn / ln_2) / ln_2
	return f64(iteration) + 1 - nu
}

// mandel_palette_color maps a continuous escape value to a color via a
// cheap cosine palette (Inigo Quilez's `a + b*cos(2π(c*t+d))` formula,
// one cos() per channel, a=b=0.5 keeps the result in [0,1]). No table,
// no branching, and -- unlike a discrete banded palette -- continuous in
// t, so it doesn't introduce its own stepping on top of whatever the
// escape-time values already do. frequency controls how many full color
// cycles happen per unit of smooth iteration count; the per-channel
// phase offsets (0, 1/3, 2/3) spread the three channels evenly around
// the cycle instead of moving in lockstep toward grey.
@(private = "file")
mandel_palette_color :: proc(smooth_iteration: f64) -> f64 {
	// Lower frequency = a given escape-time difference between neighboring
	// pixels rotates less far around the color wheel, which is what
	// actually controls perceived noise near the boundary (where escape
	// time itself varies chaotically pixel-to-pixel) -- not something a
	// discrete/continuous choice alone fixes. 0.025 caps the color swing
	// from a 1-iteration difference at roughly a fifth of the channel
	// range (derivative bound is pi*frequency*255 =~ 20 out of 255).
	frequency :: 0.025
	t := smooth_iteration * frequency
	r := 0.5 + 0.5 * math.cos(math.TAU * (t + 0.0))
	g := 0.5 + 0.5 * math.cos(math.TAU * (t + 1.0 / 3.0))
	b := 0.5 + 0.5 * math.cos(math.TAU * (t + 2.0 / 3.0))
	return mandel_encode_rgb(int(r * 255), int(g * 255), int(b * 255))
}

// mandel_encode_rgb mirrors gfx_julia.odin's own encode_rgb (itself a
// mirror of gfx.encode_rgba's packing) -- duplicated rather than shared,
// not a hard coupling worth introducing an abstraction to preserve.
@(private = "file")
mandel_encode_rgb :: proc(r, g, b: int) -> f64 {
	return f64(u32(r) << 16 | u32(g) << 8 | u32(b))
}
