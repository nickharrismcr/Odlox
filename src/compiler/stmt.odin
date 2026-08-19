package compiler

// Declarations, statements, and control flow. Each function builds and
// returns an AST node. Scope tracking, loop/try context stacks, and any
// validity check needing more than a token comparison are the Resolver's
// job (resolve.odin); self-inheritance is checked here in
// class_declaration since it's pure lexeme comparison. try/except/finally
// carries its whole body/excepts/finally_body up front as one Stmt_Try
// node -- no trampoline mechanism is needed here.

// -----------------------------------------------------------------------
// Top-level dispatch

block :: proc(p: ^Parser) -> []Stmt {
	stmts: [dynamic]Stmt
	for !check(p, .Right_Brace) && !check(p, .Eof) {
		s := declaration(p)
		if s != nil {
			append(&stmts, s)
		}
	}
	consume(p, .Right_Brace, "Expect '}' after block.")
	return stmts[:]
}

declaration :: proc(p: ^Parser) -> Stmt {
	p.stmt_depth += 1
	defer p.stmt_depth -= 1
	if p.stmt_depth > MAX_STMT_DEPTH {
		error(p, "Statement nested too deeply.")
		for p.current.type != .Eof {
			advance(p)
		}
		return nil
	}

	result: Stmt
	#partial switch p.current.type {
	case .Var:
		advance(p)
		result = var_declaration(p)
	case .Const:
		advance(p)
		result = const_declaration(p)
	case .Func:
		advance(p)
		result = function_declaration(p)
	case .Class:
		advance(p)
		result = class_declaration(p)
	case .Import:
		advance(p)
		result = import_statement(p)
	case .From:
		advance(p)
		result = from_import_statement(p)
	case:
		result = statement(p)
	}

	if p.panic_mode {
		synchronize(p)
	}
	return result
}

statement :: proc(p: ^Parser) -> Stmt {
	#partial switch p.current.type {
	case .Print:
		advance(p)
		return print_statement(p)
	case .If:
		advance(p)
		return if_statement(p)
	case .While:
		advance(p)
		return while_statement(p)
	case .For:
		advance(p)
		return for_statement(p)
	case .Foreach:
		advance(p)
		return foreach_statement(p)
	case .Return:
		advance(p)
		return return_statement(p)
	case .Break:
		advance(p)
		return break_statement(p)
	case .Continue:
		advance(p)
		return continue_statement(p)
	case .Try:
		advance(p)
		return try_except_statement(p)
	case .Raise:
		advance(p)
		return raise_statement(p)
	case .Breakpoint:
		tok := p.current
		advance(p)
		consume_eol(p, "Expect newline after 'breakpoint'.")
		return new_clone(Stmt_Breakpoint{base = Node_Base{token = tok}})
	case .Left_Brace:
		tok := p.current
		advance(p)
		stmts := block(p)
		return new_clone(Stmt_Block{base = Node_Base{token = tok}, stmts = stmts})
	case .Semicolon, .Eol:
		advance(p) // empty statement
		return nil
	case .Identifier:
		if check_next(p, .Equal) {
			advance(p)
			return implicit_assignment_statement(p)
		} else if check_next(p, .Comma) && looks_like_destructuring(p) {
			advance(p)
			return destructuring_assignment_statement(p)
		}
		return expression_statement(p)
	case:
		return expression_statement(p)
	}
}

expression_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.current
	e := expression(p)
	consume_eol(p, "Expect newline after expression.")
	return new_clone(Stmt_Expression{base = Node_Base{token = tok}, expr = e})
}

print_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	e := expression(p)
	consume_eol(p, "Expect newline after value.")
	return new_clone(Stmt_Print{base = Node_Base{token = tok}, expr = e})
}

raise_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	e := expression(p)
	consume_eol(p, "Expect newline after 'raise' expression.")
	return new_clone(Stmt_Raise{base = Node_Base{token = tok}, expr = e})
}

// -----------------------------------------------------------------------
// var / const / implicit / destructuring declarations

// parse_var_decl is shared by var_declaration/const_declaration
// (which already share finish_declare today) and for_statement's own
// `var`-led init clause.
@(private = "file")
parse_var_decl :: proc(p: ^Parser, is_const: bool) -> ^Stmt_Var_Decl {
	consume(p, .Identifier, "Expect variable name.")
	name_tok := p.previous
	init: Expr
	if is_const {
		consume(p, .Equal, "Const variable must have an initializer.")
		init = expression(p)
	} else if match(p, .Equal) {
		init = expression(p)
	}
	return new_clone(Stmt_Var_Decl{base = Node_Base{token = name_tok}, name = name_tok, init = init, is_const = is_const})
}

