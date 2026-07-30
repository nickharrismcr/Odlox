package natives

import "../core"
import "../vm"

// re: regular expressions, built on Odin's core:text/regex engine. See
// vm/regex.odin for the actual engine (pattern preprocessing for named
// groups, search/match/fullmatch/sub/subn/split/findall, and the
// Pattern/Match objects' own method dispatch) -- this file is just the
// module-level free functions, each compiling its pattern argument
// fresh and delegating to the same vm-package helpers a compiled
// Pattern's own methods use.

@(private)
register_re :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "re")
	vm.define_builtin(v, "re", "search", re_search)
	vm.define_builtin(v, "re", "match", re_match)
	vm.define_builtin(v, "re", "fullmatch", re_fullmatch)
	vm.define_builtin(v, "re", "sub", re_sub)
	vm.define_builtin(v, "re", "subn", re_subn)
	vm.define_builtin(v, "re", "split", re_split)
	vm.define_builtin(v, "re", "findall", re_findall)
	vm.define_builtin(v, "re", "compile", re_compile)
}

@(private = "file")
arg_string :: proc(vv: ^vm.VM, val: core.Value, what: string) -> (string, bool) {
	if !core.is_string(val) {
		vm.runtime_error(vv, "%s must be a string.", what)
		return "", false
	}
	return core.string_get(core.as_string(val)), true
}

@(private = "file")
re_search :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "Invalid argument count to re.search.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	s, ok2 := arg_string(v, v.stack[arg_stack_ptr + 1], "s")
	if !ok1 || !ok2 {
		return core.NIL_VALUE
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return vm.regex_search(v, pat, s)
}

@(private = "file")
re_match :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "Invalid argument count to re.match.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	s, ok2 := arg_string(v, v.stack[arg_stack_ptr + 1], "s")
	if !ok1 || !ok2 {
		return core.NIL_VALUE
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return vm.regex_match(v, pat, s)
}

@(private = "file")
re_fullmatch :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "Invalid argument count to re.fullmatch.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	s, ok2 := arg_string(v, v.stack[arg_stack_ptr + 1], "s")
	if !ok1 || !ok2 {
		return core.NIL_VALUE
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return vm.regex_fullmatch(v, pat, s)
}

@(private = "file")
re_sub :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 3 && argc != 4 {
		vm.runtime_error(v, "re.sub expects 3 or 4 arguments.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	repl, ok2 := arg_string(v, v.stack[arg_stack_ptr + 1], "repl")
	s, ok3 := arg_string(v, v.stack[arg_stack_ptr + 2], "s")
	if !ok1 || !ok2 || !ok3 {
		return core.NIL_VALUE
	}
	count := 0
	if argc == 4 {
		if !core.is_int(v.stack[arg_stack_ptr + 3]) {
			vm.runtime_error(v, "re.sub count must be an integer.")
			return core.NIL_VALUE
		}
		count = core.as_int(v.stack[arg_stack_ptr + 3])
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	result, _ := vm.regex_subn(pat, repl, s, count)
	return core.make_string_value(result)
}

@(private = "file")
re_subn :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 3 && argc != 4 {
		vm.runtime_error(v, "re.subn expects 3 or 4 arguments.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	repl, ok2 := arg_string(v, v.stack[arg_stack_ptr + 1], "repl")
	s, ok3 := arg_string(v, v.stack[arg_stack_ptr + 2], "s")
	if !ok1 || !ok2 || !ok3 {
		return core.NIL_VALUE
	}
	count := 0
	if argc == 4 {
		count = core.as_int(v.stack[arg_stack_ptr + 3])
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	result, n := vm.regex_subn(pat, repl, s, count)
	items: [dynamic]core.Value
	append(&items, core.make_string_value(result), core.make_int_value(n))
	t := core.make_list_object(items, true)
	vm.gc_track(v, &t.obj)
	return core.make_object_value(&t.obj, true)
}

@(private = "file")
re_split :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 && argc != 3 {
		vm.runtime_error(v, "re.split expects 2 or 3 arguments.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	s, ok2 := arg_string(v, v.stack[arg_stack_ptr + 1], "s")
	if !ok1 || !ok2 {
		return core.NIL_VALUE
	}
	maxsplit := 0
	if argc == 3 {
		maxsplit = core.as_int(v.stack[arg_stack_ptr + 2])
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	parts := vm.regex_split(pat, s, maxsplit)
	items: [dynamic]core.Value
	for part in parts {
		append(&items, core.make_string_value(part))
	}
	delete(parts)
	l := core.make_list_object(items)
	vm.gc_track(v, &l.obj)
	return core.make_object_value(&l.obj)
}

@(private = "file")
re_findall :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 2 {
		vm.runtime_error(v, "Invalid argument count to re.findall.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	s, ok2 := arg_string(v, v.stack[arg_stack_ptr + 1], "s")
	if !ok1 || !ok2 {
		return core.NIL_VALUE
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return vm.regex_findall(v, pat, s)
}

@(private = "file")
re_compile :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "Invalid argument count to re.compile.")
		return core.NIL_VALUE
	}
	pattern, ok1 := arg_string(v, v.stack[arg_stack_ptr], "pattern")
	if !ok1 {
		return core.NIL_VALUE
	}
	pat, ok := vm.regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return core.make_object_value(&pat.obj)
}
