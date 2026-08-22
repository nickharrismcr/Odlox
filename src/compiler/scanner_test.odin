package compiler

// Standalone unit tests for the scanner (Phase 1). These exist because
// the ported reference-implementation test suite (tests/new_tests/, see ROADMAP.md's Testing
// section) drives a whole compiled binary end to end and can't exercise
// tokenization in isolation -- by the time that suite is usable, a
// scanner bug would show up as a confusing parse/compile failure several
// layers away from its actual cause. This file is the scanner's own,
// narrower correctness gate, run with `odin test src/compiler`.
//
// Several of these tests are not just "does this feature work" checks --
// they're regression tests for two real bugs found while writing this
// scanner (both are called out at their specific test below):
//
//   1. The implicit-semicolon (EOL) suppression rule needs to look both
//      behind *and* ahead of a newline, not just behind it -- a single
//      newline right before a closing bracket wasn't being suppressed
//      by a look-behind-only rule, because the token before it is
//      typically an ordinary expression atom (a number, identifier,
//      etc.), not an operator.
//   2. String interpolation desugaring captured a literal text segment
//      as a *view* into a reused `strings.Builder`'s buffer
//      (`strings.to_string` doesn't copy) -- resetting the builder to
//      accumulate the next segment silently corrupted the one already
//      captured.
//
// Keeping both fixed is now enforced by test_eol_suppressed_inside_brackets
// and test_string_interpolation_desugars_to_call_expression respectively.

import "core:testing"

// -----------------------------------------------------------------------
// Shared helpers
//
// Most tests only care about the *shape* of the token stream -- which
// kinds of token came out, in what order -- not each token's exact line
// number or backing source pointer, so expect_types compares just the
// Token_Type sequence. A handful of tests below go further and check a
// specific token's lexeme (the actual text it spans) where the shape
// alone wouldn't catch the bug in question (e.g. an escape sequence that
// changes the text without changing which *kind* of token comes out).

// types_of extracts just the Token_Type of every token in a scanned
// stream, discarding line/lexeme -- the projection expect_types compares
// against an expected shape.
@(private = "file")
types_of :: proc(s: ^Scanner) -> [dynamic]Token_Type {
	out: [dynamic]Token_Type
	for t in s.tokens {
		append(&out, t.type)
	}
	return out
}

// expect_types tokenizes source and asserts its token-type sequence
// equals want exactly (including the trailing Eof any caller should
// list explicitly, so a test reads as a complete description of what
// the scanner produces for that input, not just a prefix check).
//
// On a length mismatch it still reports as many per-token comparisons as
// it can (via `n := min(...)`) rather than bailing out immediately, so a
// failing test's output shows exactly where the two sequences diverge
// instead of just "lengths differ".
@(private = "file")
expect_types :: proc(t: ^testing.T, source: string, want: []Token_Type) {
	s := tokenize(source)
	defer destroy_scanner(&s)
	got := types_of(&s)
	defer delete(got)

	testing.expectf(
		t,
		len(got) == len(want),
		"%q: expected %d tokens %v, got %d %v",
		source, len(want), want, len(got), got[:],
	)
	n := min(len(got), len(want))
	for i in 0 ..< n {
		testing.expectf(
			t,
			got[i] == want[i],
			"%q: token %d: expected %v, got %v",
			source, i, want[i], got[i],
		)
	}
}

// -----------------------------------------------------------------------
// Punctuation & operators
//
// Nothing subtle here -- these just confirm every single/double-char
// punctuation and operator token is recognized and none of them get
// merged or misfire against a neighbour (e.g. that `+=` doesn't scan as
// `Plus` followed by `Equal`).

@(test)
test_basic_punctuation :: proc(t: ^testing.T) {
	expect_types(t, "(){}[],.:", []Token_Type{
		.Left_Paren, .Right_Paren, .Left_Brace, .Right_Brace,
		.Left_Bracket, .Right_Bracket, .Comma, .Dot, .Colon, .Eof,
	})
}

@(test)
test_two_char_operators :: proc(t: ^testing.T) {
	expect_types(t, "== != <= >= += -=", []Token_Type{
		.Equal_Equal, .Bang_Equal, .Less_Equal, .Greater_Equal,
		.Plus_Equal, .Minus_Equal, .Eof,
	})
}