var_declaration :: proc(p: ^Parser) -> Stmt {
	decl := parse_var_decl(p, false)
	consume_eol(p, "Expect newline after variable declaration.")
	return decl
}

const_declaration :: proc(p: ^Parser) -> Stmt {
	decl := parse_var_decl(p, true)
	consume_eol(p, "Expect newline after const declaration.")
	return decl
}

implicit_assignment_statement :: proc(p: ^Parser) -> Stmt {
	s := implicit_assignment_core(p)
	consume_eol(p, "Expect newline after assignment.")
	return s
}

// implicit_assignment_core is implicit_assignment_statement's body
// minus the trailing terminator, shared with for_statement's own bare
// (non-`var`) init clause -- see ast.odin's Stmt_Implicit_Assign doc
// comment. Unlike the original implicit_assignment_core, this does none of
// the local/upvalue/global disambiguation itself -- that's exactly the
// resolution work the Resolver exists to do, once, uniformly, over the
// whole tree, instead of inline during parsing.
@(private = "file")
implicit_assignment_core :: proc(p: ^Parser) -> ^Stmt_Implicit_Assign {
	name_tok := p.previous
	consume(p, .Equal, "Expect '=' in assignment.")
	value := expression(p)
	return new_clone(Stmt_Implicit_Assign{base = Node_Base{token = name_tok}, name = name_tok, value = value})
}

// looks_like_destructuring probes ahead (using snapshot/restore, see
// parser.odin -- unaffected by this refactor, since it's pure token-
// position bookkeeping with no emission involved) for
// `identifier (, identifier)* =` before committing to parsing this
// statement as a destructuring assignment.
@(private = "file")
looks_like_destructuring :: proc(p: ^Parser) -> bool {
	snap := snapshot_pos(p)
	defer restore_pos(p, snap)

	if !check(p, .Identifier) {
		return false
	}
	advance(p)
	for check(p, .Comma) {
		advance(p)
		if !check(p, .Identifier) {
			return false
		}
		advance(p)
	}
	return check(p, .Equal)
}

destructuring_assignment_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous // first identifier, already consumed
	targets: [dynamic]Destructure_Target
	append(&targets, Destructure_Target{name = tok})
	for match(p, .Comma) {
		consume(p, .Identifier, "Expect variable name.")
		append(&targets, Destructure_Target{name = p.previous})
	}
	consume(p, .Equal, "Expect '=' after destructuring targets.")

	// The right-hand side is a comma-separated expression list too -- see
	// destructuring_assignment_statement's own comment. More than one
	// value wraps into a tuple; a single expression is used directly.
	values: [dynamic]Expr
	append(&values, expression(p))
	for match(p, .Comma) {
		append(&values, expression(p))
	}
	if len(values) > 255 {
		error(p, "Too many values on the right-hand side of a destructuring assignment.")
	}
	if len(targets) > 255 {
		error(p, "Too many destructuring targets.")
	}
	consume_eol(p, "Expect newline after destructuring assignment.")

	value: Expr = values[0]
	if len(values) > 1 {
		value = new_clone(Expr_Tuple{base = Node_Base{token = tok}, elements = values[:]})
	}
	return new_clone(Stmt_Destructure{base = Node_Base{token = tok}, targets = targets[:], value = value})
}

// -----------------------------------------------------------------------
// Functions

function_declaration :: proc(p: ^Parser) -> Stmt {
	consume(p, .Identifier, "Expect function name.")
	name_tok := p.previous
	decl := parse_function_decl(p, .Function, name_tok)
	return new_clone(Stmt_Function_Decl{base = Node_Base{token = name_tok}, decl = decl})
}

// -----------------------------------------------------------------------
// Control flow

// parse_condition compiles a control-flow header's condition
// expression, tolerating an optional wrapping `(...)` -- see
// parse_condition's own doc comment.
@(private = "file")
parse_condition :: proc(p: ^Parser) -> Expr {
	has_paren := match(p, .Left_Paren)
	e := expression(p)
	if has_paren {
		consume(p, .Right_Paren, "Expect ')' after condition.")
	}
	return e
}

if_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	condition := parse_condition(p)
	match(p, .Eol) // see if_statement's own doc comment on this Eol hazard
	then_branch := statement(p)

	else_branch: Stmt
	if match(p, .Else) {
		match(p, .Eol)
		else_branch = statement(p)
	}
	return new_clone(Stmt_If{base = Node_Base{token = tok}, condition = condition, then_branch = then_branch, else_branch = else_branch})
}

while_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	condition := parse_condition(p)
	match(p, .Eol)
	body := statement(p)
	return new_clone(Stmt_While{base = Node_Base{token = tok}, condition = condition, body = body})
}

