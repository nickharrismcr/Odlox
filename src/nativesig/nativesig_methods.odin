package nativesig

// Method_Signature parallels Signature (nativesig.odin) but for built-in
// *methods* -- vm/call.odin's invoke_builtin_list/invoke_builtin_dict/
// invoke_builtin_string, dispatched by (receiver object kind, method
// name) rather than through vm.define_builtin's (module, name) registry
// at all, so it needs its own key shape and lookup. Receiver is always
// one of .List, .Dict, .String -- the three built-in kinds with a real
// method surface and a Type_Kind of their own (Float_Array/Float_Array_3D/
// Userdata have neither today, so their methods stay unchecked).
Method_Signature :: struct {
	receiver:      Kind,
	name:          string,
	min_args:      int,
	max_args:      int,
	params:        []Param,
	returns:       Kind,
	arity_message: string,
}

// method_signatures is hand-verified against vm/call.odin's
// invoke_builtin_list/invoke_builtin_dict/invoke_builtin_string. A
// method whose real return value can be more than one kind (list.find,
// which returns Int or Nil; dict.get/dict.remove, which return whatever
// was stored, of any type, or Nil) is given .Dynamic rather than
// guessing one branch -- the same "don't narrow past what's actually
// true" discipline the rest of this table follows.
@(private = "file")
method_signatures := []Method_Signature {
	// --- List (vm/call.odin's invoke_builtin_list) ---
	{receiver = .List, name = "append", min_args = 1, max_args = 1, params = {{}}, returns = .Dynamic, arity_message = "append takes one argument."},
	{receiver = .List, name = "remove", min_args = 1, max_args = 1, params = {{accepted = NUMERIC}}, returns = .Dynamic, arity_message = "remove takes one argument."},
	{receiver = .List, name = "find", min_args = 1, max_args = 1, params = {{}}, returns = .Dynamic, arity_message = "find takes one argument."},
	{receiver = .List, name = "length", min_args = 0, max_args = 0, params = {}, returns = .Int, arity_message = "length takes no arguments."},
	{receiver = .List, name = "clear", min_args = 0, max_args = 0, params = {}, returns = .Dynamic, arity_message = "clear takes no arguments."},

	// --- Dict (vm/call.odin's invoke_builtin_dict) ---
	{receiver = .Dict, name = "get", min_args = 1, max_args = 2, params = {{accepted = STRING}}, returns = .Dynamic, arity_message = "get takes one or two arguments."},
	{receiver = .Dict, name = "keys", min_args = 0, max_args = -1, params = {}, returns = .List, arity_message = ""},
	{receiver = .Dict, name = "remove", min_args = 1, max_args = 1, params = {{accepted = STRING}}, returns = .Dynamic, arity_message = "remove takes one argument."},

	// --- String (vm/call.odin's invoke_builtin_string) ---
	{receiver = .String, name = "length", min_args = 0, max_args = 0, params = {}, returns = .Int, arity_message = "length takes no arguments."},
	{receiver = .String, name = "replace", min_args = 2, max_args = 2, params = {{accepted = STRING}, {accepted = STRING}}, returns = .String, arity_message = "replace takes two arguments."},
	{receiver = .String, name = "join", min_args = 1, max_args = 1, params = {{accepted = {.List}}}, returns = .String, arity_message = "join takes one list argument."},
}

// lookup_method finds the signature for a (receiver kind, method name)
// pair, if one is registered.
lookup_method :: proc(receiver: Kind, name: string) -> (Method_Signature, bool) {
	for sig in method_signatures {
		if sig.receiver == receiver && sig.name == name {
			return sig, true
		}
	}
	return Method_Signature{}, false
}