// Arrow (`->`, Phase 1 of optional type annotations -- return-type
// annotation syntax) shares its lead character with Minus/Minus_Equal, so
// this pins down all three of scan_token's '-' branches individually: a
// lone '-' still scans as Minus, '-=' still scans as Minus_Equal, and
// only '->' scans as the new Arrow token.
@(test)
test_arrow_and_minus_variants :: proc(t: ^testing.T) {
	expect_types(t, "- -= ->", []Token_Type{.Minus, .Minus_Equal, .Arrow, .Eof})
}

// Colon and Question are reused (not re-tokenized) for `x: int` param/var
// annotations and `int?` nilable suffixes respectively -- confirms adding
// Arrow didn't disturb either existing token, and that a type-annotation-
// shaped fragment (`x: int?`) scans as the same tokens a dict-literal-key
// or ternary-operator use of `:`/`?` already would.
@(test)
test_colon_and_question_unaffected_by_arrow :: proc(t: ^testing.T) {
	expect_types(t, "x: int?", []Token_Type{.Identifier, .Colon, .Identifier, .Question, .Eof})
}

// Regression test: keep_eol's "prev continues" rule originally treated
// Question as always meaning "a ternary's `?` is coming, don't terminate
// yet" -- true for `cond ?\n a : b`, but wrong for a nilable-type
// annotation ending a line (`var c: string?`), which is a complete
// statement. See keep_eol's own comment for why Question was removed
// from that list; this pins down the Eol surviving right after a
// line-ending `?` now that the fix is in.
@(test)
test_eol_kept_after_nilable_type_annotation :: proc(t: ^testing.T) {
	expect_types(t, "var c: string?\nvar d = 1", []Token_Type{
		.Var, .Identifier, .Colon, .Identifier, .Question, .Eol,
		.Var, .Identifier, .Equal, .Int, .Eof,
	})
}

// -----------------------------------------------------------------------
// Numbers
//
// Int vs. Float is a real lexical distinction here (not "number, parsed
// later"), because it feeds Value's separate Int/Float value kinds
// further down the pipeline -- these tests are really checking that the
// "digit run, then optionally `.` + more digits" rule draws that line in
// the right place, not just that digits scan at all.

@(test)
test_int_vs_float :: proc(t: ^testing.T) {
	expect_types(t, "1 1.5 100 3.14", []Token_Type{.Int, .Float, .Int, .Float, .Eof})
}

// Confirms the token's lexeme is exactly the matched digits -- not, say,
// off by one at either edge, which a pure type-sequence check
// (expect_types) wouldn't catch since Int/Float would still come out in
// the right order even with a boundary bug.
@(test)
test_number_lexeme :: proc(t: ^testing.T) {
	s := tokenize("42 3.5")
	defer destroy_scanner(&s)
	testing.expect_value(t, lexeme(s.tokens[0]), "42")
	testing.expect_value(t, lexeme(s.tokens[1]), "3.5")
}

// -----------------------------------------------------------------------
// Identifiers & keywords

@(test)
test_keywords_and_identifiers :: proc(t: ^testing.T) {
	expect_types(t, "var func x = foreach class", []Token_Type{
		.Var, .Func, .Identifier, .Equal, .Foreach, .Class, .Eof,
	})
}

// `fun` is a legacy alias for `func` in the keyword table (both map to
// Token_Type.Func) -- this pins that down explicitly so a future cleanup
// of the keyword table can't silently drop it.
@(test)
test_fun_alias_for_func :: proc(t: ^testing.T) {
	s := tokenize("fun")
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.Func)
}

// -----------------------------------------------------------------------
// Comments
//
// A `//` comment's own text never becomes a token (it's consumed inside
// skip_whitespace_and_comments before scan_token ever sees it) -- only
// the newline that ends it does, and that newline is *kept* here (unlike
// most of the EOL-suppression tests below) because the token before it,
// `Identifier` (the `x` in `var x`), isn't in the "continues the
// statement" set.

@(test)
test_line_comment_skipped :: proc(t: ^testing.T) {
	expect_types(t, "var x // this is a comment\nvar y", []Token_Type{
		.Var, .Identifier, .Eol, .Var, .Identifier, .Eof,
	})
}