// for_statement compiles the classic C-shaped `for init; cond; incr {
// body }` -- see for_statement's own doc comment on the increment-after-
// body trick, which is purely an Emit-time concern now (nothing here
// needs to know about back-edges/jumps). Unlike if/while/foreach, the
// body is always braced (see for_statement's own comment on why).
for_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	has_paren := match(p, .Left_Paren)

	init: For_Init
	if match(p, .Semicolon) {
		// no initializer
	} else if match(p, .Var) {
		var_decl := parse_var_decl(p, false)
		consume(p, .Semicolon, "Expect ';' after loop initializer.")
		init = var_decl
	} else if check(p, .Identifier) && check_next(p, .Equal) {
		advance(p)
		assign := implicit_assignment_core(p)
		consume(p, .Semicolon, "Expect ';' after loop initializer.")
		init = assign
	} else {
		expr_tok := p.current
		e := expression(p)
		consume(p, .Semicolon, "Expect ';' after loop initializer.")
		init = new_clone(Stmt_Expression{base = Node_Base{token = expr_tok}, expr = e})
	}

	condition: Expr
	if !check(p, .Semicolon) {
		condition = expression(p)
	}
	consume(p, .Semicolon, "Expect ';' after loop condition.")

	has_increment := !check(p, .Right_Paren) if has_paren else !check(p, .Left_Brace)
	increment: Expr
	if has_increment {
		increment = expression(p)
	}

	if has_paren {
		consume(p, .Right_Paren, "Expect ')' after for clauses.")
	}
	match(p, .Eol)
	consume(p, .Left_Brace, "Expect '{' before for body.")
	body_tok := p.previous
	body_stmts := block(p)
	body := new_clone(Stmt_Block{base = Node_Base{token = body_tok}, stmts = body_stmts})

	return new_clone(
		Stmt_For{base = Node_Base{token = tok}, init = init, condition = condition, increment = increment, body = body},
	)
}

// foreach_statement: `foreach [(]  [var]  x in iterable  [)]  body`.
// var_slot/iter_slot (the hidden loop-variable/`__iter` locals the
// original reserves at parse time) are filled in by the Resolver instead.
foreach_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	has_paren := match(p, .Left_Paren)
	match(p, .Var) // `foreach (var x in y)` -- the `var` keyword is optional
	consume(p, .Identifier, "Expect loop variable name.")
	var_name := p.previous

	consume(p, .In, "Expect 'in' after foreach variable.")
	iterable := expression(p)

	if has_paren {
		consume(p, .Right_Paren, "Expect ')' after iterable.")
	}
	match(p, .Eol) // see if_statement's doc comment: same Eol-before-body hazard
	body := statement(p)

	return new_clone(
		Stmt_Foreach{base = Node_Base{token = tok}, var_name = var_name, iterable = iterable, body = body},
	)
}

// -----------------------------------------------------------------------
// break / continue / return
//
// The "outside a loop"/"outside a function"/"value from an initializer"
// checks break_statement/continue_statement/return_statement do inline
// today move to the Resolver -- these only build nodes.

break_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	consume_eol(p, "Expect newline after 'break'.")
	return new_clone(Stmt_Break{base = Node_Base{token = tok}})
}

continue_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	consume_eol(p, "Expect newline after 'continue'.")
	return new_clone(Stmt_Continue{base = Node_Base{token = tok}})
}

return_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	// Right_Brace included alongside Eol/Eof/Semicolon -- see
	// return_statement's own comment on the one-line-block case.
	value: Expr
	if !(check(p, .Eol) || check(p, .Eof) || check(p, .Semicolon) || check(p, .Right_Brace)) {
		value = expression(p)
	}
	consume_eol(p, "Expect newline after return value.")
	return new_clone(Stmt_Return{base = Node_Base{token = tok}, value = value})
}

// -----------------------------------------------------------------------
// try / except / finally
//
// Stmt_Try carries body/excepts/has_finally/finally_body up front as one
// node -- see this file's header comment and ast.odin's Stmt_Try doc
// comment for why that eliminates the original's entire trampoline
// mechanism rather than just relocating it.

try_except_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	match(p, .Eol) // `try\n{` -- same tolerance as every other brace in this construct
	consume(p, .Left_Brace, "Expect '{' after 'try'.")
	body := block(p)

	match(p, .Eol)
	excepts: [dynamic]Except_Clause
	saw_except := false
	for check(p, .Except) {
		saw_except = true
		advance(p)
		consume(p, .Identifier, "Expect exception type name.")
		type_name := p.previous

		has_binding := false
		binding: Token
		if match(p, .As) {
			consume(p, .Identifier, "Expect exception binding name.")
			has_binding = true
			binding = p.previous
		}
		match(p, .Eol)
		consume(p, .Left_Brace, "Expect '{' after except clause.")
		clause_body := block(p)

		append(&excepts, Except_Clause{type_name = type_name, has_binding = has_binding, binding = binding, body = clause_body})
		match(p, .Eol)
	}

	if !saw_except && !check(p, .Finally) {
		error(p, "Expect 'except' or 'finally' after try block.")
	}

	has_finally := match(p, .Finally)
	finally_body: []Stmt
	if has_finally {
		match(p, .Eol) // `finally\n{` -- same tolerance as except's own clause body above
		consume(p, .Left_Brace, "Expect '{' after 'finally'.")
		finally_body = block(p)
	}

	return new_clone(
		Stmt_Try{base = Node_Base{token = tok}, body = body, excepts = excepts[:], has_finally = has_finally, finally_body = finally_body},
	)
}

