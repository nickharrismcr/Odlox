package core

import "core:encoding/endian"
import "core:fmt"

// pickle.odin: a standalone, plain-data serialiser for Value, used by the
// "pickle" native module (dumps/loads) and, later, the "process" module's
// pipe framing. Ported from glox's src/core/pickle.go -- same tag-based
// binary format in spirit (not required to be byte-compatible with glox's
// own encoding, since this only ever needs to round-trip between two
// odlox processes), same error-not-panic discipline (arbitrary/untrusted
// bytes go through decode, so truncated or malformed input must always
// come back as an error, never a crash), and the same cycle guard (a
// "currently visiting" set of object pointers, checked before recursing
// into a list/dict/instance's own children).

@(private = "file")
Pickle_Tag :: enum u8 {
	Nil = 1,
	Bool,
	Int,
	Float,
	String,
	List,
	Dict,
	Vec2,
	Vec3,
	Vec4,
	Instance,
}

@(private = "file")
Encoder :: struct {
	buf:      [dynamic]u8,
	visiting: map[rawptr]bool,
}

@(private = "file")
enc_byte :: proc(e: ^Encoder, b: u8) {
	append(&e.buf, b)
}

@(private = "file")
enc_u32 :: proc(e: ^Encoder, v: u32) {
	tmp: [4]u8
	endian.put_u32(tmp[:], .Little, v)
	append(&e.buf, ..tmp[:])
}

@(private = "file")
enc_u64 :: proc(e: ^Encoder, v: u64) {
	tmp: [8]u8
	endian.put_u64(tmp[:], .Little, v)
	append(&e.buf, ..tmp[:])
}

@(private = "file")
enc_f64 :: proc(e: ^Encoder, v: f64) {
	tmp: [8]u8
	endian.put_f64(tmp[:], .Little, v)
	append(&e.buf, ..tmp[:])
}

@(private = "file")
enc_string :: proc(e: ^Encoder, s: string) {
	enc_u32(e, u32(len(s)))
	append(&e.buf, ..transmute([]u8)s)
}

// pickle_encode serialises v into a byte string. Lists/dicts/instances
// are walked recursively; ok is false (with err set) if v contains a
// value this format can't represent (a function/class/module/file/
// native object) or a cycle -- never panics, since encode has to handle
// live, possibly-cyclic runtime values rather than just acyclic
// compile-time constants.
pickle_encode :: proc(v: Value) -> (data: []u8, err: string, ok: bool) {
	e: Encoder
	e.visiting = make(map[rawptr]bool)
	defer delete(e.visiting)
	err, ok = pickle_encode_value(&e, v)
	if !ok {
		delete(e.buf)
		return nil, err, false
	}
	return e.buf[:], "", true
}

@(private = "file")
pickle_encode_value :: proc(e: ^Encoder, v: Value) -> (err: string, ok: bool) {
	#partial switch v.type {
	case .Nil, .Undefined:
		enc_byte(e, u8(Pickle_Tag.Nil))
		return "", true
	case .Bool:
		enc_byte(e, u8(Pickle_Tag.Bool))
		enc_byte(e, 1 if v.data != 0 else 0)
		return "", true
	case .Int:
		enc_byte(e, u8(Pickle_Tag.Int))
		enc_u64(e, cast(u64)i64(as_int(v)))
		return "", true
	case .Float:
		enc_byte(e, u8(Pickle_Tag.Float))
		enc_f64(e, as_float(v))
		return "", true
	case .Vec2:
		vv := as_vec2(v)
		enc_byte(e, u8(Pickle_Tag.Vec2))
		enc_f64(e, vv.x)
		enc_f64(e, vv.y)
		return "", true
	case .Vec3:
		vv := as_vec3(v)
		enc_byte(e, u8(Pickle_Tag.Vec3))
		enc_f64(e, vv.x)
		enc_f64(e, vv.y)
		enc_f64(e, vv.z)
		return "", true
	case .Vec4:
		vv := as_vec4(v)
		enc_byte(e, u8(Pickle_Tag.Vec4))
		enc_f64(e, vv.x)
		enc_f64(e, vv.y)
		enc_f64(e, vv.z)
		enc_f64(e, vv.w)
		return "", true
	case .Obj:
		return pickle_encode_object(e, v)
	}
	return "cannot pickle value of this type", false
}

