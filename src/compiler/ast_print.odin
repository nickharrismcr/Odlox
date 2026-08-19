package compiler

import "../core"
import "core:strings"

// print_ast renders the output of Parse as an indented Lisp-style listing,
// one entry per top-level statement. Used by main.odin's --print-ast.
// Every Stmt/Expr node prints as a bare atom or a parenthesized form; a
// statement owning nested statements prints a header line, each child
// indented one level further, and a closing ")" on its own line.
// print_expr never writes its own leading indent or trailing newline.
print_ast :: proc(stmts: []Stmt, allocator := context.allocator) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	for s in stmts {
		print_stmt(&sb, s, 0)
	}
	return strings.to_string(sb)
}

@(private = "file")
write_indent :: proc(sb: ^strings.Builder, indent: int) {
	for _ in 0 ..< indent {
		strings.write_string(sb, "  ")
	}
}

// compound_op_symbol covers Expr_Assign/Expr_Property's compound_op:
// unlike a binary/unary/logical operator, there's no backing Token to pull
// lexeme() from (Node_Base.token there is the name/receiver, not the
// operator) -- mirrors the switch emit.odin's compound_op_code already
// makes over the same 5 cases.
@(private = "file")
compound_op_symbol :: proc(t: Token_Type) -> string {
	#partial switch t {
	case .Plus_Equal:
		return "+="
	case .Minus_Equal:
		return "-="
	case .Star_Equal:
		return "*="
	case .Slash_Equal:
		return "/="
	case .Percent_Equal:
		return "%="
	}
	return "?="
}

// write_function_decl renders a function's params and body, shared by
// Stmt_Function_Decl, Method (class members), and Expr_Lambda -- exactly
// as functions.odin's parse_function_decl is shared by all three at parse
// time. Writes no leading indent and no trailing newline: a statement-
// level caller (func/method) wraps this with both; Expr_Lambda, embedded
// mid-expression, adds neither -- its own caller's trailing newline closes
// the whole line once the lambda's body has been written.
@(private = "file")
write_function_decl :: proc(sb: ^strings.Builder, tag: string, name: string, decl: ^Function_Decl, indent: int) {
	strings.write_string(sb, "(")
	strings.write_string(sb, tag)
	if name != "" {
		strings.write_string(sb, " ")
		strings.write_string(sb, name)
	}
	strings.write_string(sb, " (")
	for param, i in decl.params {
		if i > 0 {
			strings.write_string(sb, " ")
		}
		if param.is_rest {
			strings.write_string(sb, "*")
		}
		strings.write_string(sb, lexeme(param.name))
		if param.default != nil {
			strings.write_string(sb, "=")
			print_expr(sb, param.default, indent)
		}
	}
	strings.write_string(sb, ")\n")
	for s in decl.body {
		print_stmt(sb, s, indent + 1)
	}
	write_indent(sb, indent)
	strings.write_string(sb, ")")
}

// ---------------------------------------------------------------------
// Statements