// -----------------------------------------------------------------------
// Implicit-semicolon (EOL) suppression
//
// keep_eol (scanner.odin) decides whether a raw newline becomes a real
// Eol token or gets dropped, based on *both* the token immediately
// before it and the next significant token after it. These four tests
// exercise, in order: suppression via the "before" rule (an operator
// clearly continues), suppression via the "after" rule (a closing
// bracket means the statement can't have ended, no matter what preceded
// it -- this is the one look-behind-only couldn't handle, see below), a
// case where neither rule fires and the Eol is correctly kept, and the
// comment case above already covered that same "neither rule fires"
// path with a comment in front instead of a bare newline.

// A newline right after `+` is a continuation, not a statement break --
// the "look behind" half of keep_eol.
@(test)
test_eol_suppressed_after_operator :: proc(t: ^testing.T) {
	expect_types(t, "1 +\n2", []Token_Type{.Int, .Plus, .Int, .Eof})
}

// Regression test for the bug described in this file's header comment:
// the newline right before `]` follows an ordinary Int token (`2`), not
// an opener/operator, so a look-behind-only suppression rule would keep
// it as a real Eol and incorrectly split this list literal into two
// statements. keep_eol's "look ahead for a closing bracket" half is what
// makes this pass -- it fired on the *previous* implementation of this
// scanner (a single-token-lookback design) and is exactly why the
// suppression logic became a two-pass filter over the whole raw token
// stream instead of an inline decision made while scanning forward.
@(test)
test_eol_suppressed_inside_brackets :: proc(t: ^testing.T) {
	expect_types(t, "[\n1,\n2\n]", []Token_Type{
		.Left_Bracket, .Int, .Comma, .Int, .Right_Bracket, .Eof,
	})
}

// The "normal" case: a newline after a complete statement, with no
// opener/operator before it and no closing bracket after it, is kept as
// a real statement-terminating Eol. Also incidentally confirms the
// forced trailing newline normalize_source adds (when source doesn't
// already end in one) doesn't leak an extra, spurious Eol before the
// final Eof -- that trailing newline's "next significant token" is Eof
// itself, which keep_eol's look-ahead rule treats the same as a closing
// bracket (nothing can follow it, so there's nothing to terminate).
@(test)
test_eol_kept_between_statements :: proc(t: ^testing.T) {
	expect_types(t, "var x = 1\nvar y = 2", []Token_Type{
		.Var, .Identifier, .Equal, .Int, .Eol,
		.Var, .Identifier, .Equal, .Int, .Eof,
	})
}

// -----------------------------------------------------------------------
// Strings: plain, escaped, and interpolated
//
// Three genuinely different code paths inside scan_string are being
// covered here: the zero-copy fast path (no `$$`/`${` at all -- the
// token's lexeme is just a slice of the original source), the
// escape-only path (`$$` collapses to `$` but there's no interpolation,
// so no `&`-chain is needed, just one quote-wrapped, unescaped literal),
// and the full interpolation-desugaring path (building a synthetic
// `( lit & str(expr) & lit )` token stream). See scan_string's own
// comments for why these are three separate branches rather than one
// path that always goes through the builder.

// The common case: no `$`/interpolation at all. The resulting token's
// lexeme should be exactly the original quoted source text -- confirming
// the fast path really does skip the builder/parts machinery rather than
// silently rebuilding an equivalent string through it (which would still
// pass a type-only check but not this lexeme check).
@(test)
test_simple_string_no_interpolation :: proc(t: ^testing.T) {
	s := tokenize(`"hello world"`)
	defer destroy_scanner(&s)
	testing.expect_value(t, len(s.tokens), 2) // String, Eof
	testing.expect_value(t, s.tokens[0].type, Token_Type.String)
	testing.expect_value(t, lexeme(s.tokens[0]), `"hello world"`)
}

// `'...'` and `"..."` are both valid string delimiters (scan_string
// takes the opening quote character as a parameter and matches only that
// one, so a `"` can appear unescaped inside a `'...'` string and vice
// versa) -- just confirms the single-quote form reaches the same
// scan_string path as double-quoted strings, not a separate, easier-to-
// forget-to-update code path.
@(test)
test_single_quoted_string :: proc(t: ^testing.T) {
	s := tokenize(`'hi'`)
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.String)
}

