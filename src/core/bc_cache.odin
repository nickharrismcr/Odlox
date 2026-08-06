package core

import "core:encoding/endian"
import "core:strings"

// bc_cache.odin: serializer/deserializer for a compiled module's
// Function_Object tree -- the format vm/bc_cache.odin's file-backed
// bytecode cache reads and writes (see docs/plans/bytecode-cache.md for
// the full design). Same tag-dispatch, length-prefixed, bounds-checked
// shape as pickle.odin's Value serializer, applied to a narrower value
// population: compile-time constants only (Int/Float/String/Function --
// nothing else is ever a Chunk constant), not arbitrary runtime values.
// Int/float constants round-trip the full 8-byte payload with no
// truncation.
//
// Same error-not-panic discipline as pickle.odin throughout: a `.lxc`
// file is untrusted input (could be corrupt, truncated, or written by a
// different schema version), so every decode step is bounds-checked and
// every failure comes back as ok=false, never a crash. No decode step
// ever pre-sizes an allocation from an attacker/corruption-controlled
// count -- every `[dynamic]` collection below starts at zero capacity
// and grows one bounds-checked element at a time via `append`, so a
// garbage-huge count fails on the very next out-of-range read instead of
// attempting a huge allocation. The one exception, `property_caches` (a
// bare count with no per-entry payload to bound it against), gets an
// explicit cap instead -- see BC_CACHE_MAX_PROPERTY_CACHES.

BC_CACHE_MAGIC :: [4]u8{'O', 'L', 'X', 'C'}
BC_CACHE_VERSION :: u16(2) // bumped: inlining Vec2/3/4 into Value added new Op_Code variants
                           // mid-enum (Set_*_Vec_Field -- see docs/plans/inline-vec-value.md),
                           // shifting every later opcode's numeric value -- a v1 cache would
                           // misdecode, not just miss.

// BC_CACHE_MAX_PROPERTY_CACHES: chunk_add_property_cache (chunk.odin)
// returns a u8 index, so no real compiler output can ever produce more
// than 256 property-cache slots in one chunk. property_cache_count is
// the one field in this format with no accompanying per-entry bytes to
// bound a decode loop against (it's a count only -- see chunk_serialise
// below), so a corrupted/malicious count must be rejected before
// `make([dynamic]Property_Cache, count)` runs, not caught by it.
BC_CACHE_MAX_PROPERTY_CACHES :: 256

Bc_Decode_Error :: enum {
	None,
	Bad_Magic,   // not one of our files at all -- the common "no cache yet" case
	Bad_Version, // a real cache of ours, written by an older/newer schema
	Malformed,   // truncated, or fails a bounds/sanity check partway through
}

@(private = "file")
Bc_Value_Tag :: enum u8 {
	Int      = 1,
	Float    = 2,
	String   = 3,
	Function = 4,
}

// -----------------------------------------------------------------------
// Encoding

@(private = "file")
Bc_Encoder :: struct {
	buf: [dynamic]u8,
}

@(private = "file")
bc_enc_byte :: proc(e: ^Bc_Encoder, b: u8) {
	append(&e.buf, b)
}

@(private = "file")
bc_enc_u32 :: proc(e: ^Bc_Encoder, v: u32) {
	tmp: [4]u8
	endian.put_u32(tmp[:], .Little, v)
	append(&e.buf, ..tmp[:])
}

@(private = "file")
bc_enc_u64 :: proc(e: ^Bc_Encoder, v: u64) {
	tmp: [8]u8
	endian.put_u64(tmp[:], .Little, v)
	append(&e.buf, ..tmp[:])
}

@(private = "file")
bc_enc_bytes :: proc(e: ^Bc_Encoder, b: []u8) {
	append(&e.buf, ..b)
}

@(private = "file")
bc_enc_string :: proc(e: ^Bc_Encoder, s: string) {
	bc_enc_u32(e, u32(len(s)))
	append(&e.buf, ..transmute([]u8)s)
}

