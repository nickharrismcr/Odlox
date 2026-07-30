package natives

import "../core"
import "../vm"
import "core:os"
import "core:thread"

// gfx_lox_julia_array computes a Julia set fractal directly into a
// float_array's backing storage (each cell an RGB-encoded float, same
// convention as gfx.encode_rgba/decode_rgba), fast enough to recompute
// every frame for a real-time zoom/pan animation. A native free
// function on the "gfx" module, not a method on any object.
//
// Parallelized across OS threads (core:thread), one per available CPU
// core, splitting the image into flat row bands: every pixel's color
// depends only on its own coordinates and the shared read-only
// parameters, never on another pixel, so any way of partitioning the
// rows produces an identical result. Safe to do without touching the VM
// or GC at all: this whole native call is one opcode from the VM's
// perspective (maybe_collect_garbage only runs *between* opcodes -- see
// vm/gc.odin), and the worker threads only write to disjoint row ranges
// of arr.data, a plain slice, with no allocation or Lox-visible calls
// happening on those threads.
@(private = "package")
gfx_lox_julia_array :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 9 {
		vm.runtime_error(v, "lox_julia_array() expects 9 arguments (array, width, height, max_iterations, cx, cy, scale, xoffset, yoffset).")
		return core.NIL_VALUE
	}
	arr_val := v.stack[arg_stack_ptr]
	w_val := v.stack[arg_stack_ptr + 1]
	h_val := v.stack[arg_stack_ptr + 2]
	max_iter_val := v.stack[arg_stack_ptr + 3]
	cx_val := v.stack[arg_stack_ptr + 4]
	cy_val := v.stack[arg_stack_ptr + 5]
	scale_val := v.stack[arg_stack_ptr + 6]
	xoffset_val := v.stack[arg_stack_ptr + 7]
	yoffset_val := v.stack[arg_stack_ptr + 8]

	if arr_val.type != .Obj || arr_val.obj_type != .Float_Array {
		vm.runtime_error(v, "lox_julia_array() first argument must be a float_array.")
		return core.NIL_VALUE
	}
	if !core.is_int(w_val) {
		vm.runtime_error(v, "lox_julia_array() width argument must be an integer.")
		return core.NIL_VALUE
	}
	if !core.is_int(h_val) {
		vm.runtime_error(v, "lox_julia_array() height argument must be an integer.")
		return core.NIL_VALUE
	}
	if !core.is_int(max_iter_val) {
		vm.runtime_error(v, "lox_julia_array() max_iterations argument must be an integer.")
		return core.NIL_VALUE
	}
	if !core.is_float(cx_val) {
		vm.runtime_error(v, "lox_julia_array() cx argument must be a float.")
		return core.NIL_VALUE
	}
	if !core.is_float(cy_val) {
		vm.runtime_error(v, "lox_julia_array() cy argument must be a float.")
		return core.NIL_VALUE
	}
	if !core.is_float(scale_val) {
		vm.runtime_error(v, "lox_julia_array() scale argument must be a float.")
		return core.NIL_VALUE
	}
	if !core.is_float(xoffset_val) {
		vm.runtime_error(v, "lox_julia_array() xoffset argument must be a float.")
		return core.NIL_VALUE
	}
	if !core.is_float(yoffset_val) {
		vm.runtime_error(v, "lox_julia_array() yoffset argument must be a float.")
		return core.NIL_VALUE
	}

	arr := core.as_float_array(arr_val)
	width := core.as_int(w_val)
	height := core.as_int(h_val)
	max_iteration := core.as_int(max_iter_val)
	cx := f32(core.as_float(cx_val))
	cy := f32(core.as_float(cy_val))
	scale := f32(core.as_float(scale_val))
	xoffset := f32(core.as_float(xoffset_val))
	yoffset := f32(core.as_float(yoffset_val))

	color_table := julia_color_table(max_iteration)
	defer delete(color_table)

	max_dim := f32(max(width, height))
	scale_over_max_dim := scale / max_dim
	half_height := f32(height) / 2
	half_width := f32(width) / 2

	num_workers := clamp(os.get_processor_core_count(), 1, height)
	blocks := make([]Julia_Block, num_workers)
	defer delete(blocks)
	threads := make([]^thread.Thread, num_workers)
	defer delete(threads)

	rows_per_worker := (height + num_workers - 1) / num_workers
	for i in 0 ..< num_workers {
		start_row := i * rows_per_worker
		end_row := min(start_row + rows_per_worker, height)
		blocks[i] = Julia_Block {
			data                = arr.data,
			array_width         = arr.width,
			start_row           = start_row,
			end_row             = end_row,
			width               = width,
			max_iteration       = max_iteration,
			cx                  = cx,
			cy                  = cy,
			xoffset             = xoffset,
			yoffset             = yoffset,
			color_table         = color_table,
			scale_over_max_dim  = scale_over_max_dim,
			half_height         = half_height,
			half_width          = half_width,
		}
		threads[i] = thread.create_and_start_with_poly_data(&blocks[i], julia_calc_block)
	}
	// destroy() waits for the thread to finish before freeing it, so this
	// loop is also the join point -- every worker has completed, and
	// arr.data is fully populated, by the time it exits.
	for t in threads {
		thread.destroy(t)
	}
	return core.NIL_VALUE
}

