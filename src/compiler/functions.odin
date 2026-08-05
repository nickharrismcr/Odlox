package compiler

// Shared function-body parsing: parameters (including `*rest` variadic
// and `name = expr` defaults) and the `{ block }` body. Used by declared
// functions (stmt.odin's function_declaration), anonymous lambdas
// (expr.odin's lambda), and class methods (stmt.odin's method) -- all
// three just differ in what happens around the call, not in how the
// function itself parses. arity/min_arity are derivable from `params` at
// Emit time, so unlike a single-pass compiler this doesn't need to track
// them here; scope/local declaration for each parameter is the
// Resolver's job (fills Param.declared_slot later).
parse_function_decl :: proc(p: ^Parser, fn_type: Function_Type, name_tok: Token) -> ^Function_Decl {
	consume(p, .Left_Paren, "Expect '(' after function name.")

	params: [dynamic]Param
	saw_default := false
	if !check(p, .Right_Paren) {
		for {
			if match(p, .Star) {
				consume(p, .Identifier, "Expect rest parameter name.")
				append(&params, Param{name = p.previous, is_rest = true})
				break // *rest must be the last parameter
			}

			consume(p, .Identifier, "Expect parameter name.")
			param_name := p.previous
			default_expr: Expr
			if match(p, .Equal) {
				saw_default = true
				default_expr = expression(p)
			} else if saw_default {
				error(p, "Non-default parameter can't follow a default parameter.")
			}
			append(&params, Param{name = param_name, default = default_expr})

			if !match(p, .Comma) {
				break
			}
		}
	}
	match(p, .Eol) // allow EOL before ')' (e.g. a trailing comma's own line)
	consume(p, .Right_Paren, "Expect ')' after parameters.")

	// A `{` on its own line after the parameter list is valid -- see
	// compile_function_body's own comment on why this Eol survives into
	// the token stream and must be tolerated explicitly here too.
	match(p, .Eol)
	consume(p, .Left_Brace, "Expect '{' before function body.")
	body := block(p)

	return new_clone(Function_Decl{base = Node_Base{token = name_tok}, name = name_tok, params = params[:], body = body, fn_type = fn_type})
}
