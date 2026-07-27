package natives

import "../core"
import "../vm"

// gfx_lox_julia_array: ported from glox's builtin_draw.go's
// JuliaArrayBuiltIn -- computes a Julia set fractal directly into a
// float_array's backing storage (each cell an RGB-encoded float, same
// convention as gfx.encode_rgba/decode_rgba), fast enough to recompute
// every frame for a real-time zoom/pan animation (lox_examples/julia.lox).
// A native free function on the "gfx" module, not a method on any
// object, matching glox's own registration
// (defineBuiltIn(vm, "gfx", "lox_julia_array", ...), src/vm/builtin.go).
//
// Deliberately single-threaded here, unlike glox's own version, which
// splits the image into blocks and computes them on separate goroutines.
// That's a pure wall-clock-speed optimization with no effect on the
// output -- every pixel's color depends only on its own coordinates and
// the shared parameters, never on another pixel -- and this port's own
// scope already excludes VM-level threading entirely (see README.md's
// Scope section). If real-time performance on a large canvas ever needs
// it, this loop is an easy target to parallelize later (e.g. via
// core:thread, entirely internal to this one native call, since it never
// touches the VM/GC mid-computation) without changing the result.
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

	for row in 0 ..< height {
		y0 := scale_over_max_dim * (f32(row) - half_height) + yoffset
		for col in 0 ..< width {
			x0 := scale_over_max_dim * (f32(col) - half_width) + xoffset
			zx, zy := x0, y0
			iteration := 0
			for (zx * zx + zy * zy <= 4.0) && (iteration < max_iteration) {
				xtemp := zx * zx - zy * zy + cx
				zy = 2 * zx * zy + cy
				zx = xtemp
				iteration += 1
			}
			arr.data[row * arr.width + col] = color_table[iteration]
		}
	}
	return core.NIL_VALUE
}

// julia_color_table precomputes an RGB-encoded-float color per possible
// iteration count, so the main loop above does a table lookup instead of
// recomputing the color band math per pixel. Ported from glox's own
// precomputeColorTable -- same six-band electric-blue -> cyan -> green
// -> yellow -> red -> magenta -> white gradient, points still inside the
// set (iteration == max_iteration) black.
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
