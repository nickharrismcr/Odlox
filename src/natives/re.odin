package natives

import "../core"
import "../vm"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:text/regex/virtual_machine"

// re: regular expressions, built on Odin's core:text/regex engine.
// Pattern preprocessing (named-group support, since core:text/regex lacks
// Python/RE2's (?P<name>...)), compiling, and the search/match/fullmatch/
// sub/subn/split/findall operations all live in this file. Known
// limitation: Odin's regex.match_and_allocate_capture compacts away any
// capture group that didn't participate in a match, so a group after one
// that failed to participate would be misnumbered here.

Pattern_Data :: struct {
	regex:       regex.Regular_Expression,
	group_names: map[int]string, // 1-based capture-group number -> name, only present entries
	num_groups:  int, // highest capture-group number in the pattern (0 if none)
	source:      string, // original pattern text, for Pattern.__str__ / error messages
}

// Match_Data is the result of a successful search/match/fullmatch --
// pos[0]/groups[0] is the whole match, pos[i]/groups[i] (i>=1) is capture
// group i. group_names is a borrowed reference to the Pattern_Data that
// produced this match (not owned/freed here -- see match_data_free).
Match_Data :: struct {
	pos:         [][2]int,
	groups:      []string,
	group_names: map[int]string,
}

@(private = "file")
pattern_vtable := core.Userdata_Vtable {
	tag       = "Pattern",
	free      = pattern_data_free,
	to_string = pattern_to_string,
	size      = pattern_data_size,
	invoke    = pattern_invoke,
}

@(private = "file")
match_vtable := core.Userdata_Vtable {
	tag       = "Match",
	free      = match_data_free,
	to_string = match_to_string,
	size      = match_data_size,
	invoke    = match_invoke,
}

@(private = "file")
pattern_data_free :: proc(data: rawptr) {
	p := cast(^Pattern_Data)data
	delete(p.group_names)
	regex.destroy_regex(p.regex)
	free(p)
}

@(private = "file")
match_data_free :: proc(data: rawptr) {
	m := cast(^Match_Data)data
	delete(m.pos)
	delete(m.groups)
	free(m)
}

@(private = "file")
pattern_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	p := cast(^Pattern_Data)data
	return fmt.aprintf("<Pattern %q>", p.source, allocator = allocator)
}

@(private = "file")
match_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	m := cast(^Match_Data)data
	return fmt.aprintf("<Match span=%v>", m.pos[0], allocator = allocator)
}

@(private = "file")
pattern_data_size :: proc(data: rawptr) -> int {
	return size_of(Pattern_Data)
}

@(private = "file")
match_data_size :: proc(data: rawptr) -> int {
	return size_of(Match_Data)
}

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
	pat, _, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return regex_search(v, pat, s)
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
	pat, _, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return regex_match(v, pat, s)
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
	pat, _, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return regex_fullmatch(v, pat, s)
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
	pat, _, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	result, _ := regex_subn(pat, repl, s, count)
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
	pat, _, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	result, n := regex_subn(pat, repl, s, count)
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
	pat, _, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	parts := regex_split(pat, s, maxsplit)
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
	pat, _, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return regex_findall(v, pat, s)
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
	_, obj, ok := regex_compile(v, pattern)
	if !ok {
		return core.NIL_VALUE
	}
	return core.make_object_value(&obj.obj)
}

// -----------------------------------------------------------------------
// Engine: pattern preprocessing, compiling, and the search/match/
// fullmatch/sub/subn/split/findall operations both the module-level free
// functions above and the Pattern/Match objects' own methods
// (pattern_invoke/match_invoke below) share.

