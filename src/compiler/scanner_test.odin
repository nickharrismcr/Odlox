package compiler

import "core:testing"

@(private = "file")
types_of :: proc(s: ^Scanner) -> [dynamic]Token_Type {
	out: [dynamic]Token_Type
	for t in s.tokens {
		append(&out, t.type)
	}
	return out
}

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

@(test)
test_int_vs_float :: proc(t: ^testing.T) {
	expect_types(t, "1 1.5 100 3.14", []Token_Type{.Int, .Float, .Int, .Float, .Eof})
}

@(test)
test_number_lexeme :: proc(t: ^testing.T) {
	s := tokenize("42 3.5")
	defer destroy_scanner(&s)
	testing.expect_value(t, lexeme(s.tokens[0]), "42")
	testing.expect_value(t, lexeme(s.tokens[1]), "3.5")
}

@(test)
test_keywords_and_identifiers :: proc(t: ^testing.T) {
	expect_types(t, "var func x = foreach class", []Token_Type{
		.Var, .Func, .Identifier, .Equal, .Foreach, .Class, .Eof,
	})
}

@(test)
test_fun_alias_for_func :: proc(t: ^testing.T) {
	s := tokenize("fun")
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.Func)
}

@(test)
test_line_comment_skipped :: proc(t: ^testing.T) {
	expect_types(t, "var x // this is a comment\nvar y", []Token_Type{
		.Var, .Identifier, .Eol, .Var, .Identifier, .Eof,
	})
}

@(test)
test_eol_suppressed_after_operator :: proc(t: ^testing.T) {
	// A newline right after `+` is a continuation, not a statement break.
	expect_types(t, "1 +\n2", []Token_Type{.Int, .Plus, .Int, .Eof})
}

@(test)
test_eol_suppressed_inside_brackets :: proc(t: ^testing.T) {
	expect_types(t, "[\n1,\n2\n]", []Token_Type{
		.Left_Bracket, .Int, .Comma, .Int, .Right_Bracket, .Eof,
	})
}

@(test)
test_eol_kept_between_statements :: proc(t: ^testing.T) {
	expect_types(t, "var x = 1\nvar y = 2", []Token_Type{
		.Var, .Identifier, .Equal, .Int, .Eol,
		.Var, .Identifier, .Equal, .Int, .Eof,
	})
}

@(test)
test_simple_string_no_interpolation :: proc(t: ^testing.T) {
	s := tokenize(`"hello world"`)
	defer destroy_scanner(&s)
	testing.expect_value(t, len(s.tokens), 2) // String, Eof
	testing.expect_value(t, s.tokens[0].type, Token_Type.String)
	testing.expect_value(t, lexeme(s.tokens[0]), `"hello world"`)
}

@(test)
test_single_quoted_string :: proc(t: ^testing.T) {
	s := tokenize(`'hi'`)
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.String)
}

@(test)
test_dollar_dollar_escape :: proc(t: ^testing.T) {
	s := tokenize(`"cost: $$5"`)
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.String)
	testing.expect_value(t, lexeme(s.tokens[0]), `"cost: $5"`)
}

@(test)
test_string_interpolation_desugars_to_call_expression :: proc(t: ^testing.T) {
	// "a${x}b" -> ( "a" & str( x ) & "b" )
	expect_types(t, `"a${x}b"`, []Token_Type{
		.Left_Paren,
		.String, .Ampersand,
		.Identifier, .Left_Paren, .Identifier, .Right_Paren,
		.Ampersand, .String,
		.Right_Paren,
		.Eof,
	})
}

@(test)
test_string_interpolation_drops_empty_literal_parts :: proc(t: ^testing.T) {
	// "${x}" has no literal text on either side of the interpolation.
	expect_types(t, `"${x}"`, []Token_Type{
		.Left_Paren,
		.Identifier, .Left_Paren, .Identifier, .Right_Paren,
		.Right_Paren,
		.Eof,
	})
}

@(test)
test_unterminated_string_is_error_token :: proc(t: ^testing.T) {
	s := tokenize(`"no closing quote`)
	defer destroy_scanner(&s)
	testing.expect_value(t, s.tokens[0].type, Token_Type.Error)
}

@(test)
test_ampersand_is_concat_operator :: proc(t: ^testing.T) {
	expect_types(t, `"a" & "b"`, []Token_Type{.String, .Ampersand, .String, .Eof})
}