print_stmt :: proc(sb: ^strings.Builder, s: Stmt, indent: int) {
	if s == nil {
		return
	}
	switch v in s {
	case ^Stmt_Expression:
		write_indent(sb, indent)
		strings.write_string(sb, "(expr-stmt ")
		print_expr(sb, v.expr, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Print:
		write_indent(sb, indent)
		strings.write_string(sb, "(print ")
		print_expr(sb, v.expr, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Raise:
		write_indent(sb, indent)
		strings.write_string(sb, "(raise ")
		print_expr(sb, v.expr, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Breakpoint:
		write_indent(sb, indent)
		strings.write_string(sb, "(breakpoint)\n")
	case ^Stmt_Var_Decl:
		write_indent(sb, indent)
		strings.write_string(sb, "(const " if v.is_const else "(var ")
		strings.write_string(sb, lexeme(v.name))
		if v.init != nil {
			strings.write_string(sb, " ")
			print_expr(sb, v.init, indent)
		}
		strings.write_string(sb, ")\n")
	case ^Stmt_Implicit_Assign:
		write_indent(sb, indent)
		strings.write_string(sb, "(assign ")
		strings.write_string(sb, lexeme(v.name))
		strings.write_string(sb, " ")
		print_expr(sb, v.value, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Destructure:
		write_indent(sb, indent)
		strings.write_string(sb, "(destructure (")
		for target, i in v.targets {
			if i > 0 {
				strings.write_string(sb, " ")
			}
			strings.write_string(sb, lexeme(target.name))
		}
		strings.write_string(sb, ") ")
		print_expr(sb, v.value, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Block:
		write_indent(sb, indent)
		strings.write_string(sb, "(block\n")
		for child in v.stmts {
			print_stmt(sb, child, indent + 1)
		}
		write_indent(sb, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_If:
		write_indent(sb, indent)
		strings.write_string(sb, "(if ")
		print_expr(sb, v.condition, indent)
		strings.write_string(sb, "\n")
		print_stmt(sb, v.then_branch, indent + 1)
		if v.else_branch != nil {
			write_indent(sb, indent)
			strings.write_string(sb, "else\n")
			print_stmt(sb, v.else_branch, indent + 1)
		}
		write_indent(sb, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_While:
		write_indent(sb, indent)
		strings.write_string(sb, "(while ")
		print_expr(sb, v.condition, indent)
		strings.write_string(sb, "\n")
		print_stmt(sb, v.body, indent + 1)
		write_indent(sb, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_For:
		write_indent(sb, indent)
		strings.write_string(sb, "(for\n")
		if v.init != nil {
			switch init in v.init {
			case ^Stmt_Var_Decl:
				print_stmt(sb, init, indent + 1)
			case ^Stmt_Implicit_Assign:
				print_stmt(sb, init, indent + 1)
			case ^Stmt_Expression:
				print_stmt(sb, init, indent + 1)
			}
		}
		if v.condition != nil {
			write_indent(sb, indent + 1)
			print_expr(sb, v.condition, indent + 1)
			strings.write_string(sb, "\n")
		}
		if v.increment != nil {
			write_indent(sb, indent + 1)
			print_expr(sb, v.increment, indent + 1)
			strings.write_string(sb, "\n")
		}
		print_stmt(sb, v.body, indent + 1)
		write_indent(sb, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Foreach:
		write_indent(sb, indent)
		strings.write_string(sb, "(foreach ")
		strings.write_string(sb, lexeme(v.var_name))
		strings.write_string(sb, " ")
		print_expr(sb, v.iterable, indent)
		strings.write_string(sb, "\n")
		print_stmt(sb, v.body, indent + 1)
		write_indent(sb, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Break:
		write_indent(sb, indent)
		strings.write_string(sb, "(break)\n")
	case ^Stmt_Continue:
		write_indent(sb, indent)
		strings.write_string(sb, "(continue)\n")
	case ^Stmt_Return:
		write_indent(sb, indent)
		strings.write_string(sb, "(return")
		if v.value != nil {
			strings.write_string(sb, " ")
			print_expr(sb, v.value, indent)
		}
		strings.write_string(sb, ")\n")
	case ^Stmt_Function_Decl:
		write_indent(sb, indent)
		write_function_decl(sb, "func", lexeme(v.decl.name), v.decl, indent)
		strings.write_string(sb, "\n")
	case ^Stmt_Class_Decl:
		write_indent(sb, indent)
		strings.write_string(sb, "(class ")
		strings.write_string(sb, lexeme(v.name))
		if v.has_superclass {
			strings.write_string(sb, " < ")
			strings.write_string(sb, lexeme(v.superclass))
		}
		strings.write_string(sb, "\n")
		for member in v.members {
			switch m in member {
			case ^Method:
				tag := "static-method" if m.is_static else "method"
				write_indent(sb, indent + 1)
				write_function_decl(sb, tag, lexeme(m.name), m.decl, indent + 1)
				strings.write_string(sb, "\n")
			case ^Class_Var_Member:
				write_indent(sb, indent + 1)
				strings.write_string(sb, "(static-var ")
				strings.write_string(sb, lexeme(m.name))
				if m.init != nil {
					strings.write_string(sb, " ")
					print_expr(sb, m.init, indent + 1)
				}
				strings.write_string(sb, ")\n")
			}
		}
		write_indent(sb, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Try:
		write_indent(sb, indent)
		strings.write_string(sb, "(try\n")
		for body_stmt in v.body {
			print_stmt(sb, body_stmt, indent + 1)
		}
		for except in v.excepts {
			write_indent(sb, indent)
			strings.write_string(sb, "except ")
			strings.write_string(sb, lexeme(except.type_name))
			if except.has_binding {
				strings.write_string(sb, " as ")
				strings.write_string(sb, lexeme(except.binding))
			}
			strings.write_string(sb, "\n")
			for except_stmt in except.body {
				print_stmt(sb, except_stmt, indent + 1)
			}
		}
		if v.has_finally {
			write_indent(sb, indent)
			strings.write_string(sb, "finally\n")
			for finally_stmt in v.finally_body {
				print_stmt(sb, finally_stmt, indent + 1)
			}
		}
		write_indent(sb, indent)
		strings.write_string(sb, ")\n")
	case ^Stmt_Import:
		write_indent(sb, indent)
		strings.write_string(sb, "(import ")
		for item, i in v.items {
			if i > 0 {
				strings.write_string(sb, ", ")
			}
			strings.write_string(sb, lexeme(item.module))
			if item.has_alias {
				strings.write_string(sb, " as ")
				strings.write_string(sb, lexeme(item.alias))
			}
		}
		strings.write_string(sb, ")\n")
	case ^Stmt_From_Import:
		write_indent(sb, indent)
		strings.write_string(sb, "(from-import ")
		strings.write_string(sb, lexeme(v.module))
		strings.write_string(sb, " ")
		if v.wildcard {
			strings.write_string(sb, "*")
		} else {
			for name, i in v.names {
				if i > 0 {
					strings.write_string(sb, " ")
				}
				strings.write_string(sb, lexeme(name.name))
			}
		}
		strings.write_string(sb, ")\n")
	}
}

// ---------------------------------------------------------------------
// Expressions
//
// Atoms (literals, variable/this references) print bare, with no wrapping
// parens; only compound forms get "(...)". No leading indent/trailing
// newline is written here -- see this file's header comment.

print_expr :: proc(sb: ^strings.Builder, e: Expr, indent: int) {
	if e == nil {
		return
	}
	switch v in e {
	case ^Expr_Literal:
		strings.write_string(sb, core.value_to_string(v.value))
	case ^Expr_Str_Call:
		strings.write_string(sb, "(str ")
		print_expr(sb, v.inner, indent)
		strings.write_string(sb, ")")
	case ^Expr_Tuple:
		strings.write_string(sb, "(tuple")
		for el in v.elements {
			strings.write_string(sb, " ")
			print_expr(sb, el, indent)
		}
		strings.write_string(sb, ")")
	case ^Expr_Unary:
		strings.write_string(sb, "(")
		strings.write_string(sb, lexeme(v.token))
		strings.write_string(sb, " ")
		print_expr(sb, v.operand, indent)
		strings.write_string(sb, ")")
	case ^Expr_Binary:
		strings.write_string(sb, "(")
		strings.write_string(sb, lexeme(v.token))
		strings.write_string(sb, " ")
		print_expr(sb, v.left, indent)
		strings.write_string(sb, " ")
		print_expr(sb, v.right, indent)
		strings.write_string(sb, ")")
	case ^Expr_Logical:
		strings.write_string(sb, "(")
		strings.write_string(sb, lexeme(v.token))
		strings.write_string(sb, " ")
		print_expr(sb, v.left, indent)
		strings.write_string(sb, " ")
		print_expr(sb, v.right, indent)
		strings.write_string(sb, ")")
	case ^Expr_Conditional:
		strings.write_string(sb, "(? ")
		print_expr(sb, v.condition, indent)
		strings.write_string(sb, " ")
		print_expr(sb, v.then_branch, indent)
		strings.write_string(sb, " ")
		print_expr(sb, v.else_branch, indent)
		strings.write_string(sb, ")")
	case ^Expr_Variable:
		strings.write_string(sb, lexeme(v.name))
	case ^Expr_Assign:
		strings.write_string(sb, "(")
		strings.write_string(sb, compound_op_symbol(v.compound_op) if v.is_compound else "=")
		strings.write_string(sb, " ")
		strings.write_string(sb, lexeme(v.name))
		strings.write_string(sb, " ")
		print_expr(sb, v.value, indent)
		strings.write_string(sb, ")")
	case ^Expr_This:
		strings.write_string(sb, "this")
	case ^Expr_Super:
		if v.has_args {
			strings.write_string(sb, "(super-call ")
			strings.write_string(sb, lexeme(v.method_name))
			for a in v.args {
				strings.write_string(sb, " ")
				print_expr(sb, a, indent)
			}
			strings.write_string(sb, ")")
		} else {
			strings.write_string(sb, "(super-get ")
			strings.write_string(sb, lexeme(v.method_name))
			strings.write_string(sb, ")")
		}
	case ^Expr_Call:
		strings.write_string(sb, "(call ")
		print_expr(sb, v.callee, indent)
		for a in v.args {
			strings.write_string(sb, " ")
			print_expr(sb, a, indent)
		}
		strings.write_string(sb, ")")
	case ^Expr_Property:
		switch v.kind {
		case .Get:
			strings.write_string(sb, "(get ")
			print_expr(sb, v.object, indent)
			strings.write_string(sb, " ")
			strings.write_string(sb, lexeme(v.name))
			strings.write_string(sb, ")")
		case .Set:
			strings.write_string(sb, "(set ")
			print_expr(sb, v.object, indent)
			strings.write_string(sb, " ")
			strings.write_string(sb, lexeme(v.name))
			strings.write_string(sb, " ")
			print_expr(sb, v.value, indent)
			strings.write_string(sb, ")")
		case .Compound_Set:
			strings.write_string(sb, "(")
			strings.write_string(sb, compound_op_symbol(v.compound_op))
			strings.write_string(sb, " ")
			print_expr(sb, v.object, indent)
			strings.write_string(sb, " ")
			strings.write_string(sb, lexeme(v.name))
			strings.write_string(sb, " ")
			print_expr(sb, v.value, indent)
			strings.write_string(sb, ")")
		case .Invoke:
			strings.write_string(sb, "(invoke ")
			print_expr(sb, v.object, indent)
			strings.write_string(sb, " ")
			strings.write_string(sb, lexeme(v.name))
			for a in v.args {
				strings.write_string(sb, " ")
				print_expr(sb, a, indent)
			}
			strings.write_string(sb, ")")
		}
	case ^Expr_Subscript:
		if v.is_slice {
			strings.write_string(sb, "(slice-set " if v.assign_value != nil else "(slice ")
			print_expr(sb, v.object, indent)
			strings.write_string(sb, " ")
			print_expr_or_placeholder(sb, v.slice_start, indent)
			strings.write_string(sb, " ")
			print_expr_or_placeholder(sb, v.slice_end, indent)
			if v.assign_value != nil {
				strings.write_string(sb, " ")
				print_expr(sb, v.assign_value, indent)
			}
			strings.write_string(sb, ")")
		} else {
			strings.write_string(sb, "(index-set " if v.assign_value != nil else "(index ")
			print_expr(sb, v.object, indent)
			strings.write_string(sb, " ")
			print_expr(sb, v.index, indent)
			if v.assign_value != nil {
				strings.write_string(sb, " ")
				print_expr(sb, v.assign_value, indent)
			}
			strings.write_string(sb, ")")
		}
	case ^Expr_List:
		strings.write_string(sb, "(list")
		for el in v.elements {
			strings.write_string(sb, " ")
			print_expr(sb, el, indent)
		}
		strings.write_string(sb, ")")
	case ^Expr_Dict:
		strings.write_string(sb, "(dict")
		for entry in v.entries {
			strings.write_string(sb, " (")
			print_expr(sb, entry.key, indent)
			strings.write_string(sb, " ")
			print_expr(sb, entry.value, indent)
			strings.write_string(sb, ")")
		}
		strings.write_string(sb, ")")
	case ^Expr_Lambda:
		write_function_decl(sb, "lambda", "", v.decl, indent)
	}
}

// print_expr_or_placeholder writes "_" for an open slice bound (nil is
// meaningful here -- `a[:i]`/`a[i:]`/`a[:]` -- unlike an absent condition/
// initializer elsewhere, so it can't reuse those sites' "just omit it"
// treatment without being ambiguous with an actual nil-valued expression).
@(private = "file")
print_expr_or_placeholder :: proc(sb: ^strings.Builder, e: Expr, indent: int) {
	if e == nil {
		strings.write_string(sb, "_")
		return
	}
	print_expr(sb, e, indent)
}