// Julia_Block is one worker's share of the image (a contiguous row
// range) plus the read-only parameters every worker needs -- passed as a
// single pointer to create_and_start_with_poly_data (the struct itself
// is too large for that proc's inline poly-data slots, which cap out at
// 8 pointer-widths).
@(private = "file")
Julia_Block :: struct {
	data:                []f64, // arr's own backing slice -- shared, but each worker only ever writes its own start_row..<end_row
	array_width:         int,
	start_row, end_row:  int,
	width:               int,
	max_iteration:       int,
	cx, cy:              f32,
	xoffset, yoffset:    f32,
	color_table:         []f64, // shared, read-only
	scale_over_max_dim:  f32,
	half_height:         f32,
	half_width:          f32,
}

@(private = "file")
julia_calc_block :: proc(b: ^Julia_Block) {
	for row in b.start_row ..< b.end_row {
		y0 := b.scale_over_max_dim * (f32(row) - b.half_height) + b.yoffset
		for col in 0 ..< b.width {
			x0 := b.scale_over_max_dim * (f32(col) - b.half_width) + b.xoffset
			zx, zy := x0, y0
			iteration := 0
			for (zx * zx + zy * zy <= 4.0) && (iteration < b.max_iteration) {
				xtemp := zx * zx - zy * zy + b.cx
				zy = 2 * zx * zy + b.cy
				zx = xtemp
				iteration += 1
			}
			b.data[row * b.array_width + col] = b.color_table[iteration]
		}
	}
}

// julia_color_table precomputes an RGB-encoded-float color per possible
// iteration count, so the main loop above does a table lookup instead of
// recomputing the color band math per pixel. Six-band electric-blue ->
// cyan -> green -> yellow -> red -> magenta -> white gradient; points
// still inside the set (iteration == max_iteration) are black.
@(private = "file")
julia_color_table :: proc(max_iteration: int) -> []f64 {
	table := make([]f64, max_iteration + 1)
	for i in 0 ..= max_iteration {
		if i == max_iteration {
			table[i] = encode_rgb(0, 0, 0)
			continue
		}
		t := f64(i) / f64(max_iteration)
		r, g, b: int
		switch {
		case t < 0.16:
			ratio := t / 0.16
			r = int(ratio * 50)
			g = int(100 + ratio * 155)
			b = 255
		case t < 0.32:
			ratio := (t - 0.16) / 0.16
			r = int(50 * (1 - ratio))
			g = 255
			b = int(255 * (1 - ratio))
		case t < 0.48:
			ratio := (t - 0.32) / 0.16
			r = int(ratio * 255)
			g = 255
			b = 0
		case t < 0.64:
			ratio := (t - 0.48) / 0.16
			r = 255
			g = int(255 * (1 - ratio))
			b = 0
		case t < 0.80:
			ratio := (t - 0.64) / 0.16
			r = 255
			g = 0
			b = int(ratio * 255)
		case:
			ratio := (t - 0.80) / 0.20
			r = 255
			g = int(ratio * 255)
			b = 255
		}
		table[i] = encode_rgb(clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255))
	}
	return table
}

// encode_rgb mirrors gfx.encode_rgba's own packing (natives/gfx.odin's
// gfx_encode_rgba) minus the alpha channel and the Lox-callable argument
// marshalling -- this is an internal helper called per table entry, not
// itself exposed to scripts.
@(private = "file")
encode_rgb :: proc(r, g, b: int) -> f64 {
	return f64(u32(r) << 16 | u32(g) << 8 | u32(b))
}
