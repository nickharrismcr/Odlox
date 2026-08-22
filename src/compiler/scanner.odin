#+feature dynamic-literals
package compiler

// Scanner: turns Lox-derived source text into a fully materialized token
// list up front (not a lazy one-token-at-a-time stream). This is load
// bearing, not just a style choice: the compiler's `finally`-block
// handling snapshots a token index and replays a range of already-
// scanned tokens later, which only works if the whole stream is
// already a stable array by the time parsing starts. See
// docs/ARCHITECTURE.md's Scanner section.

import "core:strings"
import "core:fmt"

Token_Type :: enum {
	// punctuation
	Left_Paren, Right_Paren,
	Left_Brace, Right_Brace,
	Left_Bracket, Right_Bracket,
	Comma, Dot, Colon, Semicolon, Question, Eol, Ampersand,

	// one/two-char operators
	Percent, Percent_Equal,
	Minus, Minus_Equal, Arrow,
	Plus, Plus_Equal, Plus_Plus,
	Star, Star_Equal,
	Slash, Slash_Equal,
	Bang, Bang_Equal,
	Equal, Equal_Equal,
	Greater, Greater_Equal,
	Less, Less_Equal,

	// literals -- Int/Float are deliberately distinct tokens (not one
	// "number" kind): this feeds directly into Value's separate
	// Int/Float value types later.
	Identifier, String, Int, Float,

	// keywords
	And, Class, Else, False, For, Func, If, Nil, Or, Print, Return,
	Super, This, True, Var, While, Const, Break, Continue, Str,
	Import, Try, Except, As, Finally, Raise, Foreach, In, Breakpoint,
	Static, From,

	// meta
	Error, Eof,
}

@(private = "file")
keywords := map[string]Token_Type {
	"and"        = .And,
	"class"      = .Class,
	"else"       = .Else,
	"false"      = .False,
	"for"        = .For,
	"func"       = .Func,
	"fun"        = .Func, // legacy alias
	"if"         = .If,
	"nil"        = .Nil,
	"or"         = .Or,
	"print"      = .Print,
	"return"     = .Return,
	"super"      = .Super,
	"this"       = .This,
	"true"       = .True,
	"var"        = .Var,
	"while"      = .While,
	"const"      = .Const,
	"break"      = .Break,
	"continue"   = .Continue,
	"str"        = .Str,
	"import"     = .Import,
	"try"        = .Try,
	"except"     = .Except,
	"as"         = .As,
	"finally"    = .Finally,
	"raise"      = .Raise,
	"foreach"    = .Foreach,
	"in"         = .In,
	"breakpoint" = .Breakpoint,
	"static"     = .Static,
	"from"       = .From,
}

// Token.source is the backing text this token's lexeme slices from --
// either the original (normalised) source string, or, for a
// scanner-generated ("synthetic") token, a small standalone string owned
// by the token itself. Either way `lexeme` is an allocation-free slice.
Token :: struct {
	type:   Token_Type,
	source: string,
	start:  int,
	length: int,
	line:   int,
}

lexeme :: proc(t: Token) -> string {
	return t.source[t.start:t.start + t.length]
}

Scanner :: struct {
	source:  string, // normalised: \r\n and \r folded to \n, trailing \n guaranteed
	start:   int,
	current: int,
	line:    int,

	tokens:    [dynamic]Token,
	token_idx: int,

	// Queued synthetic tokens from string-interpolation desugaring
	// (see scan_string) -- drained by scan_token before it does any
	// real scanning.
	pending: [dynamic]Token,
}

