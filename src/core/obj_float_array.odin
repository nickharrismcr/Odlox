package core

// Float_Array_Object: a flat, row-major w*h buffer of f64s. Get/Set
// return an ok bool on an out-of-range index rather than panicking,
// leaving raising a proper Lox runtime error to the caller (vm
// package), consistent with every other bounds check in this
// interpreter.
Float_Array_Object :: struct {
	using obj:     Obj,
	width, height: int,
	data:          []f64,
}

make_float_array_object :: proc(width, height: int) -> ^Float_Array_Object {
	o := new(Float_Array_Object)
	o.obj.type = .Float_Array
	o.width = width
	o.height = height
	o.data = make([]f64, width * height)
	return o
}

float_array_in_bounds :: proc(f: ^Float_Array_Object, x, y: int) -> bool {
	return x >= 0 && x < f.width && y >= 0 && y < f.height
}

float_array_get :: proc(f: ^Float_Array_Object, x, y: int) -> (value: f64, ok: bool) {
	if !float_array_in_bounds(f, x, y) {
		return 0, false
	}
	return f.data[y * f.width + x], true
}

float_array_set :: proc(f: ^Float_Array_Object, x, y: int, value: f64) -> bool {
	if !float_array_in_bounds(f, x, y) {
		return false
	}
	f.data[y * f.width + x] = value
	return true
}

float_array_clear :: proc(f: ^Float_Array_Object, value: f64) {
	for i in 0 ..< len(f.data) {
		f.data[i] = value
	}
}