@(private = "file")
bc_enc_chunk :: proc(e: ^Bc_Encoder, c: ^Chunk) -> bool {
	bc_enc_u32(e, u32(len(c.code)))
	bc_enc_bytes(e, c.code[:])

	bc_enc_u32(e, u32(len(c.lines)))
	for line in c.lines {
		bc_enc_u32(e, u32(line))
	}

	bc_enc_u32(e, u32(len(c.constants)))
	for v in c.constants {
		if !bc_enc_value(e, v) {
			return false
		}
	}

	bc_enc_string(e, c.filename)

	bc_enc_u32(e, u32(c.global_count))
	bc_enc_u32(e, u32(len(c.global_names)))
	for name in c.global_names {
		bc_enc_string(e, name)
	}

	// Count only -- class/method are live runtime state (a ^Class_Object
	// pointer, a resolved method Value), never written to disk. Decodes
	// to a zero-valued array of this exact length (see chunk.odin's
	// Property_Cache doc comment: class == nil means "never populated,"
	// exactly a fresh compile's own starting state) -- the length itself
	// matters because Get_Property/Invoke index this array with a u8
	// operand baked into the bytecode at compile time.
	bc_enc_u32(e, u32(len(c.property_caches)))
	return true
}

// bc_enc_value encodes one Chunk constant. Only Int/Float/String/
// Function ever appear in a constant pool -- Bool/Nil have dedicated
// opcodes and are never constant-pool entries, and no other Object_Type
// is ever passed to chunk_add_constant anywhere in the compiler. A
// value that doesn't match one of these four shapes means the caller
// handed this a live runtime Value by mistake, not real compiler
// output -- reported as a plain encode failure, not a panic.
@(private = "file")
bc_enc_value :: proc(e: ^Bc_Encoder, v: Value) -> bool {
	#partial switch v.type {
	case .Int:
		bc_enc_byte(e, u8(Bc_Value_Tag.Int))
		bc_enc_u64(e, v.data)
		return true
	case .Float:
		bc_enc_byte(e, u8(Bc_Value_Tag.Float))
		bc_enc_u64(e, v.data)
		return true
	case .Obj:
		#partial switch v.obj_type {
		case .String:
			bc_enc_byte(e, u8(Bc_Value_Tag.String))
			bc_enc_string(e, string_get(as_string(v)))
			return true
		case .Function:
			bc_enc_byte(e, u8(Bc_Value_Tag.Function))
			return bc_enc_function(e, as_function(v))
		}
	}
	return false
}

@(private = "file")
bc_enc_function :: proc(e: ^Bc_Encoder, fn: ^Function_Object) -> bool {
	bc_enc_string(e, fn.name.chars)
	bc_enc_u32(e, u32(fn.arity))
	bc_enc_u32(e, u32(fn.min_arity))
	bc_enc_byte(e, 1 if fn.is_variadic else 0)
	bc_enc_u32(e, u32(fn.upvalue_count))
	return bc_enc_chunk(e, fn.chunk)
}

// function_serialise encodes fn and, recursively, every nested
// Function_Object reachable through its own chunk.constants (nested
// functions/closures are always constants of their enclosing chunk --
// see compiler/functions.odin's emit_closure -- so the whole compiled
// unit is one tree reachable from a single top-level Function_Object,
// same as main.odin's own program_stats already walks for `--info`).
// Never touches fn.environment -- that's a runtime-only back-pointer;
// the caller must wire it up on every node of a decoded tree after a
// successful function_deserialise (see that proc's own doc comment for
// why every node, not just the root). ok is false only if fn's constant
// pool contains something other than Int/Float/String/Function -- not
// expected from any real compiler output, checked rather than assumed.
function_serialise :: proc(fn: ^Function_Object) -> (data: []u8, ok: bool) {
	e: Bc_Encoder
	magic := BC_CACHE_MAGIC
	bc_enc_bytes(&e, magic[:])
	bc_enc_byte(&e, u8(BC_CACHE_VERSION & 0xFF))
	bc_enc_byte(&e, u8((BC_CACHE_VERSION >> 8) & 0xFF))
	if !bc_enc_function(&e, fn) {
		delete(e.buf)
		return nil, false
	}
	return e.buf[:], true
}

// -----------------------------------------------------------------------
// Decoding

@(private = "file")
Bc_Decoder :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file")
bc_dec_byte :: proc(d: ^Bc_Decoder) -> (b: u8, ok: bool) {
	if d.pos >= len(d.data) {
		return 0, false
	}
	b = d.data[d.pos]
	d.pos += 1
	return b, true
}

