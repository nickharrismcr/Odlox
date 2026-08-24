package compiler

import "../nativesig"
import "core:fmt"
import "core:strings"

// typecheck_native_call checks a call against a table-driven lookup in
// nativesig.signatures -- see that package's own header comment for why
// the table lives in a separate, dependency-free package rather than
// alongside the native functions it describes.
//
// Called from typecheck_call (typecheck_expr.odin), gated on a bare
// Expr_Variable whose name matches a registered signature *and* whose
// own resolved type is still Dynamic, so a genuine user shadow is never
// checked against the builtin's shape instead of their own. call.args
// aren't typechecked yet at this point (this runs before typecheck_
// call's own ordinary arg loop), so this proc does that itself, unlike
// typecheck_native_method_call below.
typecheck_native_call :: proc(tc: ^Type_Checker, call: ^Expr_Call, sig: nativesig.Signature) -> ^Type {
	arg_types := make([dynamic]^Type, 0, len(call.args))
	arg_tokens := make([dynamic]Token, 0, len(call.args))
	for a in call.args {
		append(&arg_types, typecheck_expr(tc, a))
		append(&arg_tokens, expr_token(a))
	}
	check_native_args(tc, arg_types[:], arg_tokens[:], sig.params, sig.variadic_tail, sig.min_args, sig.max_args, sig.arity_message, call.token)
	return native_kind_to_type(sig.returns)
}

// typecheck_native_module_call is typecheck_property's early-recognition
// case (typecheck_expr.odin) for a call on a built-in module with no real
// Module_Signature (sys.sleep(...)/os.exists(...)). A separate path from
// typecheck_module_property's ordinary Func-type/types_compatible check:
// a nativesig.Param can accept several kinds (sys.sleep's argument is
// int-or-float), which a single-declared-type Func param can't
// represent without either a false positive on one arm or widening to
// Dynamic (no checking at all). Takes arg_types already computed by
// typecheck_property, same reasoning as typecheck_native_method_call
// below.
typecheck_native_module_call :: proc(tc: ^Type_Checker, v: ^Expr_Property, sig: nativesig.Signature, arg_types: []^Type) -> ^Type {
	arg_tokens := make([dynamic]Token, 0, len(v.args))
	for a in v.args {
		append(&arg_tokens, expr_token(a))
	}
	check_native_args(tc, arg_types, arg_tokens[:], sig.params, sig.variadic_tail, sig.min_args, sig.max_args, sig.arity_message, v.token)
	return native_kind_to_type(sig.returns)
}

// typecheck_native_method_call is typecheck_property's .Invoke branch for
// a List/Dict/String receiver (nativesig_methods.odin's table) -- see
// typecheck_property (typecheck_expr.odin) for the receiver-kind dispatch
// that calls this. Takes arg_types already computed by typecheck_property
// itself (unlike typecheck_native_call above, whose caller hasn't
// typechecked call.args yet) rather than re-visiting each argument a
// second time.
typecheck_native_method_call :: proc(tc: ^Type_Checker, v: ^Expr_Property, sig: nativesig.Method_Signature, arg_types: []^Type) -> ^Type {
	arg_tokens := make([dynamic]Token, 0, len(v.args))
	for a in v.args {
		append(&arg_tokens, expr_token(a))
	}
	check_native_args(tc, arg_types, arg_tokens[:], sig.params, nil, sig.min_args, sig.max_args, sig.arity_message, v.token)
	return native_kind_to_type(sig.returns)
}

// typecheck_builtin_method_property is typecheck_property's branch
// (typecheck_expr.odin) for a List/Dict/String receiver -- the only
// built-in kinds with both a real method surface and a Type_Kind of
// their own (Float_Array/Float_Array_3D/Userdata have neither, so their
// methods stay unchecked). None of the three have a real *field*
// surface -- append/remove/get/... are always called, never read as
// bound values -- so .Get/.Set/.Compound_Set are left permissive; only
// .Invoke does anything. A miss against nativesig_methods.odin's table
// is a diagnosed error, not a permissive fallback: the switch it mirrors
// (vm/call.odin's invoke_builtin_list/dict/string) is a closed,
// unconditional runtime error on any other name, unlike a Class's own
// methods_uncertain escape hatch.
typecheck_builtin_method_property :: proc(tc: ^Type_Checker, v: ^Expr_Property, kind: Type_Kind, arg_types: []^Type) -> ^Type {
	if v.kind != .Invoke {
		return dynamic_type()
	}
	name := lexeme(v.name)
	native_kind := type_kind_to_native_kind(kind)
	sig, ok := nativesig.lookup_method(native_kind, name)
	if !ok {
		diagnose(tc, v.token, fmt.tprintf("%s has no method '%s'", native_kind_name(native_kind), name))
		return dynamic_type()
	}
	return typecheck_native_method_call(tc, v, sig, arg_types)
}

@(private = "file")
type_kind_to_native_kind :: proc(k: Type_Kind) -> nativesig.Kind {
	#partial switch k {
	case .List:
		return .List
	case .Dict:
		return .Dict
	case .String:
		return .String
	}
	return .Dynamic
}