@(private = "file")
pickle_encode_object :: proc(e: ^Encoder, v: Value) -> (err: string, ok: bool) {
	#partial switch v.obj_type {
	case .String:
		s := as_string(v)
		enc_byte(e, u8(Pickle_Tag.String))
		enc_string(e, string_get(s))
		return "", true
	case .List:
		list := as_list(v)
		ptr := rawptr(list)
		if e.visiting[ptr] {
			return "cannot pickle cyclic structure", false
		}
		e.visiting[ptr] = true
		defer delete_key(&e.visiting, ptr)

		enc_byte(e, u8(Pickle_Tag.List))
		enc_byte(e, 1 if list.is_tuple else 0)
		enc_u32(e, u32(len(list.items)))
		for item in list.items {
			ierr, iok := pickle_encode_value(e, item)
			if !iok {
				return ierr, false
			}
		}
		return "", true
	case .Dict:
		dict := as_dict(v)
		ptr := rawptr(dict)
		if e.visiting[ptr] {
			return "cannot pickle cyclic structure", false
		}
		e.visiting[ptr] = true
		defer delete_key(&e.visiting, ptr)

		enc_byte(e, u8(Pickle_Tag.Dict))
		enc_u32(e, u32(len(dict.items)))
		for k, val in dict.items {
			enc_string(e, string_get(k))
			ierr, iok := pickle_encode_value(e, val)
			if !iok {
				return ierr, false
			}
		}
		return "", true
	case .Instance:
		inst := as_instance(v)
		ptr := rawptr(inst)
		if e.visiting[ptr] {
			return "cannot pickle cyclic structure", false
		}
		e.visiting[ptr] = true
		defer delete_key(&e.visiting, ptr)

		enc_byte(e, u8(Pickle_Tag.Instance))
		enc_string(e, string_get(inst.class.name))
		enc_u32(e, u32(len(inst.fields)))
		for k, val in inst.fields {
			enc_string(e, string_get(k))
			ierr, iok := pickle_encode_value(e, val)
			if !iok {
				return ierr, false
			}
		}
		return "", true
	}
	return fmt.tprintf("cannot pickle value of type %s", object_type_name(v.obj_type)), false
}

@(private = "file")
object_type_name :: proc(t: Object_Type) -> string {
	#partial switch t {
	case .Function:
		return "function"
	case .Closure:
		return "closure"
	case .Upvalue:
		return "upvalue"
	case .Native:
		return "builtin"
	case .Class:
		return "class"
	case .Bound_Method:
		return "bound method"
	case .Module:
		return "module"
	case .File:
		return "file"
	case .List_Iterator, .Int_Iterator, .String_Iterator:
		return "iterator"
	case:
		return "object"
	}
}

// -----------------------------------------------------------------------
// Decoding

@(private = "file")
Decoder :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file")
dec_byte :: proc(d: ^Decoder) -> (b: u8, ok: bool) {
	if d.pos >= len(d.data) {
		return 0, false
	}
	b = d.data[d.pos]
	d.pos += 1
	return b, true
}

@(private = "file")
dec_bytes :: proc(d: ^Decoder, n: int) -> (b: []u8, ok: bool) {
	if n < 0 || d.pos + n > len(d.data) {
		return nil, false
	}
	b = d.data[d.pos:d.pos + n]
	d.pos += n
	return b, true
}

@(private = "file")
dec_u32 :: proc(d: ^Decoder) -> (v: u32, ok: bool) {
	b, bok := dec_bytes(d, 4)
	if !bok {
		return 0, false
	}
	return endian.get_u32(b, .Little)
}

@(private = "file")
dec_u64 :: proc(d: ^Decoder) -> (v: u64, ok: bool) {
	b, bok := dec_bytes(d, 8)
	if !bok {
		return 0, false
	}
	return endian.get_u64(b, .Little)
}

@(private = "file")
dec_f64 :: proc(d: ^Decoder) -> (v: f64, ok: bool) {
	b, bok := dec_bytes(d, 8)
	if !bok {
		return 0, false
	}
	return endian.get_f64(b, .Little)
}

@(private = "file")
dec_string :: proc(d: ^Decoder) -> (s: string, ok: bool) {
	n, nok := dec_u32(d)
	if !nok {
		return "", false
	}
	b, bok := dec_bytes(d, int(n))
	if !bok {
		return "", false
	}
	return string(b), true
}

@(private = "file")
TRUNCATED :: "truncated pickle data"

// Class_Resolver looks up a live ^Class_Object by name so pickle_decode
// can reconstruct a pickled instance against a class already loaded in
// the decoding process -- pickle never ships class code (methods/super)
// over the wire, only field data. ctx is an opaque pointer threaded
// through from pickle_decode's own caller (typically a ^vm.VM, cast back
// on the resolver's own side) -- a plain function pointer rather than a
// closure over the caller's locals, since core sits below vm in the
// package graph and can't name ^vm.VM directly (same rawptr-boundary
// shape as core.Builtin_Fn; see obj_native.odin's doc comment).
Class_Resolver :: #type proc(name: string, ctx: rawptr) -> (^Class_Object, bool)

