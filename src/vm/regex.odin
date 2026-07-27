package vm

import "../core"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:text/regex/virtual_machine"

// re module engine: pattern preprocessing (named-group support, since
// Odin's own core:text/regex syntax has no equivalent of Python/RE2's
// (?P<name>...)), compiling, and the search/match/fullmatch/sub/subn/
// split/findall operations both the module-level free functions
// (natives/re.odin) and the Pattern/Match objects' own methods
// (invoke_builtin_regex_pattern/invoke_builtin_regex_match below) share.
//
// One accepted, narrow limitation: Odin's regex.match_and_allocate_capture
// (and the iterator form) compact away any capture group that didn't
// participate in a given match, rather than leaving a hole -- so a group
// *after* one that failed to participate (e.g. one side of an
// alternation) would be misnumbered here. Not exercised by anything in
// the ported test suite; accepted rather than reimplementing capture
// extraction against the lower-level virtual_machine package directly.

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

regex_compile :: proc(vm: ^VM, pattern: string) -> (^core.Regex_Pattern_Object, bool) {
	rewritten, names := preprocess_pattern(pattern)
	num_groups := regex_num_groups(rewritten)
	re, err := regex.create(rewritten)
	if err != nil {
		delete(names)
		runtime_error(vm, "re: invalid pattern: %v", err)
		return nil, false
	}
	obj := core.make_regex_pattern_object(re, names, num_groups, pattern)
	gc_track(vm, &obj.obj)
	return obj, true
}

@(private = "file")
regex_search_raw :: proc(vm: ^VM, pat: ^core.Regex_Pattern_Object, s: string) -> core.Value {
	capture, ok := regex.match_and_allocate_capture(pat.regex, s)
	if !ok {
		return core.NIL_VALUE
	}
	m := core.make_regex_match_object(capture.pos, capture.groups, pat.group_names)
	gc_track(vm, &m.obj)
	return core.make_object_value(&m.obj)
}

regex_search :: proc(vm: ^VM, pat: ^core.Regex_Pattern_Object, s: string) -> core.Value {
	return regex_search_raw(vm, pat, s)
}

// regex_match/regex_fullmatch don't re-anchor the compiled pattern --
// they reuse a plain search and check the result's own span, since any
// regex engine that tries starting positions left-to-right (as Odin's
// thread-based VM does) finds a position-0 match first if one exists,
// making "search, then check span" equivalent to a true anchored match
// without needing a second compiled variant per anchoring mode.
regex_match :: proc(vm: ^VM, pat: ^core.Regex_Pattern_Object, s: string) -> core.Value {
	v := regex_search_raw(vm, pat, s)
	if v.type != .Obj {
		return core.NIL_VALUE
	}
	m := core.as_regex_match(v)
	if m.pos[0][0] != 0 {
		return core.NIL_VALUE
	}
	return v
}

regex_fullmatch :: proc(vm: ^VM, pat: ^core.Regex_Pattern_Object, s: string) -> core.Value {
	v := regex_search_raw(vm, pat, s)
	if v.type != .Obj {
		return core.NIL_VALUE
	}
	m := core.as_regex_match(v)
	if m.pos[0][0] != 0 || m.pos[0][1] != len(s) {
		return core.NIL_VALUE
	}
	return v
}

// regex_iterate_matches returns every non-overlapping match, up to limit
// (0 = unlimited) -- caller owns and must delete() each Capture's pos/
// groups slices, and the returned dynamic array itself.
@(private = "file")
regex_iterate_matches :: proc(pat: ^core.Regex_Pattern_Object, s: string, limit: int) -> [dynamic]regex.Capture {
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
// against capture's own groups, matching Go's regexp replacement syntax
// (glox's own re module is built on Go's regexp and documents this exact
// syntax, not Python's \1/\g<name>).
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

regex_subn :: proc(pat: ^core.Regex_Pattern_Object, repl: string, s: string, count: int) -> (result: string, n: int) {
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

regex_split :: proc(pat: ^core.Regex_Pattern_Object, s: string, maxsplit: int) -> []string {
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

regex_findall :: proc(vm: ^VM, pat: ^core.Regex_Pattern_Object, s: string) -> core.Value {
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
			gc_track(vm, &t.obj)
			append(&items, core.make_object_value(&t.obj, true))
		}
	}
	l := core.make_list_object(items)
	gc_track(vm, &l.obj)
	return core.make_object_value(&l.obj)
}

// -----------------------------------------------------------------------
// Match object methods

@(private = "file")
regex_match_group_at :: proc(m: ^core.Regex_Match_Object, idx: int) -> core.Value {
	if idx < 0 || idx >= len(m.groups) {
		return core.NIL_VALUE
	}
	return core.make_string_value(m.groups[idx])
}

@(private = "file")
regex_group_index_for_name :: proc(m: ^core.Regex_Match_Object, name: string) -> (int, bool) {
	for gn, gname in m.group_names {
		if gname == name {
			return gn, true
		}
	}
	return -1, false
}

invoke_builtin_regex_match :: proc(v: ^VM, m: ^core.Regex_Match_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "group":
		if arg_count == 0 {
			result = regex_match_group_at(m, 0)
		} else if arg_count == 1 {
			key := peek(v, 0)
			if core.is_int(key) {
				result = regex_match_group_at(m, core.as_int(key))
			} else if core.is_string(key) {
				idx, ok := regex_group_index_for_name(m, core.string_get(core.as_string(key)))
				if !ok {
					runtime_error(v, "No such group: '%s'.", core.string_get(core.as_string(key)))
					return false
				}
				result = regex_match_group_at(m, idx)
			} else {
				runtime_error(v, "group() argument must be an int or string.")
				return false
			}
		} else {
			runtime_error(v, "group() takes 0 or 1 arguments.")
			return false
		}
	case "groups":
		if arg_count != 0 {
			runtime_error(v, "groups() takes no arguments.")
			return false
		}
		items: [dynamic]core.Value
		for i in 1 ..< len(m.groups) {
			append(&items, core.make_string_value(m.groups[i]))
		}
		t := core.make_list_object(items, true)
		gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "groupdict":
		if arg_count != 0 {
			runtime_error(v, "groupdict() takes no arguments.")
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
			idx = core.as_int(peek(v, 0))
		} else if arg_count != 0 {
			runtime_error(v, "start() takes 0 or 1 arguments.")
			return false
		}
		if idx < 0 || idx >= len(m.pos) {
			runtime_error(v, "No such group: %d.", idx)
			return false
		}
		result = core.make_int_value(m.pos[idx][0])
	case "end":
		idx := 0
		if arg_count == 1 {
			idx = core.as_int(peek(v, 0))
		} else if arg_count != 0 {
			runtime_error(v, "end() takes 0 or 1 arguments.")
			return false
		}
		if idx < 0 || idx >= len(m.pos) {
			runtime_error(v, "No such group: %d.", idx)
			return false
		}
		result = core.make_int_value(m.pos[idx][1])
	case "span":
		idx := 0
		if arg_count == 1 {
			idx = core.as_int(peek(v, 0))
		} else if arg_count != 0 {
			runtime_error(v, "span() takes 0 or 1 arguments.")
			return false
		}
		if idx < 0 || idx >= len(m.pos) {
			runtime_error(v, "No such group: %d.", idx)
			return false
		}
		items: [dynamic]core.Value
		append(&items, core.make_int_value(m.pos[idx][0]), core.make_int_value(m.pos[idx][1]))
		t := core.make_list_object(items, true)
		gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case:
		runtime_error(v, "Undefined Match method '%s'.", name)
		return false
	}
	collapse_call(v, arg_count, result)
	return true
}