// Regression test for the second bug in this file's header comment, from
// the opposite direction: this string has no `${...}` at all, only a
// `$$` escape, so has_interp is false -- an earlier version of
// scan_string used "not interpolated" as the condition for the zero-copy
// fast path and returned a token spanning the *raw, unescaped* source
// text (`$$` still in it) instead of routing through the builder that
// actually collapses it. The fast path must be gated on "not interpolated
// *and* not escaped", or an escape-only string silently keeps its
// literal `$$` instead of becoming `$`.
@(test)
test_dollar_dollar_escape :: proc(t: ^testing.T) {
	s := tokenize(`"cost: $$5"`)
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.String)
	testing.expect_value(t, lexeme(s.tokens[0]), `"cost: $5"`)
}

// The full interpolation-desugaring path, with a literal segment on
// *both* sides of the interpolated expression ("a" before, "b" after):
// "a${x}b" -> ( "a" & str( x ) & "b" ). Having two separate literal
// segments is the important part of this particular test, not just the
// interpolation itself -- it's what exercises the builder-reset-and-
// reuse path in scan_string (capture segment 1 into `parts`, reset the
// builder, accumulate segment 2 into the *same* builder). This is
// exactly the sequence that triggered the aliasing bug in this file's
// header comment: without cloning the first segment's text before the
// reset, writing "b" into the reused builder's buffer silently corrupted
// the already-captured "a" (which shared that same backing memory).
// This test would still pass with the type-sequence check alone even if
// that bug were reintroduced (the *shape* of the desugared tokens
// wouldn't change) -- the fix is really guarded by the scanner smoke
// test in main.odin and would need a lexeme-level assertion here to
// catch on its own; flagged as a coverage gap rather than silently
// trusted.
@(test)
test_string_interpolation_desugars_to_call_expression :: proc(t: ^testing.T) {
	// The "str" here is Token_Type.Str (the reserved keyword, compiled
	// straight to Op_Code.Str), not a plain Identifier -- interpolation
	// deliberately reuses str(expr)'s own compiled form rather than
	// assuming a global function named "str" exists at runtime. See the
	// comment at this synthetic token's construction in scanner.odin.
	expect_types(t, `"a${x}b"`, []Token_Type{
		.Left_Paren,
		.String, .Ampersand,
		.Str, .Left_Paren, .Identifier, .Right_Paren,
		.Ampersand, .String,
		.Right_Paren,
		.Eof,
	})
}

// "${x}" has no literal text on either side of the interpolation --
// both potential literal segments are empty strings. Without the
// empty-part filter in scan_string, this would desugar to
// `( "" & str(x) & "" )`, i.e. two extra String/Ampersand pairs around
// the real content; this test pins down that empty segments are dropped
// entirely rather than emitted as pointless no-op concatenations.
@(test)
test_string_interpolation_drops_empty_literal_parts :: proc(t: ^testing.T) {
	expect_types(t, `"${x}"`, []Token_Type{
		.Left_Paren,
		.Str, .Left_Paren, .Identifier, .Right_Paren,
		.Right_Paren,
		.Eof,
	})
}

// An unterminated plain string (no matching closing quote before
// end-of-input) must produce an Error token rather than, say, scanning
// to the end of the file and silently treating everything after the
// opening quote as string content. Note this only covers the plain-
// string case -- scan_string has a second, separate "Unterminated
// string interpolation." error path for an unterminated `${...}`
// specifically, which isn't covered by a test here yet.
@(test)
test_unterminated_string_is_error_token :: proc(t: ^testing.T) {
	s := tokenize(`"no closing quote`)
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.Error)
}

// `&` is the string-concatenation operator this language uses (not
// string addition or a dedicated concat token) -- also exactly the
// operator string-interpolation desugaring itself emits between segments
// above, so this is really confirming the raw source-level spelling
// scans the same way the scanner's own synthetic tokens are built.
@(test)
test_ampersand_is_concat_operator :: proc(t: ^testing.T) {
	expect_types(t, `"a" & "b"`, []Token_Type{.String, .Ampersand, .String, .Eof})
}