// pickle_decode deserialises data produced by pickle_encode into a Value.
// Returns an error rather than panicking on truncated or malformed input,
// since the input is untrusted (arbitrary bytes from a script, a file, or
// another process). Any collectible object this constructs (list/dict/
// instance) is freshly allocated but not yet linked into any VM's GC
// registry -- the caller adopts the whole result afterward (see
// vm/gc.odin's gc_adopt, used by pickle.loads and the process module's
// own recv()). resolve/ctx may both be nil if the caller knows the data
// can't contain an encoded instance (any Instance tag then fails to
// decode with a clear error rather than dereferencing a nil resolver).
pickle_decode :: proc(data: []u8, resolve: Class_Resolver, ctx: rawptr) -> (result: Value, err: string, ok: bool) {
	d := Decoder{data = data}
	return pickle_decode_value(&d, resolve, ctx)
}

@(private = "file")
pickle_decode_value :: proc(d: ^Decoder, resolve: Class_Resolver, ctx: rawptr) -> (result: Value, err: string, ok: bool) {
	tag_byte, tok := dec_byte(d)
	if !tok {
		return NIL_VALUE, TRUNCATED, false
	}
	switch Pickle_Tag(tag_byte) {
	case .Nil:
		return NIL_VALUE, "", true
	case .Bool:
		b, bok := dec_byte(d)
		if !bok {
			return NIL_VALUE, TRUNCATED, false
		}
		return make_bool_value(b != 0), "", true
	case .Int:
		n, nok := dec_u64(d)
		if !nok {
			return NIL_VALUE, TRUNCATED, false
		}
		return make_int_value(int(cast(i64)n)), "", true
	case .Float:
		f, fok := dec_f64(d)
		if !fok {
			return NIL_VALUE, TRUNCATED, false
		}
		return make_float_value(f), "", true
	case .String:
		s, sok := dec_string(d)
		if !sok {
			return NIL_VALUE, TRUNCATED, false
		}
		return make_string_value(s), "", true
	case .Vec2:
		x, xok := dec_f64(d)
		y, yok := dec_f64(d)
		if !xok || !yok {
			return NIL_VALUE, TRUNCATED, false
		}
		return make_vec2_value(x, y), "", true
	case .Vec3:
		x, xok := dec_f64(d)
		y, yok := dec_f64(d)
		z, zok := dec_f64(d)
		if !xok || !yok || !zok {
			return NIL_VALUE, TRUNCATED, false
		}
		return make_vec3_value(x, y, z), "", true
	case .Vec4:
		x, xok := dec_f64(d)
		y, yok := dec_f64(d)
		z, zok := dec_f64(d)
		w, wok := dec_f64(d)
		if !xok || !yok || !zok || !wok {
			return NIL_VALUE, TRUNCATED, false
		}
		return make_vec4_value(x, y, z, w), "", true
	case .List:
		tuple_flag, tfok := dec_byte(d)
		count, cok := dec_u32(d)
		if !tfok || !cok {
			return NIL_VALUE, TRUNCATED, false
		}
		items: [dynamic]Value
		for _ in 0 ..< count {
			item, ierr, iok := pickle_decode_value(d, resolve, ctx)
			if !iok {
				return NIL_VALUE, ierr, false
			}
			append(&items, item)
		}
		list := make_list_object(items, tuple_flag != 0)
		return make_object_value(&list.obj, tuple_flag != 0), "", true
	case .Dict:
		count, cok := dec_u32(d)
		if !cok {
			return NIL_VALUE, TRUNCATED, false
		}
		dict := make_dict_object()
		for _ in 0 ..< count {
			key, kok := dec_string(d)
			if !kok {
				return NIL_VALUE, TRUNCATED, false
			}
			val, verr, vok := pickle_decode_value(d, resolve, ctx)
			if !vok {
				return NIL_VALUE, verr, false
			}
			dict_set(dict, intern_string(key), val)
		}
		return make_object_value(&dict.obj), "", true
	case .Instance:
		class_name, cnok := dec_string(d)
		count, cok := dec_u32(d)
		if !cnok || !cok {
			return NIL_VALUE, TRUNCATED, false
		}
		fields := make(map[^String_Object]Value, count)
		for _ in 0 ..< count {
			key, kok := dec_string(d)
			if !kok {
				delete(fields)
				return NIL_VALUE, TRUNCATED, false
			}
			val, verr, vok := pickle_decode_value(d, resolve, ctx)
			if !vok {
				delete(fields)
				return NIL_VALUE, verr, false
			}
			fields[intern_string(key)] = val
		}
		// fields must be fully consumed above before any error return, so
		// the reader cursor lands correctly for whatever sibling value
		// comes next in the stream (e.g. inside an outer list).
		if resolve == nil {
			delete(fields)
			return NIL_VALUE, fmt.tprintf("cannot unpickle instance of class %q: no class resolver available", class_name), false
		}
		class, found := resolve(class_name, ctx)
		if !found {
			delete(fields)
			return NIL_VALUE, fmt.tprintf("cannot unpickle instance of unknown class %q", class_name), false
		}
		inst := make_instance_object(class)
		inst.fields = fields
		return make_object_value(&inst.obj), "", true
	}
	return NIL_VALUE, fmt.tprintf("unknown pickle tag %d", tag_byte), false
}