// tokenize scans the entire source up front and returns a Scanner
// positioned at the first token; scan_token is an internal driver.
// Implicit-semicolon suppression runs as a second pass over the raw token
// stream (see keep_eol) rather than inline, since the decision to keep or
// drop an Eol needs to see both the token before and after it -- a single
// token of look-behind can't express "still inside an open `[`".
tokenize :: proc(source: string) -> Scanner {
	s := Scanner {
		source = normalize_source(source),
		line   = 1,
	}

	raw: [dynamic]Token
	defer delete(raw)
	for {
		tok := scan_token(&s)
		append(&raw, tok)
		if tok.type == .Eof {
			break
		}
	}

	for tok, i in raw {
		if tok.type == .Eol {
			prev_type := Token_Type.Eof
			if len(s.tokens) > 0 {
				prev_type = s.tokens[len(s.tokens) - 1].type
			}
			if !keep_eol(prev_type, next_significant_type(raw[:], i + 1)) {
				continue
			}
		}
		append(&s.tokens, tok)
	}

	s.token_idx = 0
	return s
}

destroy_scanner :: proc(s: ^Scanner) {
	delete(s.tokens)
	delete(s.pending)
}

// next_token consumes and returns the next token in the already-scanned
// stream, clamping at the trailing Eof so callers can keep calling this
// past the end without special-casing it.
next_token :: proc(s: ^Scanner) -> Token {
	if s.token_idx >= len(s.tokens) {
		return s.tokens[len(s.tokens) - 1]
	}
	t := s.tokens[s.token_idx]
	s.token_idx += 1
	return t
}

// peek_token returns the token next_token would return, without
// consuming it -- used for one-token lookahead (e.g. distinguishing
// `identifier =` from `identifier ,` before committing to a parse path).
peek_token :: proc(s: ^Scanner) -> Token {
	if s.token_idx >= len(s.tokens) {
		return s.tokens[len(s.tokens) - 1]
	}
	return s.tokens[s.token_idx]
}

print_tokens :: proc(s: ^Scanner) {
	for t in s.tokens {
		fmt.printf("%4d  %-14v  %q\n", t.line, t.type, lexeme(t))
	}
}

// -----------------------------------------------------------------------
// Implicit-semicolon suppression.
//
// An Eol token is dropped rather than kept in three situations: right
// after an opening bracket/separator/`=`/binary operator, right before a
// closing bracket or Eof, or right after another (kept) Eol (collapsing a
// blank line into one statement-boundary).

@(private = "file")
next_significant_type :: proc(raw: []Token, from: int) -> Token_Type {
	for i := from; i < len(raw); i += 1 {
		if raw[i].type != .Eol {
			return raw[i].type
		}
	}
	return .Eof
}

@(private = "file")
keep_eol :: proc(prev, next: Token_Type) -> bool {
	if prev == .Eol {
		return false // collapse consecutive blank lines
	}
	// Question is deliberately absent from the "prev continues" list
	// below, even though it leads the ternary operator (`cond ? a : b`)
	// the same way And/Or/Ampersand lead their own binary forms: `?` is
	// also reused postfix for a nilable type annotation (`int?`, see
	// type_expr.odin), and a line commonly *ends* right after one (`var
	// c: string?`). Since this pass has no parser context to tell the two
	// uses apart, always suppressing here would break every such
	// annotation; a ternary's `?` genuinely spanning a line break (`x ?\n
	// a : b`) is unsupported as a result -- not exercised anywhere in
	// lox_examples/tests today, and recoverable by keeping `?` and its
	// then-branch on the same line, which every existing script already does.
	#partial switch prev {
	case .Eof: // start of file (or of a re-scanned fragment): nothing to terminate yet
		return false
	case .Left_Paren, .Left_Brace, .Left_Bracket,
	     .Comma, .Colon, .Equal,
	     .Plus, .Minus, .Star, .Slash, .Percent,
	     .Plus_Equal, .Minus_Equal, .Star_Equal, .Slash_Equal, .Percent_Equal,
	     .Bang_Equal, .Equal_Equal, .Greater, .Greater_Equal, .Less, .Less_Equal,
	     .And, .Or, .Ampersand, .Plus_Plus:
		return false
	}
	#partial switch next {
	case .Right_Paren, .Right_Brace, .Right_Bracket, .Eof:
		return false
	}
	return true
}

