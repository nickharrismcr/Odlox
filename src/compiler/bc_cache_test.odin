package compiler

import "../core"
import "core:testing"

// Round-trips a *real* compiler.Compile output through
// core.function_serialise/function_deserialise -- core/bc_cache_test.odin
// already covers the format's edge cases (bad magic/version, truncation,
// a corrupted count) against hand-built Chunk/Function_Object trees; this
// test exists to catch anything a hand-built fixture could hide -- a
// shape the real compiler produces that the format doesn't actually
// handle (e.g. an unexpected constant kind, a nesting pattern the
// recursive encoder mishandles).

@(private = "file")
functions_structurally_equal :: proc(a, b: ^core.Function_Object) -> bool {
	if a.arity != b.arity || a.min_arity != b.min_arity || a.is_variadic != b.is_variadic || a.upvalue_count != b.upvalue_count {
		return false
	}
	if core.string_get(a.name) != core.string_get(b.name) {
		return false
	}
	return chunks_structurally_equal(a.chunk, b.chunk)
}

@(private = "file")
chunks_structurally_equal :: proc(a, b: ^core.Chunk) -> bool {
	if len(a.code) != len(b.code) {
		return false
	}
	for byte, i in a.code {
		if byte != b.code[i] {
			return false
		}
	}
	if len(a.lines) != len(b.lines) {
		return false
	}
	for line, i in a.lines {
		if line != b.lines[i] {
			return false
		}
	}
	if a.filename != b.filename || a.global_count != b.global_count {
		return false
	}
	if len(a.global_names) != len(b.global_names) {
		return false
	}
	for name, i in a.global_names {
		if name != b.global_names[i] {
			return false
		}
	}
	if len(a.property_caches) != len(b.property_caches) {
		return false
	}
	if len(a.constants) != len(b.constants) {
		return false
	}
	for cv, i in a.constants {
		if !constants_structurally_equal(cv, b.constants[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
constants_structurally_equal :: proc(a, b: core.Value) -> bool {
	if a.type != b.type {
		return false
	}
	#partial switch a.type {
	case .Int, .Float:
		return a.data == b.data
	case .Obj:
		if a.obj_type != b.obj_type {
			return false
		}
		#partial switch a.obj_type {
		case .String:
			return core.string_get(core.as_string(a)) == core.string_get(core.as_string(b))
		case .Function:
			return functions_structurally_equal(core.as_function(a), core.as_function(b))
		}
	}
	return false
}

// A source exercising every constant kind the cache format handles: an
// int on each side of the 32-bit boundary (a regression in the cache's
// no-truncation guarantee -- see bc_cache.odin's own doc comment -- would
// look exactly like the reference implementation's own acknowledged bc_cache.go bug reappearing),
// a float, a string, and a nested closure capturing an enclosing
// parameter (exercises the recursive Function-as-constant path that
// vm/bc_cache.odin's environment fixup, wired up in a later stage, has
// to walk into).
@(test)
test_bc_cache_roundtrip_preserves_real_compiled_program :: proc(t: ^testing.T) {
	env := core.make_environment("test")
	source := `
var large1 = 2147483647
var large2 = 2147483648
var large3 = 4294967296
var negative = -5
var pi = 3.14159
var greeting = "hello"

func make_adder(n) {
	func adder(x) {
		return x + n
	}
	return adder
}

var add5 = make_adder(5)
`
	fn, ok := Compile(source, "test.lox", env)
	testing.expect(t, ok)
	if !ok {
		return
	}

	data, enc_ok := core.function_serialise(fn)
	testing.expect(t, enc_ok)
	if !enc_ok {
		return
	}
	defer delete(data)

	fn2, err := core.function_deserialise(data)
	testing.expect_value(t, err, core.Bc_Decode_Error.None)
	if err != .None {
		return
	}

	testing.expect(t, functions_structurally_equal(fn, fn2))
	testing.expect(t, fn2.environment == nil) // wiring is a later stage's job (vm/bc_cache.odin)
	testing.expect_value(t, len(fn2.chunk.local_vars), 0) // debug-only, deliberately omitted
}