// check_native_args is the shared core both entry points above delegate
// to: checks each already-typed argument against its declared position
// (params[i]), or variadic_tail for any position beyond len(params) if
// one is given (os.join: every argument, not just the first, must be a
// string) -- otherwise a beyond-params position is left unchecked
// (format()'s template-plus-anything tail). Then checks the argument
// count against [min_args, max_args] (max_args == -1 is unbounded),
// diagnosing arity_message on a mismatch unless it's empty (arity never
// enforced for this signature -- see nativesig.Signature's own doc
// comment).
@(private = "file")
check_native_args :: proc(
	tc: ^Type_Checker,
	arg_types: []^Type,
	arg_tokens: []Token,
	params: []nativesig.Param,
	variadic_tail: []nativesig.Kind,
	min_args, max_args: int,
	arity_message: string,
	call_tok: Token,
) {
	for arg_type, i in arg_types {
		accepted: []nativesig.Kind
		switch {
		case i < len(params):
			accepted = params[i].accepted
		case len(variadic_tail) > 0:
			accepted = variadic_tail
		case:
			continue
		}
		if len(accepted) == 0 {
			continue
		}
		if !kind_in_set(arg_type.kind, accepted) {
			diagnose(
				tc,
				arg_tokens[i],
				fmt.tprintf("argument %d: expected %s, got %s", i + 1, describe_kind_set(accepted), type_string(arg_type)),
			)
		}
	}
	if arity_message != "" && (len(arg_types) < min_args || (max_args >= 0 && len(arg_types) > max_args)) {
		diagnose(tc, call_tok, arity_message)
	}
}

// kind_in_set reports whether actual matches one of accepted, or is
// Dynamic -- an argument the checker never followed to a concrete type
// is always accepted regardless of what the parameter declares, the
// same escape hatch every other diagnostic in this feature uses.
@(private = "file")
kind_in_set :: proc(actual: Type_Kind, accepted: []nativesig.Kind) -> bool {
	if actual == .Dynamic {
		return true
	}
	for k in accepted {
		if native_kind_to_type_kind(k) == actual {
			return true
		}
	}
	return false
}

// describe_kind_set renders an accepted-kind list as "int or float" /
// "string, list, or dict" for a diagnostic message.
@(private = "file")
describe_kind_set :: proc(accepted: []nativesig.Kind) -> string {
	names := make([dynamic]string, 0, len(accepted))
	for k in accepted {
		append(&names, native_kind_name(k))
	}
	switch len(names) {
	case 0:
		return "a value"
	case 1:
		return names[0]
	case 2:
		return fmt.tprintf("%s or %s", names[0], names[1])
	case:
		return fmt.tprintf("%s, or %s", strings.join(names[:len(names) - 1], ", "), names[len(names) - 1])
	}
}

@(private = "file")
native_kind_name :: proc(k: nativesig.Kind) -> string {
	switch k {
	case .Dynamic:
		return "any value"
	case .Bool:
		return "bool"
	case .Int:
		return "int"
	case .Float:
		return "float"
	case .String:
		return "string"
	case .List:
		return "list"
	case .Dict:
		return "dict"
	case .Vec2:
		return "vec2"
	case .Vec3:
		return "vec3"
	case .Vec4:
		return "vec4"
	case .Window:
		return "Window"
	case .Image:
		return "Image"
	case .Texture:
		return "Texture"
	case .Render_Texture:
		return "RenderTexture"
	case .Shader:
		return "Shader"
	case .Camera3D:
		return "Camera3D"
	case .Batch:
		return "Batch"
	case .Batch2D:
		return "Batch2D"
	case .Batch_Instanced:
		return "BatchInstanced"
	case .Light:
		return "Light"
	case .Sound:
		return "Sound"
	case .Music:
		return "Music"
	case .Socket:
		return "Socket"
	case .Process:
		return "Process"
	case .Box2D_World:
		return "Box2DWorld"
	case .Physics_World:
		return "PhysicsWorld"
	case .Pattern:
		return "Pattern"
	case .Match:
		return "Match"
	}
	return "unknown"
}

@(private = "file")
native_kind_to_type_kind :: proc(k: nativesig.Kind) -> Type_Kind {
	switch k {
	case .Dynamic:
		return .Dynamic
	case .Bool:
		return .Bool
	case .Int:
		return .Int
	case .Float:
		return .Float
	case .String:
		return .String
	case .List:
		return .List
	case .Dict:
		return .Dict
	case .Vec2:
		return .Vec2
	case .Vec3:
		return .Vec3
	case .Vec4:
		return .Vec4
	case .Window:
		return .Window
	case .Image:
		return .Image
	case .Texture:
		return .Texture
	case .Render_Texture:
		return .Render_Texture
	case .Shader:
		return .Shader
	case .Camera3D:
		return .Camera3D
	case .Batch:
		return .Batch
	case .Batch2D:
		return .Batch2D
	case .Batch_Instanced:
		return .Batch_Instanced
	case .Light:
		return .Light
	case .Sound:
		return .Sound
	case .Music:
		return .Music
	case .Socket:
		return .Socket
	case .Process:
		return .Process
	case .Box2D_World:
		return .Box2D_World
	case .Physics_World:
		return .Physics_World
	case .Pattern:
		return .Pattern
	case .Match:
		return .Match
	}
	return .Dynamic
}

// native_kind_to_type builds a fully-formed ^Type for a native's return
// kind -- not just new_clone(Type{kind = native_kind_to_type_kind(k)}):
// a .List/.Dict Type must always carry a non-nil list_elem/dict_key/
// dict_value (Expr_Index reads obj_type.list_elem with no nil check, see
// typecheck_expr.odin), so both are set to Dynamic here, matching every
// other List/Dict Type this package constructs.
@(private = "file")
native_kind_to_type :: proc(k: nativesig.Kind) -> ^Type {
	#partial switch k {
	case .List:
		return new_clone(Type{kind = .List, list_elem = dynamic_type()})
	case .Dict:
		return new_clone(Type{kind = .Dict, dict_key = dynamic_type(), dict_value = dynamic_type()})
	}
	return new_clone(Type{kind = native_kind_to_type_kind(k)})
}