// -----------------------------------------------------------------------
// Pattern object methods -- same operations as the module-level
// functions, minus the leading pattern argument (natives/re.odin's free
// functions call the same regex_* helpers above directly).

invoke_builtin_regex_pattern :: proc(v: ^VM, pat: ^core.Regex_Pattern_Object, name: string, arg_count: int) -> bool {
	result: core.Value
	switch name {
	case "search":
		if arg_count != 1 {
			runtime_error(v, "search() takes 1 argument.")
			return false
		}
		result = regex_search(v, pat, core.string_get(core.as_string(peek(v, 0))))
	case "match":
		if arg_count != 1 {
			runtime_error(v, "match() takes 1 argument.")
			return false
		}
		result = regex_match(v, pat, core.string_get(core.as_string(peek(v, 0))))
	case "fullmatch":
		if arg_count != 1 {
			runtime_error(v, "fullmatch() takes 1 argument.")
			return false
		}
		result = regex_fullmatch(v, pat, core.string_get(core.as_string(peek(v, 0))))
	case "sub":
		if arg_count != 2 && arg_count != 3 {
			runtime_error(v, "sub() takes 2 or 3 arguments.")
			return false
		}
		count := 0
		if arg_count == 3 {
			count = core.as_int(peek(v, 0))
		}
		s := core.string_get(core.as_string(peek(v, arg_count - 2)))
		repl := core.string_get(core.as_string(peek(v, arg_count - 1)))
		new_s, _ := regex_subn(pat, repl, s, count)
		result = core.make_string_value(new_s)
	case "subn":
		if arg_count != 2 && arg_count != 3 {
			runtime_error(v, "subn() takes 2 or 3 arguments.")
			return false
		}
		count := 0
		if arg_count == 3 {
			count = core.as_int(peek(v, 0))
		}
		s := core.string_get(core.as_string(peek(v, arg_count - 2)))
		repl := core.string_get(core.as_string(peek(v, arg_count - 1)))
		new_s, n := regex_subn(pat, repl, s, count)
		items: [dynamic]core.Value
		append(&items, core.make_string_value(new_s), core.make_int_value(n))
		t := core.make_list_object(items, true)
		gc_track(v, &t.obj)
		result = core.make_object_value(&t.obj, true)
	case "split":
		if arg_count != 1 && arg_count != 2 {
			runtime_error(v, "split() takes 1 or 2 arguments.")
			return false
		}
		maxsplit := 0
		if arg_count == 2 {
			maxsplit = core.as_int(peek(v, 0))
		}
		s := core.string_get(core.as_string(peek(v, arg_count - 1)))
		parts := regex_split(pat, s, maxsplit)
		items: [dynamic]core.Value
		for part in parts {
			append(&items, core.make_string_value(part))
		}
		delete(parts)
		l := core.make_list_object(items)
		gc_track(v, &l.obj)
		result = core.make_object_value(&l.obj)
	case "findall":
		if arg_count != 1 {
			runtime_error(v, "findall() takes 1 argument.")
			return false
		}
		result = regex_findall(v, pat, core.string_get(core.as_string(peek(v, 0))))
	case:
		runtime_error(v, "Undefined Pattern method '%s'.", name)
		return false
	}
	collapse_call(v, arg_count, result)
	return true
}