// preprocess_pattern strips (?P<name>...) down to plain (...) before
// handing the pattern to Odin's regex.create, recording which capture-
// group number each name corresponds to (capture groups are numbered by
// the position of their opening paren, left to right; (?:...) is
// non-capturing and does not consume a number, matching every regex
// engine's own convention).
@(private = "file")
preprocess_pattern :: proc(pattern: string) -> (rewritten: string, group_names: map[int]string) {
	sb: strings.Builder
	group_names = make(map[int]string)
	in_class := false
	group_count := 0
	i := 0
	for i < len(pattern) {
		c := pattern[i]
		if c == '\\' && i + 1 < len(pattern) {
			strings.write_byte(&sb, c)
			strings.write_byte(&sb, pattern[i + 1])
			i += 2
			continue
		}
		if !in_class && c == '[' {
			in_class = true
			strings.write_byte(&sb, c)
			i += 1
			continue
		}
		if in_class && c == ']' {
			in_class = false
			strings.write_byte(&sb, c)
			i += 1
			continue
		}
		if !in_class && c == '(' {
			if i + 1 < len(pattern) && pattern[i + 1] == '?' {
				if i + 3 < len(pattern) && pattern[i + 2] == 'P' && pattern[i + 3] == '<' {
					group_count += 1
					end := i + 4
					for end < len(pattern) && pattern[end] != '>' {
						end += 1
					}
					group_names[group_count] = pattern[i + 4:end]
					strings.write_byte(&sb, '(')
					i = end + 1
					continue
				}
				// (?:...) or any other (?...) form -- pass through as-is,
				// doesn't consume a capture-group number.
				strings.write_byte(&sb, c)
				i += 1
				continue
			}
			group_count += 1
			strings.write_byte(&sb, c)
			i += 1
			continue
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	rewritten = strings.to_string(sb)
	return
}

// regex_num_groups counts every capturing group (named or not) in an
// already-preprocessed pattern -- used so findall/groups know how many
// groups to report even for ones that didn't participate in a given
// match (which Odin's own capture result simply omits -- see this file's
// header comment).
@(private = "file")
regex_num_groups :: proc(preprocessed: string) -> int {
	in_class := false
	count := 0
	i := 0
	for i < len(preprocessed) {
		c := preprocessed[i]
		if c == '\\' && i + 1 < len(preprocessed) {
			i += 2
			continue
		}
		if !in_class && c == '[' {
			in_class = true
			i += 1
			continue
		}
		if in_class && c == ']' {
			in_class = false
			i += 1
			continue
		}
		if !in_class && c == '(' {
			if i + 1 < len(preprocessed) && preprocessed[i + 1] == '?' {
				i += 1
				continue
			}
			count += 1
			i += 1
			continue
		}
		i += 1
	}
	return count
}

// regex_compile compiles pattern into a new Pattern_Data, GC-tracked via
// its wrapping Userdata_Object. Returns both: callers that only need the
// engine (regex_search & co.) use the ^Pattern_Data directly; re_compile
// (which returns the Pattern itself to the script) uses the
// ^core.Userdata_Object.
@(private = "file")
regex_compile :: proc(v: ^vm.VM, pattern: string) -> (^Pattern_Data, ^core.Userdata_Object, bool) {
	rewritten, names := preprocess_pattern(pattern)
	num_groups := regex_num_groups(rewritten)
	re, err := regex.create(rewritten)
	if err != nil {
		delete(names)
		vm.runtime_error(v, "re: invalid pattern: %v", err)
		return nil, nil, false
	}
	data := new(Pattern_Data)
	data.regex = re
	data.group_names = names
	data.num_groups = num_groups
	data.source = pattern
	o := core.make_userdata_object(&pattern_vtable, data)
	vm.gc_track(v, &o.obj)
	return data, o, true
}

@(private = "file")
regex_search_raw :: proc(v: ^vm.VM, pat: ^Pattern_Data, s: string) -> core.Value {
	capture, ok := regex.match_and_allocate_capture(pat.regex, s)
	if !ok {
		return core.NIL_VALUE
	}
	data := new(Match_Data)
	data.pos = capture.pos
	data.groups = capture.groups
	data.group_names = pat.group_names
	o := core.make_userdata_object(&match_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj)
}

@(private = "file")
regex_search :: proc(v: ^vm.VM, pat: ^Pattern_Data, s: string) -> core.Value {
	return regex_search_raw(v, pat, s)
}

// regex_match/regex_fullmatch don't re-anchor the compiled pattern --
// they reuse a plain search and check the result's own span, since any
// regex engine that tries starting positions left-to-right (as Odin's
// thread-based VM does) finds a position-0 match first if one exists,
// making "search, then check span" equivalent to a true anchored match
// without needing a second compiled variant per anchoring mode.
@(private = "file")
regex_match :: proc(v: ^vm.VM, pat: ^Pattern_Data, s: string) -> core.Value {
	val := regex_search_raw(v, pat, s)
	if val.type != .Obj {
		return core.NIL_VALUE
	}
	m := cast(^Match_Data)core.as_userdata(val).data
	if m.pos[0][0] != 0 {
		return core.NIL_VALUE
	}
	return val
}

@(private = "file")
regex_fullmatch :: proc(v: ^vm.VM, pat: ^Pattern_Data, s: string) -> core.Value {
	val := regex_search_raw(v, pat, s)
	if val.type != .Obj {
		return core.NIL_VALUE
	}
	m := cast(^Match_Data)core.as_userdata(val).data
	if m.pos[0][0] != 0 || m.pos[0][1] != len(s) {
		return core.NIL_VALUE
	}
	return val
}

// regex_iterate_matches returns every non-overlapping match, up to limit
// (0 = unlimited) -- caller owns and must delete() each Capture's pos/
// groups slices, and the returned dynamic array itself.
@(private = "file")
regex_iterate_matches :: proc(pat: ^Pattern_Data, s: string, limit: int) -> [dynamic]regex.Capture {
	results: [dynamic]regex.Capture
	it: regex.Match_Iterator
	it.regex = pat.regex
	it.capture = regex.preallocate_capture()
	it.temp = context.temp_allocator
	it.vm = virtual_machine.create(pat.regex.program, s)
	it.vm.class_data = pat.regex.class_data
	it.threads = max(1, virtual_machine.opcode_count(it.vm.code) - 1)

	for {
		if limit > 0 && len(results) >= limit {
			break
		}
		capture, _, ok := regex.match_iterator(&it)
		if !ok {
			break
		}
		pos_copy := make([][2]int, len(capture.pos))
		copy(pos_copy, capture.pos)
		groups_copy := make([]string, len(capture.groups))
		copy(groups_copy, capture.groups)
		append(&results, regex.Capture{pos = pos_copy, groups = groups_copy})
	}

	delete(it.capture.pos)
	delete(it.capture.groups)
	return results
}

@(private = "file")
delete_matches :: proc(matches: [dynamic]regex.Capture) {
	for m in matches {
		delete(m.pos)
		delete(m.groups)
	}
	delete(matches)
}

// regex_expand_repl expands $1/$12/${1}/${name} references in repl
// against capture's own groups. This is the re module's replacement
// syntax -- not Python's \1/\g<name>.
@(private = "file")
regex_expand_repl :: proc(repl: string, capture: regex.Capture, group_names: map[int]string) -> string {
	sb: strings.Builder
	i := 0
	for i < len(repl) {
		c := repl[i]
		if c == '$' && i + 1 < len(repl) {
			if repl[i + 1] == '{' {
				end := i + 2
				for end < len(repl) && repl[end] != '}' {
					end += 1
				}
				key := repl[i + 2:end]
				if n, ok := strconv.parse_int(key); ok {
					if n >= 0 && n < len(capture.groups) {
						strings.write_string(&sb, capture.groups[n])
					}
				} else {
					for gn, gname in group_names {
						if gname == key && gn < len(capture.groups) {
							strings.write_string(&sb, capture.groups[gn])
							break
						}
					}
				}
				i = end + 1
				continue
			} else if repl[i + 1] >= '0' && repl[i + 1] <= '9' {
				end := i + 1
				for end < len(repl) && repl[end] >= '0' && repl[end] <= '9' {
					end += 1
				}
				n, _ := strconv.parse_int(repl[i + 1:end])
				if n >= 0 && n < len(capture.groups) {
					strings.write_string(&sb, capture.groups[n])
				}
				i = end
				continue
			}
		}
		strings.write_byte(&sb, c)
		i += 1
	}
	return strings.to_string(sb)
}

@(private = "file")
regex_subn :: proc(pat: ^Pattern_Data, repl: string, s: string, count: int) -> (result: string, n: int) {
	matches := regex_iterate_matches(pat, s, count)
	defer delete_matches(matches)

	sb: strings.Builder
	last := 0
	for m in matches {
		start, end := m.pos[0][0], m.pos[0][1]
		strings.write_string(&sb, s[last:start])
		strings.write_string(&sb, regex_expand_repl(repl, m, pat.group_names))
		last = end
	}
	strings.write_string(&sb, s[last:])
	return strings.to_string(sb), len(matches)
}

@(private = "file")
regex_split :: proc(pat: ^Pattern_Data, s: string, maxsplit: int) -> []string {
	matches := regex_iterate_matches(pat, s, maxsplit)
	defer delete_matches(matches)

	result: [dynamic]string
	last := 0
	for m in matches {
		start, end := m.pos[0][0], m.pos[0][1]
		append(&result, s[last:start])
		last = end
	}
	append(&result, s[last:])
	return result[:]
}

@(private = "file")
regex_findall :: proc(v: ^vm.VM, pat: ^Pattern_Data, s: string) -> core.Value {
	matches := regex_iterate_matches(pat, s, 0)
	defer delete_matches(matches)

	items: [dynamic]core.Value
	for m in matches {
		switch {
		case pat.num_groups == 0:
			append(&items, core.make_string_value(m.groups[0]))
		case pat.num_groups == 1:
			if len(m.groups) > 1 {
				append(&items, core.make_string_value(m.groups[1]))
			} else {
				append(&items, core.NIL_VALUE)
			}
		case:
			tuple_items: [dynamic]core.Value
			for i in 1 ..= pat.num_groups {
				if i < len(m.groups) {
					append(&tuple_items, core.make_string_value(m.groups[i]))
				} else {
					append(&tuple_items, core.NIL_VALUE)
				}
			}
			t := core.make_list_object(tuple_items, true)
			vm.gc_track(v, &t.obj)
			append(&items, core.make_object_value(&t.obj, true))
		}
	}
	l := core.make_list_object(items)
	vm.gc_track(v, &l.obj)
	return core.make_object_value(&l.obj)
}

// -----------------------------------------------------------------------
// Match object methods

@(private = "file")
regex_match_group_at :: proc(m: ^Match_Data, idx: int) -> core.Value {
	if idx < 0 || idx >= len(m.groups) {
		return core.NIL_VALUE
	}
	return core.make_string_value(m.groups[idx])
}

@(private = "file")
regex_group_index_for_name :: proc(m: ^Match_Data, name: string) -> (int, bool) {
	for gn, gname in m.group_names {
		if gname == name {
			return gn, true
		}
	}
	return -1, false
}

@(private = "file")
match_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	m := cast(^Match_Data)data
	result: core.Value
	switch name {
	case "group":
		if arg_count == 0 {
			result = regex_match_group_at(m, 0)
		} else if arg_count == 1 {
			key := vm.peek(v, 0)
			if core.is_int(key) {
				result = regex_match_group_at(m, core.as_int(key))
			} else if core.is_string(key) {
				idx, ok := regex_group_index_for_name(m, core.string_get(core.as_string(key)))
				if !ok {
					vm.runtime_error(v, "No such group: '%s'.", core.string_get(core.as_string(key)))
					return false
				}
				result = regex_match_group_at(m, idx)
			} else {
				vm.runtime_error(v, "group() argument must be an int or string.")
				return false
			}
		} else {
			vm.runtime_error(v, "group() takes 0 or 1 arguments.")
			return false
		}
	case "groups":
		if arg_count != 0 {
			vm.runtime_error(v, "groups() takes no arguments.")
			return false
		}
		items: [dynamic]core.Value
		for i in 1 ..< len(m.groups) {
			append(&items, core.make_string_value(m.groups[i]))
		}
		t := core.make_list_object(items, true)
		vm.gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "groupdict":
		if arg_count != 0 {
			vm.runtime_error(v, "groupdict() takes no arguments.")
			return false
		}
		d := core.make_dict_object()
		for gn, gname in m.group_names {
			if gn < len(m.groups) {
				core.dict_set(d, core.intern_string(gname), core.make_string_value(m.groups[gn]))
			}
		}
		result = core.make_object_value(&d.obj)
	case "start":
		idx := 0
		if arg_count == 1 {
			idx = core.as_int(vm.peek(v, 0))
		} else if arg_count != 0 {
			vm.runtime_error(v, "start() takes 0 or 1 arguments.")
			return false
		}
		if idx < 0 || idx >= len(m.pos) {
			vm.runtime_error(v, "No such group: %d.", idx)
			return false
		}
		result = core.make_int_value(m.pos[idx][0])
	case "end":
		idx := 0
		if arg_count == 1 {
			idx = core.as_int(vm.peek(v, 0))
		} else if arg_count != 0 {
			vm.runtime_error(v, "end() takes 0 or 1 arguments.")
			return false
		}
		if idx < 0 || idx >= len(m.pos) {
			vm.runtime_error(v, "No such group: %d.", idx)
			return false
		}
		result = core.make_int_value(m.pos[idx][1])
	case "span":
		idx := 0
		if arg_count == 1 {
			idx = core.as_int(vm.peek(v, 0))
		} else if arg_count != 0 {
			vm.runtime_error(v, "span() takes 0 or 1 arguments.")
			return false
		}
		if idx < 0 || idx >= len(m.pos) {
			vm.runtime_error(v, "No such group: %d.", idx)
			return false
		}
		items: [dynamic]core.Value
		append(&items, core.make_int_value(m.pos[idx][0]), core.make_int_value(m.pos[idx][1]))
		t := core.make_list_object(items, true)
		vm.gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case:
		vm.runtime_error(v, "Undefined Match method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}

// -----------------------------------------------------------------------
// Pattern object methods -- same operations as the module-level
// functions above, minus the leading pattern argument (those call the
// same regex_* helpers directly).

@(private = "file")
pattern_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	pat := cast(^Pattern_Data)data
	result: core.Value
	switch name {
	case "search":
		if arg_count != 1 {
			vm.runtime_error(v, "search() takes 1 argument.")
			return false
		}
		result = regex_search(v, pat, core.string_get(core.as_string(vm.peek(v, 0))))
	case "match":
		if arg_count != 1 {
			vm.runtime_error(v, "match() takes 1 argument.")
			return false
		}
		result = regex_match(v, pat, core.string_get(core.as_string(vm.peek(v, 0))))
	case "fullmatch":
		if arg_count != 1 {
			vm.runtime_error(v, "fullmatch() takes 1 argument.")
			return false
		}
		result = regex_fullmatch(v, pat, core.string_get(core.as_string(vm.peek(v, 0))))
	case "sub":
		if arg_count != 2 && arg_count != 3 {
			vm.runtime_error(v, "sub() takes 2 or 3 arguments.")
			return false
		}
		count := 0
		if arg_count == 3 {
			count = core.as_int(vm.peek(v, 0))
		}
		s := core.string_get(core.as_string(vm.peek(v, arg_count - 2)))
		repl := core.string_get(core.as_string(vm.peek(v, arg_count - 1)))
		new_s, _ := regex_subn(pat, repl, s, count)
		result = core.make_string_value(new_s)
	case "subn":
		if arg_count != 2 && arg_count != 3 {
			vm.runtime_error(v, "subn() takes 2 or 3 arguments.")
			return false
		}
		count := 0
		if arg_count == 3 {
			count = core.as_int(vm.peek(v, 0))
		}
		s := core.string_get(core.as_string(vm.peek(v, arg_count - 2)))
		repl := core.string_get(core.as_string(vm.peek(v, arg_count - 1)))
		new_s, n := regex_subn(pat, repl, s, count)
		items: [dynamic]core.Value
		append(&items, core.make_string_value(new_s), core.make_int_value(n))
		t := core.make_list_object(items, true)
		vm.gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "split":
		if arg_count != 1 && arg_count != 2 {
			vm.runtime_error(v, "split() takes 1 or 2 arguments.")
			return false
		}
		maxsplit := 0
		if arg_count == 2 {
			maxsplit = core.as_int(vm.peek(v, 0))
		}
		s := core.string_get(core.as_string(vm.peek(v, arg_count - 1)))
		parts := regex_split(pat, s, maxsplit)
		items: [dynamic]core.Value
		for part in parts {
			append(&items, core.make_string_value(part))
		}
		delete(parts)
		l := core.make_list_object(items)
		vm.gc_track(v, &l.obj)
		result = core.make_object_value(&l.obj)
	case "findall":
		if arg_count != 1 {
			vm.runtime_error(v, "findall() takes 1 argument.")
			return false
		}
		result = regex_findall(v, pat, core.string_get(core.as_string(vm.peek(v, 0))))
	case:
		vm.runtime_error(v, "Undefined Pattern method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