// -----------------------------------------------------------------------
// Classes

class_declaration :: proc(p: ^Parser) -> Stmt {
	consume(p, .Identifier, "Expect class name.")
	name_tok := p.previous
	class_name := lexeme(name_tok)

	has_superclass := false
	superclass: Token
	if match(p, .Less) {
		consume(p, .Identifier, "Expect superclass name.")
		if lexeme(p.previous) == class_name {
			error(p, "A class can't inherit from itself.")
		}
		has_superclass = true
		superclass = p.previous
	}

	consume(p, .Left_Brace, "Expect '{' before class body.")
	members: [dynamic]Class_Member
	for !check(p, .Right_Brace) && !check(p, .Eof) {
		// See class_declaration's own comment: a bare Eol/Semicolon
		// between members is legitimate and needs skipping here directly,
		// since method has no branch of its own for it.
		if match(p, .Eol) || match(p, .Semicolon) {
			continue
		}
		member := method(p)
		if member != nil {
			append(&members, member)
		}
		// Same synchronize-on-panic need as class_declaration's own loop --
		// a malformed method whose error path leaves panic_mode set
		// without consuming a token would otherwise spin forever here.
		if p.panic_mode {
			synchronize(p)
		}
	}
	consume(p, .Right_Brace, "Expect '}' after class body.")

	return new_clone(
		Stmt_Class_Decl{base = Node_Base{token = name_tok}, name = name_tok, has_superclass = has_superclass, superclass = superclass, members = members[:]},
	)
}

@(private = "file")
method :: proc(p: ^Parser) -> Class_Member {
	is_static := match(p, .Static)

	consume(p, .Identifier, "Expect method or field name.")
	name := p.previous

	if !check(p, .Left_Paren) {
		if !is_static {
			error(p, "Expect '(' after method name.")
			return nil
		}
		init: Expr
		if match(p, .Equal) {
			init = expression(p)
		}
		consume_eol(p, "Expect newline after class variable.")
		return new_clone(Class_Var_Member{name = name, init = init})
	}

	name_str := lexeme(name)
	if is_static && name_str == "__init__" {
		error(p, "'__init__' cannot be static.")
	}
	fn_type := Function_Type.Initializer if name_str == "__init__" else Function_Type.Method

	decl := parse_function_decl(p, fn_type, name)
	return new_clone(Method{name = name, is_static = is_static, decl = decl})
}

// -----------------------------------------------------------------------
// Imports

import_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	items: [dynamic]Import_Item
	for {
		consume(p, .Identifier, "Expect module name.")
		module := p.previous

		has_alias := false
		alias: Token
		if match(p, .As) {
			consume(p, .Identifier, "Expect alias after 'as'.")
			has_alias = true
			alias = p.previous
		}
		append(&items, Import_Item{module = module, has_alias = has_alias, alias = alias})

		if !match(p, .Comma) {
			break
		}
	}
	consume_eol(p, "Expect newline after import.")
	return new_clone(Stmt_Import{base = Node_Base{token = tok}, items = items[:]})
}

from_import_statement :: proc(p: ^Parser) -> Stmt {
	tok := p.previous
	consume(p, .Identifier, "Expect module name.")
	module := p.previous
	consume(p, .Import, "Expect 'import' after module name.")

	if match(p, .Star) {
		// Not consume_eol -- see from_import_statement's own comment on
		// why the scanner's Eol-suppression heuristic means there is
		// structurally no Eol token here to require.
		return new_clone(Stmt_From_Import{base = Node_Base{token = tok}, module = module, wildcard = true})
	}

	names: [dynamic]From_Import_Name
	for {
		consume(p, .Identifier, "Expect imported name.")
		append(&names, From_Import_Name{name = p.previous})
		if !match(p, .Comma) {
			break
		}
	}
	if len(names) > 255 {
		error(p, "Too many imported names.")
	}
	consume_eol(p, "Expect newline after import.")
	return new_clone(Stmt_From_Import{base = Node_Base{token = tok}, module = module, names = names[:]})
}
