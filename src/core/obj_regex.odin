package core

import "core:text/regex"

// Regex_Pattern_Object wraps a compiled regular expression (Odin's own
// core:text/regex engine) plus a capture-group-number -> name map, since
// that engine's own pattern syntax has no equivalent of Python/RE2's
// (?P<name>...) named groups at all -- named-group support here is
// this port's own preprocessing layer (see vm/regex.odin's
// preprocess_pattern), which strips the name out before compiling and
// remembers which group number it corresponded to.
Regex_Pattern_Object :: struct {
	using obj:   Obj,
	regex:       regex.Regular_Expression,
	group_names: map[int]string, // 1-based capture-group number -> name, only present entries
	num_groups:  int, // highest capture-group number in the pattern (0 if none)
	source:      string, // original pattern text, for Pattern.__str__ / error messages
}

make_regex_pattern_object :: proc(re: regex.Regular_Expression, group_names: map[int]string, num_groups: int, source: string) -> ^Regex_Pattern_Object {
	o := new(Regex_Pattern_Object)
	o.obj.type = .Regex_Pattern
	o.regex = re
	o.group_names = group_names
	o.num_groups = num_groups
	o.source = source
	return o
}

// Regex_Match_Object is the result of a successful search/match/fullmatch --
// pos[0]/groups[0] is the whole match, pos[i]/groups[i] (i>=1) is capture
// group i. group_names is a borrowed reference to the pattern that
// produced this match (not owned/freed here -- see gc.odin's free case).
Regex_Match_Object :: struct {
	using obj:   Obj,
	pos:         [][2]int,
	groups:      []string,
	group_names: map[int]string,
}

make_regex_match_object :: proc(pos: [][2]int, groups: []string, group_names: map[int]string) -> ^Regex_Match_Object {
	o := new(Regex_Match_Object)
	o.obj.type = .Regex_Match
	o.pos = pos
	o.groups = groups
	o.group_names = group_names
	return o
}