@(private = "file")
bc_dec_bytes :: proc(d: ^Bc_Decoder, n: int) -> (b: []u8, ok: bool) {
	if n < 0 || d.pos + n > len(d.data) {
		return nil, false
	}
	b = d.data[d.pos:d.pos + n]
	d.pos += n
	return b, true
}

@(private = "file")
bc_dec_u32 :: proc(d: ^Bc_Decoder) -> (v: u32, ok: bool) {
	b, bok := bc_dec_bytes(d, 4)
	if !bok {
		return 0, false
	}
	return endian.get_u32(b, .Little)
}

@(private = "file")
bc_dec_u64 :: proc(d: ^Bc_Decoder) -> (v: u64, ok: bool) {
	b, bok := bc_dec_bytes(d, 8)
	if !bok {
		return 0, false
	}
	return endian.get_u64(b, .Little)
}

@(private = "file")
bc_dec_string :: proc(d: ^Bc_Decoder) -> (s: string, ok: bool) {
	n, nok := bc_dec_u32(d)
	if !nok {
		return "", false
	}
	b, bok := bc_dec_bytes(d, int(n))
	if !bok {
		return "", false
	}
	return string(b), true
}

@(private = "file")
bc_dec_value :: proc(d: ^Bc_Decoder) -> (v: Value, ok: bool) {
	tag_byte, tok := bc_dec_byte(d)
	if !tok {
		return NIL_VALUE, false
	}
	switch Bc_Value_Tag(tag_byte) {
	case .Int:
		n, nok := bc_dec_u64(d)
		if !nok {
			return NIL_VALUE, false
		}
		r: Value
		r.type = .Int
		r.data = n
		return r, true
	case .Float:
		n, nok := bc_dec_u64(d)
		if !nok {
			return NIL_VALUE, false
		}
		r: Value
		r.type = .Float
		r.data = n
		return r, true
	case .String:
		// make_interned_string_value (not make_string_value): a chunk's
		// constant pool holds both literal string values AND identifier
		// names (property/method/class/module names -- compiled via
		// make_interned_string_value too, see compiler/expr.odin,stmt.odin),
		// indistinguishable once serialized down to a generic .String
		// constant tag. Always interning on cache-load keeps identifier
		// constants correct (map-keyed lookups need the canonical pointer
		// regardless of length); the cost is a long string *literal*
		// staying permanently interned when loaded from a bytecode cache,
		// same as every string did before STRING_INTERN_MAX_LEN existed,
		// rather than getting the length-split treatment a fresh compile
		// of the same source would give it -- acceptable since a literal's
		// content is bounded by source size, not external runtime data
		// (the actual leak source the split exists for). s itself is a
		// slice into d.data and never retained past this call, so no
		// explicit clone is needed here.
		s, sok := bc_dec_string(d)
		if !sok {
			return NIL_VALUE, false
		}
		return make_interned_string_value(s), true
	case .Function:
		fn, fok := bc_dec_function(d)
		if !fok {
			return NIL_VALUE, false
		}
		return make_object_value(&fn.obj), true
	}
	return NIL_VALUE, false
}

@(private = "file")
bc_dec_function :: proc(d: ^Bc_Decoder) -> (fn: ^Function_Object, ok: bool) {
	name, nok := bc_dec_string(d)
	arity, aok := bc_dec_u32(d)
	min_arity, mok := bc_dec_u32(d)
	is_variadic_byte, vok := bc_dec_byte(d)
	upvalue_count, uok := bc_dec_u32(d)
	if !nok || !aok || !mok || !vok || !uok {
		return nil, false
	}
	chunk, cok := bc_dec_chunk(d)
	if !cok {
		return nil, false
	}

	f := new(Function_Object)
	f.obj.type = .Function
	f.name = intern_string(name) // clones internally on first sight
	f.arity = int(arity)
	f.min_arity = int(min_arity)
	f.is_variadic = is_variadic_byte != 0
	f.upvalue_count = int(upvalue_count)
	f.chunk = chunk
	// f.environment intentionally left nil here -- see
	// function_deserialise's own doc comment; the caller must wire it up
	// on every node of the returned tree before this function is
	// callable (Get_Global/Set_Global resolve through whichever frame's
	// own fn.environment is currently executing, not just the root's).
	return f, true
}

