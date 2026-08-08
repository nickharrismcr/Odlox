package core

// Float_Array_3D_Object: a flat, row-major w*h*d buffer of f64s -- the
// 3D counterpart to Float_Array_Object (obj_float_array.odin), same
// conventions throughout (index order x-fastest via (z*height+y)*width+x,
// Get/Set return an ok bool on an out-of-range index rather than
// panicking, leaving raising a proper Lox runtime error to the caller in
// the vm package).
Float_Array_3D_Object :: struct {
	using obj:            Obj,
	width, height, depth: int,
	data:                 []f64,
}

make_float_array_3d_object :: proc(width, height, depth: int) -> ^Float_Array_3D_Object {
	o := new(Float_Array_3D_Object)
	o.obj.type = .Float_Array_3D
	o.width = width
	o.height = height
	o.depth = depth
	o.data = make([]f64, width * height * depth)
	return o
}

float_array_3d_in_bounds :: proc(f: ^Float_Array_3D_Object, x, y, z: int) -> bool {
	return x >= 0 && x < f.width && y >= 0 && y < f.height && z >= 0 && z < f.depth
}

float_array_3d_get :: proc(f: ^Float_Array_3D_Object, x, y, z: int) -> (value: f64, ok: bool) {
	if !float_array_3d_in_bounds(f, x, y, z) {
		return 0, false
	}
	return f.data[(z*f.height+y)*f.width+x], true
}

float_array_3d_set :: proc(f: ^Float_Array_3D_Object, x, y, z: int, value: f64) -> bool {
	if !float_array_3d_in_bounds(f, x, y, z) {
		return false
	}
	f.data[(z*f.height+y)*f.width+x] = value
	return true
}

float_array_3d_clear :: proc(f: ^Float_Array_3D_Object, value: f64) {
	for i in 0 ..< len(f.data) {
		f.data[i] = value
	}
}