// -----------------------------------------------------------------------
// Source normalisation

@(private = "file")
normalize_source :: proc(source: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, 0, len(source) + 1)
	i := 0
	for i < len(source) {
		c := source[i]
		if c == '\r' {
			strings.write_byte(&b, '\n')
			if i + 1 < len(source) && source[i + 1] == '\n' {
				i += 1
			}
		} else {
			strings.write_byte(&b, c)
		}
		i += 1
	}
	if strings.builder_len(b) == 0 || b.buf[len(b.buf) - 1] != '\n' {
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// -----------------------------------------------------------------------
// Character-level helpers

@(private = "file")
is_at_end :: proc(s: ^Scanner) -> bool {
	return s.current >= len(s.source)
}

@(private = "file")
peek :: proc(s: ^Scanner) -> u8 {
	if is_at_end(s) {
		return 0
	}
	return s.source[s.current]
}

@(private = "file")
peek_next :: proc(s: ^Scanner) -> u8 {
	if s.current + 1 >= len(s.source) {
		return 0
	}
	return s.source[s.current + 1]
}

@(private = "file")
advance_char :: proc(s: ^Scanner) -> u8 {
	c := s.source[s.current]
	s.current += 1
	return c
}

@(private = "file")
match_char :: proc(s: ^Scanner, expected: u8) -> bool {
	if is_at_end(s) || s.source[s.current] != expected {
		return false
	}
	s.current += 1
	return true
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private = "file")
make_token :: proc(s: ^Scanner, type: Token_Type) -> Token {
	return Token{type = type, source = s.source, start = s.start, length = s.current - s.start, line = s.line}
}

@(private = "file")
error_token :: proc(s: ^Scanner, msg: string) -> Token {
	return Token{type = .Error, source = msg, start = 0, length = len(msg), line = s.line}
}

// synthetic_token is package-visible (not file-private): the compiler
// also needs it, to fabricate the implicit `this`/unnamed slot at the
// head of every function's local table.
@(private)
synthetic_token :: proc(type: Token_Type, text: string, line: int) -> Token {
	return Token{type = type, source = text, start = 0, length = len(text), line = line}
}

// -----------------------------------------------------------------------
// Main dispatch

@(private = "file")
scan_token :: proc(s: ^Scanner) -> Token {
	if len(s.pending) > 0 {
		t := s.pending[0]
		ordered_remove(&s.pending, 0)
		return t
	}

	skip_whitespace_and_comments(s)
	s.start = s.current

	if is_at_end(s) {
		return make_token(s, .Eof)
	}

	c := advance_char(s)

	if is_alpha(c) {
		return scan_identifier(s)
	}
	if is_digit(c) {
		return scan_number(s)
	}

	switch c {
	case '\n':
		line := s.line
		s.line += 1
		return Token{type = .Eol, source = s.source, start = s.start, length = 1, line = line}
	case '(':
		return make_token(s, .Left_Paren)
	case ')':
		return make_token(s, .Right_Paren)
	case '{':
		return make_token(s, .Left_Brace)
	case '}':
		return make_token(s, .Right_Brace)
	case '[':
		return make_token(s, .Left_Bracket)
	case ']':
		return make_token(s, .Right_Bracket)
	case ',':
		return make_token(s, .Comma)
	case '.':
		return make_token(s, .Dot)
	case ':':
		return make_token(s, .Colon)
	case ';':
		return make_token(s, .Semicolon)
	case '?':
		return make_token(s, .Question)
	case '&':
		return make_token(s, .Ampersand)
	case '%':
		return make_token(s, .Percent_Equal if match_char(s, '=') else .Percent)
	case '*':
		return make_token(s, .Star_Equal if match_char(s, '=') else .Star)
	case '/':
		return make_token(s, .Slash_Equal if match_char(s, '=') else .Slash)
	case '!':
		return make_token(s, .Bang_Equal if match_char(s, '=') else .Bang)
	case '=':
		return make_token(s, .Equal_Equal if match_char(s, '=') else .Equal)
	case '<':
		return make_token(s, .Less_Equal if match_char(s, '=') else .Less)
	case '>':
		return make_token(s, .Greater_Equal if match_char(s, '=') else .Greater)
	case '+':
		if match_char(s, '+') {
			return make_token(s, .Plus_Plus)
		}
		return make_token(s, .Plus_Equal if match_char(s, '=') else .Plus)
	case '-':
		if match_char(s, '=') {
			return make_token(s, .Minus_Equal)
		}
		return make_token(s, .Arrow if match_char(s, '>') else .Minus)
	case '"':
		return scan_string(s, '"')
	case '\'':
		return scan_string(s, '\'')
	}

	return error_token(s, fmt.aprintf("Unexpected character '%c'.", c))
}

@(private = "file")
skip_whitespace_and_comments :: proc(s: ^Scanner) {
	for {
		switch peek(s) {
		case ' ', '\t':
			advance_char(s)
		case '/':
			if peek_next(s) == '/' {
				for peek(s) != '\n' && !is_at_end(s) {
					advance_char(s)
				}
			} else {
				return
			}
		case:
			return
		}
	}
}

@(private = "file")
scan_identifier :: proc(s: ^Scanner) -> Token {
	for is_alpha(peek(s)) || is_digit(peek(s)) {
		advance_char(s)
	}
	text := s.source[s.start:s.current]
	if type, ok := keywords[text]; ok {
		return make_token(s, type)
	}
	return make_token(s, .Identifier)
}

// scan_number distinguishes Int from Float purely lexically: a digit run
// with no following `.digit` is an Int. No exponent/hex support -- not a
// gap to fix, matches the source language.
@(private = "file")
scan_number :: proc(s: ^Scanner) -> Token {
	for is_digit(peek(s)) {
		advance_char(s)
	}
	if peek(s) == '.' && is_digit(peek_next(s)) {
		advance_char(s) // consume '.'
		for is_digit(peek(s)) {
			advance_char(s)
		}
		return make_token(s, .Float)
	}
	return make_token(s, .Int)
}

// -----------------------------------------------------------------------
// String scanning, with scan-time interpolation desugaring.
// `"lit0 ${expr0} lit1"` desugars into a synthetic token stream equivalent
// to `( "lit0 " & str(expr0) & " lit1" )`, queued in s.pending and drained
// one-by-one by later scan_token calls -- no interpolation concept exists
// past this point. `$$` escapes to a literal `$`.

@(private = "file")
String_Part :: struct {
	is_expr: bool,
	text:    string, // literal text, or (for is_expr) the expression's own source text
}

@(private = "file")
scan_string :: proc(s: ^Scanner, quote: u8) -> Token {
	start_line := s.line
	parts: [dynamic]String_Part
	lit: strings.Builder
	strings.builder_init(&lit)
	has_interp := false
	has_escape := false

	for {
		if is_at_end(s) {
			return error_token(s, "Unterminated string.")
		}
		c := peek(s)
		if c == quote {
			advance_char(s)
			break
		}
		if c == '\n' {
			// A literal newline inside a string is content, not an error --
			// e.g. a multi-line string literal embedding another
			// language's source verbatim. Every other character in this
			// loop already falls through to the generic write-and-advance
			// below; '\n' just also needs the line counter bumped so
			// later tokens/error messages still report accurate line
			// numbers.
			s.line += 1
		}
		if c == '$' && peek_next(s) == '$' {
			has_escape = true
			advance_char(s)
			advance_char(s)
			strings.write_byte(&lit, '$')
			continue
		}
		if c == '$' && peek_next(s) == '{' {
			has_interp = true
			// strings.to_string(lit) is a view into the builder's live
			// buffer, not a copy -- clone it before reset/reuse or the
			// next literal segment's writes silently corrupt this one.
			append(&parts, String_Part{false, strings.clone(strings.to_string(lit))})
			strings.builder_reset(&lit)
			advance_char(s) // '$'
			advance_char(s) // '{'
			expr_start := s.current
			depth := 1
			for depth > 0 {
				if is_at_end(s) {
					return error_token(s, "Unterminated string interpolation.")
				}
				ic := peek(s)
				switch ic {
				case '{':
					depth += 1
					advance_char(s)
				case '}':
					depth -= 1
					advance_char(s)
				case quote:
					// Skip a nested string literal whole so its own
					// braces/quotes can't confuse this depth count.
					advance_char(s)
					for !is_at_end(s) && peek(s) != quote {
						advance_char(s)
					}
					if !is_at_end(s) {
						advance_char(s)
					}
				case:
					advance_char(s)
				}
			}
			append(&parts, String_Part{true, s.source[expr_start:s.current - 1]})
			continue
		}
		strings.write_byte(&lit, c)
		advance_char(s)
	}

	if !has_interp && !has_escape {
		// Nothing to unescape or desugar: the raw quoted source slice
		// is already exactly right (the compiler strips the quote
		// bytes itself), so skip the builder/parts machinery entirely.
		strings.builder_destroy(&lit)
		return make_token(s, .String)
	}

	append(&parts, String_Part{false, strings.to_string(lit)})

	if !has_interp {
		// Escaped (`$$`) but not interpolated: one literal part, no
		// `&`-chain needed -- just quote-wrap the unescaped text.
		quoted := strings.concatenate({"\"", parts[0].text, "\""})
		delete(parts)
		return synthetic_token(.String, quoted, start_line)
	}

	non_empty: [dynamic]String_Part
	for part in parts {
		if part.is_expr || len(part.text) > 0 {
			append(&non_empty, part)
		}
	}

	append(&s.pending, synthetic_token(.Left_Paren, "(", start_line))
	first := true
	for part in non_empty {
		if !first {
			append(&s.pending, synthetic_token(.Ampersand, "&", start_line))
		}
		first = false
		if part.is_expr {
			// `str` is the reserved keyword (Token_Type.Str) whose
			// prefix parse rule compiles `str(expr)` straight to
			// Op_Code.Str -- not a call to some assumed-to-exist global
			// function named "str". Using the keyword token here (not
			// Identifier) keeps interpolation and hand-written
			// `str(...)` going through the exact same compiled path.
			append(&s.pending, synthetic_token(.Str, "str", start_line))
			append(&s.pending, synthetic_token(.Left_Paren, "(", start_line))
			for t in scan_expr_fragment(part.text, start_line) {
				append(&s.pending, t)
			}
			append(&s.pending, synthetic_token(.Right_Paren, ")", start_line))
		} else {
			// The compiler's string-literal handler always strips the
			// first/last byte of a String token's lexeme as "the
			// quotes" -- so wrapping the raw literal text in a pair of
			// quote bytes here (regardless of what's inside it) is all
			// that's needed; this token is never re-scanned.
			quoted := strings.concatenate({"\"", part.text, "\""})
			append(&s.pending, synthetic_token(.String, quoted, start_line))
		}
	}
	append(&s.pending, synthetic_token(.Right_Paren, ")", start_line))

	first_tok := s.pending[0]
	ordered_remove(&s.pending, 0)
	return first_tok
}

// scan_expr_fragment recursively tokenizes an interpolated expression's
// own source text (a slice of the outer source), retagging every token
// to the outer string literal's start line and dropping the trailing
// Eof (and any stray Eol -- an interpolated expression is one line of
// its own by construction).
@(private = "file")
scan_expr_fragment :: proc(text: string, line: int) -> []Token {
	sub := tokenize(text)
	result: [dynamic]Token
	for t in sub.tokens {
		if t.type == .Eof || t.type == .Eol {
			continue
		}
		rt := t
		rt.line = line
		append(&result, rt)
	}
	delete(sub.tokens)
	delete(sub.pending)
	return result[:]
}