@(private = "file")
bc_dec_chunk :: proc(d: ^Bc_Decoder) -> (c: ^Chunk, ok: bool) {
	code_len, cl_ok := bc_dec_u32(d)
	if !cl_ok {
		return nil, false
	}
	code_bytes, cb_ok := bc_dec_bytes(d, int(code_len))
	if !cb_ok {
		return nil, false
	}

	lines_count, lc_ok := bc_dec_u32(d)
	if !lc_ok {
		return nil, false
	}
	lines: [dynamic]int
	for _ in 0 ..< lines_count {
		line, lok := bc_dec_u32(d)
		if !lok {
			delete(lines)
			return nil, false
		}
		append(&lines, int(line))
	}

	constants_count, cc_ok := bc_dec_u32(d)
	if !cc_ok {
		delete(lines)
		return nil, false
	}
	constants: [dynamic]Value
	for _ in 0 ..< constants_count {
		v, vok := bc_dec_value(d)
		if !vok {
			delete(lines)
			delete(constants)
			return nil, false
		}
		append(&constants, v)
	}

	filename_raw, fok := bc_dec_string(d)
	if !fok {
		delete(lines)
		delete(constants)
		return nil, false
	}

	global_count, gc_ok := bc_dec_u32(d)
	if !gc_ok {
		delete(lines)
		delete(constants)
		return nil, false
	}
	global_names_count, gnc_ok := bc_dec_u32(d)
	if !gnc_ok {
		delete(lines)
		delete(constants)
		return nil, false
	}
	global_names: [dynamic]string
	for _ in 0 ..< global_names_count {
		name, nok := bc_dec_string(d)
		if !nok {
			delete(lines)
			delete(constants)
			delete(global_names)
			return nil, false
		}
		// Unlike String constants, global_names entries aren't interned
		// -- Chunk owns this string directly (see chunk.odin), so it
		// must be a real clone, not a slice into the caller's (soon to
		// be freed) input buffer.
		append(&global_names, strings.clone(name))
	}

	property_cache_count, pcc_ok := bc_dec_u32(d)
	if !pcc_ok {
		delete(lines)
		delete(constants)
		delete(global_names)
		return nil, false
	}
	if property_cache_count > BC_CACHE_MAX_PROPERTY_CACHES {
		delete(lines)
		delete(constants)
		delete(global_names)
		return nil, false
	}

	c = new(Chunk)
	c.filename = strings.clone(filename_raw) // see global_names' own note above
	c.lines = lines
	c.constants = constants
	c.global_count = int(global_count)
	c.global_names = global_names
	c.property_caches = make([dynamic]Property_Cache, int(property_cache_count))
	append(&c.code, ..code_bytes)
	return c, true
}

// function_deserialise decodes data (produced by function_serialise)
// back into a fresh Function_Object tree. Every node's .environment is
// left nil -- the caller (vm package; only vm-layer code has a live
// ^Environment in scope for a given module load) must walk the returned
// tree and set it on every node before the result is callable. Never
// panics on malformed/truncated/wrong-version input: err distinguishes
// "not one of our files" (.Bad_Magic, the common no-cache-yet case) from
// "a real cache of ours from a different schema" (.Bad_Version, worth a
// one-line diagnostic) from "corrupt/truncated body" (.Malformed) purely
// so a caller CAN log something more specific than "cache miss" -- every
// one of these should be treated identically for control flow (fall back
// to compiling from source), never as a hard error.
function_deserialise :: proc(data: []u8) -> (fn: ^Function_Object, err: Bc_Decode_Error) {
	if len(data) < 6 {
		return nil, .Malformed
	}
	if data[0] != BC_CACHE_MAGIC[0] || data[1] != BC_CACHE_MAGIC[1] || data[2] != BC_CACHE_MAGIC[2] || data[3] != BC_CACHE_MAGIC[3] {
		return nil, .Bad_Magic
	}
	version := u16(data[4]) | (u16(data[5]) << 8)
	if version != BC_CACHE_VERSION {
		return nil, .Bad_Version
	}
	d := Bc_Decoder{data = data, pos = 6}
	result, ok := bc_dec_function(&d)
	if !ok {
		return nil, .Malformed
	}
	return result, .None
}
