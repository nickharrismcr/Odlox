package compiler

import "core:fmt"

// The Resolver: walks the AST the parser built, annotating nodes in place
// with scope/local/upvalue/global resolution (Var_Ref/declared_slot/
// is_local/local_exits/etc.) and running every validity check that needs
// more than a token comparison. A return/break/continue crossing an
// enclosing try (crosses_tries) is resolved here too, via
// resolve_finally_for_crossing. Hard invariant: this file never touches
// core.Chunk -- it only assigns slot numbers, never bytecode-pool indices.

// -----------------------------------------------------------------------
// Types

Function_Type :: enum {
	Function,
	Script,
	Method,
	Initializer,
}

// Local's `debug_info_idx` is never touched here -- it only means
// something once a real Chunk exists (Emit's job); it's set by
// emit.odin's open_local_debug instead.
Local :: struct {
	name:           Token,
	lexeme:         string,
	depth:          int, // -1 = declared but not yet initialised
	is_captured:    bool,
	is_const:       bool,
	debug_info_idx: int,
}

Upvalue :: struct {
	index:    u8,
	is_local: bool,
}

// field_slots/field_slot_names back the compile-time-baked field-slot
// fast path (core/chunk.odin's Get_Field_Slot/Set_Field_Slot). Populated
// once by discover_field_slots before class members are resolved, so
// every `this.name` reference resolves against the finished table.
// field_slots is name -> index; field_slot_names is the same table in
// index -> name form, copied onto Stmt_Class_Decl for the Emitter.
Class_Compiler :: struct {
	enclosing:        ^Class_Compiler,
	has_superclass:   bool,
	field_slots:      map[string]int,
	field_slot_names: [dynamic]string,
}

// discover_field_slots scans the class's `__init__` method for top-level,
// unconditional, plain-assignment `this.name = value` statements --
// direct elements of __init__'s body, not recursed into any nested block,
// and Property_Kind.Set only (not Compound_Set, which reads before
// writing). A field assigned any other way never enters this table and
// keeps compiling through the ordinary Get_Property/Set_Property path.
// A name that could be a vec2/3/4 swizzle component
// (is_swizzle_field_name) is excluded so swizzle write-back still applies.
@(private = "file")
discover_field_slots :: proc(class_ctx: ^Class_Compiler, members: []Class_Member) {
	init_method: ^Method
	for member in members {
		if m, ok := member.(^Method); ok && m.decl.fn_type == .Initializer {
			init_method = m
			break
		}
	}
	if init_method == nil {
		return
	}
	for stmt in init_method.decl.body {
		discover_field_slots_stmt(class_ctx, stmt)
	}
}

// discover_field_slots_stmt handles one top-level statement of init's
// body: a plain `this.name = value` assignment (the common case), or an
// if/else whose *both* branches unconditionally assign the same field
// name -- e.g. `if (cond) { this.left = X } else { this.left = nil }`,
// exactly benchmarks/lox/binary_trees.lox's own shape (found while
// benchmarking: without this, binary_trees' hottest fields, left/right,
// never qualified at all, since each is only ever assigned inside one
// if/else branch or the other, never as a bare top-level statement --
// trees.lox's own conditional fields, by contrast, are genuinely only
// assigned in the if-with-no-else branch and correctly stay unslotted).
// Only one level of if/else is walked this way (each branch's own
// top-level statements, not recursively into further nesting) --
// deliberately bounded, not a general reachability/CFG analysis;
// anything outside this shape simply isn't discovered, same as any
// other unhandled statement kind, and keeps compiling through the
// ordinary Get_Property/Set_Property path, unchanged and always correct.
@(private = "file")
discover_field_slots_stmt :: proc(class_ctx: ^Class_Compiler, stmt: Stmt) {
	#partial switch s in stmt {
	case ^Stmt_Expression:
		if name, ok := top_level_field_assign_name(s); ok {
			add_discovered_field_slot(class_ctx, name)
		}
	case ^Stmt_If:
		if s.else_branch == nil {
			return
		}
		then_names := field_slot_names_of_branch(s.then_branch)
		defer delete(then_names)
		else_names := field_slot_names_of_branch(s.else_branch)
		defer delete(else_names)
		for name in then_names {
			if _, in_else := else_names[name]; in_else {
				add_discovered_field_slot(class_ctx, name)
			}
		}
	}
}

@(private = "file")
add_discovered_field_slot :: proc(class_ctx: ^Class_Compiler, name: string) {
	if is_swizzle_field_name(name) {
		return
	}
	if _, already := class_ctx.field_slots[name]; already {
		return
	}
	class_ctx.field_slots[name] = len(class_ctx.field_slot_names)
	append(&class_ctx.field_slot_names, name)
}

// top_level_field_assign_name reports the field name a bare
// `this.name = value` expression-statement assigns, if that's what stmt
// actually is (a plain .Set, not .Compound_Set -- see
// discover_field_slots_stmt's own doc comment on why a compound
// assignment can never count).
@(private = "file")
top_level_field_assign_name :: proc(stmt: ^Stmt_Expression) -> (name: string, ok: bool) {
	prop, is_prop := stmt.expr.(^Expr_Property)
	if !is_prop || prop.kind != .Set {
		return "", false
	}
	if _, is_this := prop.object.(^Expr_This); !is_this {
		return "", false
	}
	return lexeme(prop.name), true
}

// field_slot_names_of_branch collects the set of `this.name = value`
// plain-assignment field names appearing as direct top-level statements
// of one if/else branch (a block's own .stmts, or the single statement
// itself if the branch isn't braced) -- used only to intersect against
// the other branch in discover_field_slots_stmt, so the caller owns and
// deletes the returned map.
@(private = "file")
field_slot_names_of_branch :: proc(branch: Stmt) -> map[string]bool {
	names: map[string]bool
	if block, ok := branch.(^Stmt_Block); ok {
		for stmt in block.stmts {
			if expr_stmt, is_expr_stmt := stmt.(^Stmt_Expression); is_expr_stmt {
				if name, name_ok := top_level_field_assign_name(expr_stmt); name_ok {
					names[name] = true
				}
			}
		}
	} else if expr_stmt, is_expr_stmt := branch.(^Stmt_Expression); is_expr_stmt {
		if name, name_ok := top_level_field_assign_name(expr_stmt); name_ok {
			names[name] = true
		}
	}
	return names
}

// Resolve_Loop tracks one enclosing loop -- just scope_depth (the depth
// the loop's own control-variable scope lives at, same meaning as
// compiler_state.odin's Loop.scope_depth), since that's all the Resolver
// needs: break/continue validity (loop != nil) and, via locals_above_rs,
// which locals a break/continue jumping out to this depth needs to pop
// itself (see Stmt_Break/Stmt_Continue's own doc comment in ast.odin).
// Bytecode-offset bookkeeping (start/breaks/continues/is_foreach) is
// Emit's own concern, re-derived fresh during emission -- those don't
// exist yet at resolve time.
Resolve_Loop :: struct {
	scope_depth: int,
	previous:    ^Resolve_Loop,
}

// Resolve_Try tracks one enclosing try -- just enough for a return/break/
// continue to determine which trys it crosses (implementation phase 6):
// scope_depth_at_entry (same meaning as Try_Finally.scope_depth_at_entry
// today, used to filter which trys a break/continue crosses vs. one that
// merely wraps the loop from outside) and the AST node itself, so Emit
// can read has_finally/finally_ctx directly. Stays on Resolve_Scope.tries
// throughout body+every except clause+finally resolution, matching how
// long Compiler.tries stays set today -- see resolve_try's own comment.
Resolve_Try :: struct {
	node:                 ^Stmt_Try,
	scope_depth_at_entry: int,
	previous:             ^Resolve_Try,
}

// Finally_Resolve_Ctx captures the ambient context that was active when
// a Stmt_Try's finally_body was first resolved -- everything Emit needs
// to correctly re-resolve it fresh at a later emission site (both the
// two "normal" copies and any crossing site; implementation phase 6):
// enclosing_scope (the try's own function scope, reused -- not climbed
// into -- by resolve_finally_for_crossing, since finally_body is lexically
// part of the same function as the try, not a nested one), outer_tries
// (deliberately *excludes* this try itself -- a return/break/continue
// written directly inside this finally_body must not try to cross this
// same try again, matching how compile_pending_trampolines temporarily
// swaps Compiler.tries to try_ctx.previous during a replay today),
// current_class (for this/super), and entry_scope_depth/entry_local_count
// (the try statement's own starting point, used for the two ordinary
// non-crossing copies).
Finally_Resolve_Ctx :: struct {
	resolver:          ^Resolver,
	enclosing_scope:   ^Resolve_Scope,
	outer_tries:       ^Resolve_Try,
	current_class:     ^Class_Compiler,
	fn_type:           Function_Type,
	entry_scope_depth: int,
	entry_local_count: int,
}

Resolve_Scope :: struct {
	enclosing:     ^Resolve_Scope,
	fn_type:       Function_Type,
	locals:        [256]Local,
	local_count:   int,
	scope_depth:   int,
	loop:          ^Resolve_Loop, // nil outside any loop *in this function scope*
	tries:         ^Resolve_Try, // nil outside any try *in this function scope*
	upvalues:      [256]Upvalue,
	upvalue_count: int,
}

Global_Table :: struct {
	slots:         map[string]int,
	declared:      map[string]bool,
	count:         int,
	names_by_slot: [dynamic]string,
}

Resolver :: struct {
	scope:         ^Resolve_Scope,
	current_class: ^Class_Compiler,
	had_error:     bool,

	globals:              map[string]int,
	globals_declared:     map[string]bool,
	global_count:         int,
	global_names_by_slot: [dynamic]string,
}

@(private = "file")
resolve_error :: proc(rs: ^Resolver, tok: Token, message: string) {
	rs.had_error = true
	if tok.type == .Eof {
		fmt.printfln("[line %d] Error at end: %s", tok.line, message)
	} else if tok.type == .Error {
		fmt.printfln("[line %d] Error: %s", tok.line, message)
	} else {
		fmt.printfln("[line %d] Error at '%s': %s", tok.line, lexeme(tok), message)
	}
}

// -----------------------------------------------------------------------
// Entry point

// Repl_Seed carries a REPL session's slot-assignment bookkeeping into a
// fresh resolve_program call -- implementation phase 7's equivalent of
// Compile_Repl seeding Parser.globals/globals_declared/global_count
// before the old single pass runs, moved here since global resolution
// now happens in the Resolver, not the Parser. The caller (v2_compile.
// odin's Compile_Repl_V2) is responsible for copying these out of its own
// persistent state first, same as today's copy_string_int_map/
// copy_string_bool_map -- resolve_program takes ownership of exactly
// what's passed in.
Repl_Seed :: struct {
	globals:          map[string]int,
	globals_declared: map[string]bool,
	global_count:     int,
}

resolve_program :: proc(stmts: []Stmt, seed: ^Repl_Seed = nil) -> (globals: Global_Table, had_error: bool) {
	rs := new(Resolver)
	if seed != nil {
		rs.globals = seed.globals
		rs.globals_declared = seed.globals_declared
		rs.global_count = seed.global_count
		// Rebuild names_by_slot in slot order from the seeded map -- map
		// iteration order isn't slot order, same reasoning as today's
		// rebuild_names_by_slot.
		names := make([dynamic]string, rs.global_count)
		for name, slot in rs.globals {
			names[slot] = name
		}
		rs.global_names_by_slot = names
	} else {
		rs.globals = make(map[string]int)
		rs.globals_declared = make(map[string]bool)
	}

	root := new(Resolve_Scope)
	root.fn_type = .Script
	rs.scope = root
	add_local_rs(rs, synthetic_token(.Identifier, "", 0))
	mark_initialised_rs(rs)

	resolve_stmt_list(rs, stmts)

	globals = Global_Table {
		slots         = rs.globals,
		declared      = rs.globals_declared,
		count         = rs.global_count,
		names_by_slot = rs.global_names_by_slot,
	}
	had_error = rs.had_error
	return
}

// -----------------------------------------------------------------------
// Scopes

@(private = "file")
begin_scope_rs :: proc(rs: ^Resolver) {
	rs.scope.scope_depth += 1
}

// end_scope_rs pops every local declared at a depth deeper than the scope
// being exited and returns them as Local_Exit entries -- innermost/most-
// recently-declared first, matching end_scope's own iteration order today
// (the correct order for a stack machine to pop them in, since the last-
// declared local is the one on top of the stack).
@(private = "file")
end_scope_rs :: proc(rs: ^Resolver) -> []Local_Exit {
	sc := rs.scope
	sc.scope_depth -= 1
	exits: [dynamic]Local_Exit
	for sc.local_count > 0 && sc.locals[sc.local_count - 1].depth > sc.scope_depth {
		i := sc.local_count - 1
		append(&exits, Local_Exit{slot = i, is_captured = sc.locals[i].is_captured})
		sc.local_count -= 1
	}
	return exits[:]
}

// locals_above_rs is end_scope_rs's read-only counterpart: a snapshot of
// which locals currently sit above target_depth, without actually closing
// the scope (local_count/scope_depth are untouched) -- used for a break/
// continue's own pop_exits, since the scope those locals belong to still
// gets closed normally later by whatever Stmt_Block owns it; the jump
// just needs to pop them itself first, matching pop_locals_above.
@(private = "file")
locals_above_rs :: proc(rs: ^Resolver, target_depth: int) -> []Local_Exit {
	sc := rs.scope
	exits: [dynamic]Local_Exit
	for i := sc.local_count - 1; i >= 0 && sc.locals[i].depth > target_depth; i -= 1 {
		append(&exits, Local_Exit{slot = i, is_captured = sc.locals[i].is_captured})
	}
	return exits[:]
}

@(private = "file")
push_resolve_loop :: proc(rs: ^Resolver) -> ^Resolve_Loop {
	l := new(Resolve_Loop)
	l.previous = rs.scope.loop
	l.scope_depth = rs.scope.scope_depth
	rs.scope.loop = l
	return l
}

@(private = "file")
pop_resolve_loop :: proc(rs: ^Resolver) {
	rs.scope.loop = rs.scope.loop.previous
}

// -----------------------------------------------------------------------
// Locals

@(private = "file")
add_local_rs :: proc(rs: ^Resolver, name: Token) -> int {
	sc := rs.scope
	if sc.local_count == 256 {
		resolve_error(rs, name, "Too many local variables in function.")
		return 0
	}
	slot := sc.local_count
	sc.locals[slot] = Local{name = name, lexeme = lexeme(name), depth = -1}
	sc.local_count += 1
	return slot
}

// declare_variable_rs is a no-op (returns -1) at global scope, same as
// declare_variable -- callers branch on scope_depth themselves to decide
// between this and global_slot_rs, matching finish_declare's own split.
@(private = "file")
declare_variable_rs :: proc(rs: ^Resolver, name: Token) -> int {
	sc := rs.scope
	if sc.scope_depth == 0 {
		return -1
	}
	lex := lexeme(name)
	for i := sc.local_count - 1; i >= 0; i -= 1 {
		local := sc.locals[i]
		if local.depth != -1 && local.depth < sc.scope_depth {
			break
		}
		if local.lexeme == lex {
			resolve_error(rs, name, "Already a variable with this name in this scope.")
		}
	}
	return add_local_rs(rs, name)
}

@(private = "file")
mark_initialised_rs :: proc(rs: ^Resolver) {
	sc := rs.scope
	sc.locals[sc.local_count - 1].depth = sc.scope_depth
}

@(private = "file")
mark_local_const_rs :: proc(rs: ^Resolver) {
	sc := rs.scope
	sc.locals[sc.local_count - 1].is_const = true
}

@(private = "file")
resolve_local_rs :: proc(rs: ^Resolver, sc: ^Resolve_Scope, name: Token) -> int {
	lex := lexeme(name)
	for i := sc.local_count - 1; i >= 0; i -= 1 {
		if sc.locals[i].lexeme == lex {
			if sc.locals[i].depth == -1 {
				resolve_error(rs, name, "Can't read local variable in its own initializer.")
			}
			return i
		}
	}
	return -1
}

// -----------------------------------------------------------------------
// Upvalues

@(private = "file")
add_upvalue_rs :: proc(rs: ^Resolver, sc: ^Resolve_Scope, index: u8, is_local: bool) -> int {
	count := sc.upvalue_count
	for i in 0 ..< count {
		uv := sc.upvalues[i]
		if uv.index == index && uv.is_local == is_local {
			return i // already captured -- reuse the same upvalue slot
		}
	}
	if count == 256 {
		resolve_error(rs, Token{}, "Too many closure variables in function.")
		return 0
	}
	sc.upvalues[count] = Upvalue{index = index, is_local = is_local}
	sc.upvalue_count += 1
	return count
}

// resolve_upvalue_rs is the recursive clox-style climb, same shape as
// resolve_upvalue -- just walking Resolve_Scope.enclosing (built by this
// Resolver's own recursion into nested Function_Decl bodies) instead of a
// live parse-time Compiler.enclosing chain.
@(private = "file")
resolve_upvalue_rs :: proc(rs: ^Resolver, sc: ^Resolve_Scope, name: Token) -> int {
	if sc.enclosing == nil {
		return -1
	}
	if local := resolve_local_rs(rs, sc.enclosing, name); local != -1 {
		sc.enclosing.locals[local].is_captured = true
		return add_upvalue_rs(rs, sc, u8(local), true)
	}
	if upvalue := resolve_upvalue_rs(rs, sc.enclosing, name); upvalue != -1 {
		return add_upvalue_rs(rs, sc, u8(upvalue), false)
	}
	return -1
}

// -----------------------------------------------------------------------
// Globals

@(private = "file")
global_slot_rs :: proc(rs: ^Resolver, name: string) -> int {
	if slot, ok := rs.globals[name]; ok {
		return slot
	}
	slot := rs.global_count
	rs.globals[name] = slot
	rs.global_count += 1
	append(&rs.global_names_by_slot, name)
	return slot
}

@(private = "file")
mark_global_declared_rs :: proc(rs: ^Resolver, name: string) {
	rs.globals_declared[name] = true
}

@(private = "file")
is_global_declared_rs :: proc(rs: ^Resolver, name: string) -> bool {
	return rs.globals_declared[name] or_else false
}

// resolve_variable_rs is the three-tier dispatcher every name reference
// goes through -- local, then upvalue, then (falling back) global, same
// priority as resolve_variable. Returns a Var_Ref (location only) instead
// of resolve_variable's (arg, get_op, set_op) -- see Var_Ref's own doc
// comment in ast.odin for why that's a deliberate split.
@(private = "file")
resolve_variable_rs :: proc(rs: ^Resolver, name: Token) -> Var_Ref {
	if local := resolve_local_rs(rs, rs.scope, name); local != -1 {
		return Var_Ref{kind = .Local, slot = local, is_const = rs.scope.locals[local].is_const}
	}
	if upvalue := resolve_upvalue_rs(rs, rs.scope, name); upvalue != -1 {
		return Var_Ref{kind = .Upvalue, slot = upvalue}
	}
	return Var_Ref{kind = .Global, slot = global_slot_rs(rs, lexeme(name))}
}

// -----------------------------------------------------------------------
// Function lifecycle

@(private = "file")
begin_function_resolve :: proc(rs: ^Resolver, fn_type: Function_Type) {
	sc := new(Resolve_Scope)
	sc.enclosing = rs.scope
	sc.fn_type = fn_type
	rs.scope = sc

	// Slot 0 is always reserved for the enclosing-context value, same as
	// init_function_compiler -- see that proc's own doc comment.
	slot0_name := "this" if (fn_type == .Method || fn_type == .Initializer) else ""
	add_local_rs(rs, synthetic_token(.Identifier, slot0_name, 0))
	mark_initialised_rs(rs)
}

// end_function_resolve pops back to the enclosing scope. No Local_Exit
// list comes out of this -- unlike a Stmt_Block, a function's own top-
// level scope (params + slot 0) is never explicitly popped by end_scope
// either today: Op_Return already discards the whole call frame, so no
// per-local Pop/Close_Upvalue is ever emitted for it.
@(private = "file")
end_function_resolve :: proc(rs: ^Resolver) -> ^Resolve_Scope {
	finished := rs.scope
	rs.scope = finished.enclosing
	return finished
}

resolve_function_decl :: proc(rs: ^Resolver, decl: ^Function_Decl) {
	begin_function_resolve(rs, decl.fn_type)
	// Matches compile_function_body's own begin_scope call, for params +
	// body -- deliberately no matching end_scope_rs; see
	// end_function_resolve's own doc comment on why a function's top-level
	// scope is never explicitly popped either today.
	begin_scope_rs(rs)
	for &param in decl.params {
		declare_variable_rs(rs, param.name)
		mark_initialised_rs(rs)
		param.declared_slot = rs.scope.local_count - 1
		resolve_expr(rs, param.default)
	}
	resolve_stmt_list(rs, decl.body)
	finished := end_function_resolve(rs)
	decl.upvalues = finished.upvalues[:finished.upvalue_count]
}

// -----------------------------------------------------------------------
// Statements

resolve_stmt_list :: proc(rs: ^Resolver, stmts: []Stmt) {
	for s in stmts {
		resolve_stmt(rs, s)
	}
}

resolve_stmt :: proc(rs: ^Resolver, s: Stmt) {
	if s == nil {
		return
	}
	switch v in s {
	case ^Stmt_Expression:
		resolve_expr(rs, v.expr)
	case ^Stmt_Print:
		resolve_expr(rs, v.expr)
	case ^Stmt_Raise:
		resolve_expr(rs, v.expr)
	case ^Stmt_Breakpoint:
	// nothing to resolve
	case ^Stmt_Var_Decl:
		resolve_var_decl(rs, v)
	case ^Stmt_Implicit_Assign:
		resolve_implicit_assign(rs, v)
	case ^Stmt_Destructure:
		resolve_destructure(rs, v)
	case ^Stmt_Block:
		begin_scope_rs(rs)
		resolve_stmt_list(rs, v.stmts)
		v.local_exits = end_scope_rs(rs)
	case ^Stmt_If:
		resolve_expr(rs, v.condition)
		resolve_stmt(rs, v.then_branch)
		resolve_stmt(rs, v.else_branch)
	case ^Stmt_While:
		resolve_expr(rs, v.condition)
		push_resolve_loop(rs)
		resolve_stmt(rs, v.body)
		pop_resolve_loop(rs)
	case ^Stmt_For:
		resolve_for(rs, v)
	case ^Stmt_Foreach:
		resolve_foreach(rs, v)
	case ^Stmt_Break:
		if rs.scope.loop == nil {
			resolve_error(rs, v.token, "Cannot use break outside loop.")
		} else {
			v.pop_exits = locals_above_rs(rs, rs.scope.loop.scope_depth)
			v.crosses_tries = collect_crossed_tries_rs(rs, rs.scope.loop.scope_depth)
			if len(v.crosses_tries) > 0 {
				v.local_count_at_crossing = local_count_at_depth_rs(rs, rs.scope.loop.scope_depth)
			}
		}
	case ^Stmt_Continue:
		if rs.scope.loop == nil {
			resolve_error(rs, v.token, "Cannot use continue outside loop.")
		} else {
			v.pop_exits = locals_above_rs(rs, rs.scope.loop.scope_depth)
			v.crosses_tries = collect_crossed_tries_rs(rs, rs.scope.loop.scope_depth)
			if len(v.crosses_tries) > 0 {
				v.local_count_at_crossing = local_count_at_depth_rs(rs, rs.scope.loop.scope_depth)
			}
		}
	case ^Stmt_Return:
		resolve_return(rs, v)
	case ^Stmt_Function_Decl:
		resolve_function_declaration_stmt(rs, v)
	case ^Stmt_Class_Decl:
		resolve_class_decl(rs, v)
	case ^Stmt_Try:
		resolve_try(rs, v)
	case ^Stmt_Import:
		resolve_import(rs, v)
	case ^Stmt_From_Import:
		resolve_from_import(rs, v)
	}
}

// -----------------------------------------------------------------------
// var / const / implicit / destructuring declarations

// resolve_var_decl resolves the initializer *before* declaring the name,
// matching var_declaration/const_declaration's own order today -- unlike
// clox, odlox does not catch `var x = x` as a self-reference (verified
// directly against Compile() before writing this): the initializer sees
// whatever `x` means in the *enclosing* scope, since the new local isn't
// added until afterward.
@(private = "file")
resolve_var_decl :: proc(rs: ^Resolver, v: ^Stmt_Var_Decl) {
	resolve_expr(rs, v.init)
	v.is_local = rs.scope.scope_depth > 0
	if v.is_local {
		v.declared_slot = declare_variable_rs(rs, v.name)
		mark_initialised_rs(rs)
		if v.is_const {
			mark_local_const_rs(rs)
		}
	} else {
		name := lexeme(v.name)
		v.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
}

// resolve_implicit_assign mirrors implicit_assignment_core's local ->
// upvalue -> already-global -> new-local -> new-global priority exactly,
// including per-branch ordering relative to the RHS: the "new local"
// branch declares (depth -1) *before* resolving the RHS, same as
// implicit_assignment_core's add_local-then-expression-then-mark_
// initialised order -- so a first-mention `x = x` *does* trip "can't read
// local variable in its own initializer" here, unlike `var x = x` above.
// The "new global" branch marks declared before the RHS too, but globals
// have no uninitialised-sentinel state, so that has no compile-time
// consequence -- also matching today's behavior exactly.
@(private = "file")
resolve_implicit_assign :: proc(rs: ^Resolver, v: ^Stmt_Implicit_Assign) {
	sc := rs.scope
	name := lexeme(v.name)
	existing_local := resolve_local_rs(rs, sc, v.name)
	already_global := is_global_declared_rs(rs, name)
	existing_upvalue := -1
	if existing_local == -1 {
		existing_upvalue = resolve_upvalue_rs(rs, sc, v.name)
	}

	if existing_local != -1 {
		if sc.locals[existing_local].is_const {
			resolve_error(rs, v.name, fmt.tprintf("Cannot assign to const '%s'.", name))
		}
		resolve_expr(rs, v.value)
		v.resolved = Var_Ref{kind = .Local, slot = existing_local, is_const = sc.locals[existing_local].is_const}
	} else if existing_upvalue != -1 {
		resolve_expr(rs, v.value)
		v.resolved = Var_Ref{kind = .Upvalue, slot = existing_upvalue}
	} else if already_global {
		slot := global_slot_rs(rs, name)
		resolve_expr(rs, v.value)
		v.resolved = Var_Ref{kind = .Global, slot = slot}
	} else if sc.scope_depth > 0 {
		v.declared_slot = declare_variable_rs(rs, v.name)
		resolve_expr(rs, v.value)
		mark_initialised_rs(rs)
		v.resolved = Var_Ref{kind = .Local, slot = v.declared_slot}
		v.declares_new = true
	} else {
		slot := global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
		resolve_expr(rs, v.value)
		v.declared_slot = slot
		v.resolved = Var_Ref{kind = .Global, slot = slot}
		v.declares_new = true
	}
}

@(private = "file")
resolve_destructure :: proc(rs: ^Resolver, v: ^Stmt_Destructure) {
	resolve_expr(rs, v.value)
	is_local := rs.scope.scope_depth > 0
	for &target in v.targets {
		target.is_local = is_local
		if is_local {
			target.declared_slot = declare_variable_rs(rs, target.name)
			mark_initialised_rs(rs)
		} else {
			n := lexeme(target.name)
			target.declared_slot = global_slot_rs(rs, n)
			mark_global_declared_rs(rs, n)
		}
	}
}

// -----------------------------------------------------------------------
// Functions

@(private = "file")
resolve_function_declaration_stmt :: proc(rs: ^Resolver, v: ^Stmt_Function_Decl) {
	v.is_local = rs.scope.scope_depth > 0
	// Declared (and marked initialised) *before* the body resolves, so the
	// function can call itself by name for recursion -- matching
	// function_declaration's own ordering.
	if v.is_local {
		v.declared_slot = declare_variable_rs(rs, v.decl.name)
		mark_initialised_rs(rs)
	} else {
		name := lexeme(v.decl.name)
		v.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
	resolve_function_decl(rs, v.decl)
}

// -----------------------------------------------------------------------
// Control flow

@(private = "file")
resolve_for :: proc(rs: ^Resolver, v: ^Stmt_For) {
	begin_scope_rs(rs) // owns the init-variable's scope, matching for_statement's own begin_scope

	if v.init != nil {
		switch init in v.init {
		case ^Stmt_Var_Decl:
			resolve_var_decl(rs, init)
		case ^Stmt_Implicit_Assign:
			resolve_implicit_assign(rs, init)
		case ^Stmt_Expression:
			resolve_expr(rs, init.expr)
		}
	}

	resolve_expr(rs, v.condition)
	resolve_expr(rs, v.increment)

	push_resolve_loop(rs)
	resolve_stmt(rs, v.body) // body is always a Stmt_Block (see for_statement_ast), opens/closes its own nested scope
	pop_resolve_loop(rs)

	v.init_local_exits = end_scope_rs(rs)
}

// resolve_foreach uses add_local_rs directly for both the loop variable
// and the hidden __iter local, not declare_variable_rs -- matching
// foreach_statement's own add_local calls, which (like these) skip the
// duplicate-name-in-scope check declare_variable does. Both are always
// locals regardless of enclosing scope depth, same as today (add_local is
// called unconditionally, with no scope_depth branch).
@(private = "file")
resolve_foreach :: proc(rs: ^Resolver, v: ^Stmt_Foreach) {
	begin_scope_rs(rs)
	v.var_slot = add_local_rs(rs, v.var_name)
	mark_initialised_rs(rs)

	resolve_expr(rs, v.iterable)

	v.iter_slot = add_local_rs(rs, synthetic_token(.Identifier, "__iter", v.var_name.line))
	mark_initialised_rs(rs)

	push_resolve_loop(rs)
	resolve_stmt(rs, v.body)
	pop_resolve_loop(rs)

	v.local_exits = end_scope_rs(rs)
}

// -----------------------------------------------------------------------
// return
//
// crosses_tries collects *every* currently-open try unconditionally (see
// collect_tries_rs) -- a return always crosses all the way to the
// function boundary, unlike break/continue's loop-scoped filter.
// retval_slot is anchored *after* the value expression resolves, at
// whatever local_count is current then, matching return_statement's own
// add_local-after-expression order exactly: the value's own emission
// naturally leaves it sitting at that exact stack position (see
// emit_return_stmt), so no store instruction is needed for the anchor
// itself. local_count_at_crossing is read *after* the anchor local is
// added, so it already includes retval_slot -- also matching today's
// Trampoline_Site.local_count_at_crossing.

@(private = "file")
resolve_return :: proc(rs: ^Resolver, v: ^Stmt_Return) {
	if rs.scope.fn_type == .Script {
		resolve_error(rs, v.token, "Can't return from top-level code.")
	}
	if v.value != nil {
		if rs.scope.fn_type == .Initializer {
			resolve_error(rs, v.token, "Can't return a value from an initializer.")
		}
		resolve_expr(rs, v.value)
	}

	v.crosses_tries = collect_tries_rs(rs)
	if len(v.crosses_tries) > 0 {
		v.retval_slot = add_local_rs(rs, synthetic_token(.Identifier, "__retval", v.token.line))
		mark_initialised_rs(rs)
		v.local_count_at_crossing = rs.scope.local_count
	}
}

// -----------------------------------------------------------------------
// try / except / finally
//
// resolve_try pushes a Resolve_Try onto rs.scope.tries *before* resolving
// the body and only pops it back after finally too -- deliberately
// mirroring how long Compiler.tries stays set today (from before
// try_except_statement's own try-body parse through its finally parse,
// only reset to try_ctx.previous right at the very end). This means a
// return/break/continue inside an except clause or even inside this same
// try's own finally_body sees this try in its own crossing chain too,
// same as today -- Finally_Resolve_Ctx.outer_tries (not this rs.scope.
// tries snapshot) is what a *replay* of finally_body uses instead, to
// avoid a return inside finally_body trying to cross its own try again.

@(private = "file")
resolve_try :: proc(rs: ^Resolver, v: ^Stmt_Try) {
	try_ctx := new(Resolve_Try)
	try_ctx.node = v
	try_ctx.scope_depth_at_entry = rs.scope.scope_depth
	try_ctx.previous = rs.scope.tries

	if v.has_finally {
		v.finally_ctx = new(Finally_Resolve_Ctx)
		v.finally_ctx.resolver = rs
		v.finally_ctx.enclosing_scope = rs.scope
		v.finally_ctx.outer_tries = rs.scope.tries // deliberately *before* try_ctx is pushed
		v.finally_ctx.current_class = rs.current_class
		v.finally_ctx.fn_type = rs.scope.fn_type
		v.finally_ctx.entry_scope_depth = rs.scope.scope_depth
		v.finally_ctx.entry_local_count = rs.scope.local_count
	}

	rs.scope.tries = try_ctx

	begin_scope_rs(rs)
	resolve_stmt_list(rs, v.body)
	v.body_local_exits = end_scope_rs(rs)

	for &ex in v.excepts {
		begin_scope_rs(rs)
		if ex.has_binding {
			ex.binding_slot = add_local_rs(rs, ex.binding)
			mark_initialised_rs(rs)
		}
		resolve_stmt_list(rs, ex.body)
		ex.local_exits = end_scope_rs(rs)
	}

	if v.has_finally {
		// This main-pass walk exists for validity-checking finally_body
		// once (undeclared names, duplicate locals, etc.) -- its
		// declared_slot/local_exits output is never read by Emit
		// directly (see Stmt_Try.finally_local_exits's own doc comment);
		// every actual emission re-resolves via resolve_finally_for_crossing.
		begin_scope_rs(rs)
		resolve_stmt_list(rs, v.finally_body)
		v.finally_local_exits = end_scope_rs(rs)
	}

	rs.scope.tries = try_ctx.previous
}

// collect_tries_rs collects every currently-open try in this function
// scope, innermost first -- what a return crosses unconditionally (all
// the way to the function boundary, same as return_statement's own
// unfiltered chain collection today).
@(private = "file")
collect_tries_rs :: proc(rs: ^Resolver) -> []^Stmt_Try {
	chain: [dynamic]^Stmt_Try
	for t := rs.scope.tries; t != nil; t = t.previous {
		append(&chain, t.node)
	}
	return chain[:]
}

// collect_crossed_tries_rs is break/continue's version: only trys entered
// at or after target_scope_depth (i.e. nested *inside* the loop) count as
// crossed -- a try that merely wraps the loop from outside isn't, same
// filter cross_tries applies today.
@(private = "file")
collect_crossed_tries_rs :: proc(rs: ^Resolver, target_scope_depth: int) -> []^Stmt_Try {
	chain: [dynamic]^Stmt_Try
	for t := rs.scope.tries; t != nil && t.scope_depth_at_entry >= target_scope_depth; t = t.previous {
		append(&chain, t.node)
	}
	return chain[:]
}

// local_count_at_depth_rs mirrors local_count_at_depth: how many locals
// remain once everything above boundary_scope_depth is popped -- i.e. the
// local count *as if* pop_locals_above/locals_above_rs had already run,
// which is exactly the baseline a break/continue's own try-crossing
// (after its pop_exits already emitted) needs.
@(private = "file")
local_count_at_depth_rs :: proc(rs: ^Resolver, boundary_scope_depth: int) -> int {
	sc := rs.scope
	n := sc.local_count
	for n > 0 && sc.locals[n - 1].depth > boundary_scope_depth {
		n -= 1
	}
	return n
}

// resolve_finally_for_crossing re-resolves try_node's finally_body fresh,
// seeded with local_count_at_crossing locals already "live" but the
// try's own fixed entry scope depth -- callable more than once against
// the same subtree (implementation phase 6), for the two ordinary
// non-crossing copies (pass finally_ctx.entry_local_count) or any
// crossing site (pass that site's own local_count_at_crossing). Reuses
// the try's own Resolve_Scope (ctx.enclosing_scope) directly rather than
// fabricating a child scope with it as `.enclosing` -- finally_body is
// lexically part of the SAME function as the try, not a nested one, so
// any reference to a local declared outside the try's own immediate
// block (e.g. a `for` loop's own control variable) must resolve as a
// plain Local via that same scope's locals array, not climb out as an
// Upvalue into a scope with no real function/closure backing it. Starts
// tries at outer_tries, not this try itself -- see Finally_Resolve_Ctx's
// own doc comment. Mutable fields on both the shared Resolver and the
// borrowed scope are saved and restored around the replay so nothing
// else that might read them later observes the scratch state.
resolve_finally_for_crossing :: proc(try_node: ^Stmt_Try, local_count_at_crossing: int) -> (exits: []Local_Exit, had_error: bool) {
	ctx := try_node.finally_ctx
	rs := ctx.resolver
	sc := ctx.enclosing_scope

	saved_scope := rs.scope
	saved_class := rs.current_class
	saved_had_error := rs.had_error
	saved_local_count := sc.local_count
	saved_scope_depth := sc.scope_depth
	saved_tries := sc.tries

	rs.scope = sc
	rs.current_class = ctx.current_class
	rs.had_error = false
	sc.local_count = local_count_at_crossing
	sc.scope_depth = ctx.entry_scope_depth
	sc.tries = ctx.outer_tries

	begin_scope_rs(rs)
	resolve_stmt_list(rs, try_node.finally_body)
	exits = end_scope_rs(rs)
	had_error = rs.had_error

	rs.scope = saved_scope
	rs.current_class = saved_class
	rs.had_error = saved_had_error
	sc.local_count = saved_local_count
	sc.scope_depth = saved_scope_depth
	sc.tries = saved_tries
	return
}

// -----------------------------------------------------------------------
// Classes

@(private = "file")
resolve_class_decl :: proc(rs: ^Resolver, v: ^Stmt_Class_Decl) {
	v.is_local = rs.scope.scope_depth > 0
	if v.is_local {
		v.declared_slot = declare_variable_rs(rs, v.name)
		mark_initialised_rs(rs)
	} else {
		name := lexeme(v.name)
		v.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}

	class_ctx := new(Class_Compiler)
	class_ctx.enclosing = rs.current_class
	rs.current_class = class_ctx
	discover_field_slots(class_ctx, v.members)

	// Self-inheritance is already checked at parse time (pure lexeme
	// comparison -- see class_declaration_ast); only the superclass
	// *reference* (which might be a local/upvalue/global depending on
	// where it's declared) needs real resolution here.
	if v.has_superclass {
		v.superclass_ref = resolve_variable_rs(rs, v.superclass)
		begin_scope_rs(rs)
		v.super_slot = add_local_rs(rs, synthetic_token(.Identifier, "super", v.superclass.line))
		mark_initialised_rs(rs)
		class_ctx.has_superclass = true
	}

	for member in v.members {
		switch m in member {
		case ^Method:
			resolve_function_decl(rs, m.decl)
		case ^Class_Var_Member:
			resolve_expr(rs, m.init)
		}
	}

	if v.has_superclass {
		exits := end_scope_rs(rs)
		if len(exits) > 0 {
			v.super_is_captured = exits[0].is_captured
		}
	}

	v.field_slot_names = class_ctx.field_slot_names[:]
	rs.current_class = class_ctx.enclosing
}

// -----------------------------------------------------------------------
// Imports
//
// Always global regardless of enclosing scope depth -- global_slot is
// called unconditionally by import_statement/from_import_statement today,
// with no scope_depth branch, so these match that directly.

@(private = "file")
resolve_import :: proc(rs: ^Resolver, v: ^Stmt_Import) {
	for &item in v.items {
		name := lexeme(item.alias) if item.has_alias else lexeme(item.module)
		item.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
}

@(private = "file")
resolve_from_import :: proc(rs: ^Resolver, v: ^Stmt_From_Import) {
	if v.wildcard {
		return
	}
	for &n in v.names {
		name := lexeme(n.name)
		n.declared_slot = global_slot_rs(rs, name)
		mark_global_declared_rs(rs, name)
	}
}

// -----------------------------------------------------------------------
// Expressions

resolve_expr :: proc(rs: ^Resolver, e: Expr) {
	if e == nil {
		return
	}
	switch v in e {
	case ^Expr_Literal:
	// nothing to resolve
	case ^Expr_Str_Call:
		resolve_expr(rs, v.inner)
	case ^Expr_Tuple:
		for el in v.elements {
			resolve_expr(rs, el)
		}
	case ^Expr_Unary:
		resolve_expr(rs, v.operand)
	case ^Expr_Binary:
		resolve_expr(rs, v.left)
		resolve_expr(rs, v.right)
	case ^Expr_Logical:
		resolve_expr(rs, v.left)
		resolve_expr(rs, v.right)
	case ^Expr_Conditional:
		resolve_expr(rs, v.condition)
		resolve_expr(rs, v.then_branch)
		resolve_expr(rs, v.else_branch)
	case ^Expr_Variable:
		v.resolved = resolve_variable_rs(rs, v.name)
	case ^Expr_Assign:
		resolve_assign(rs, v)
	case ^Expr_This:
		if rs.current_class == nil {
			resolve_error(rs, v.token, "Can't use 'this' outside of a class.")
		} else {
			v.resolved = resolve_variable_rs(rs, synthetic_token(.Identifier, "this", v.token.line))
		}
	case ^Expr_Super:
		resolve_super(rs, v)
	case ^Expr_Call:
		resolve_expr(rs, v.callee)
		for a in v.args {
			resolve_expr(rs, a)
		}
	case ^Expr_Property:
		resolve_expr(rs, v.object)
		resolve_expr(rs, v.value)
		for a in v.args {
			resolve_expr(rs, a)
		}
		// .Invoke deliberately never gets a field_slot, even when the name
		// matches a discovered slot (e.g. a callback stored in `this.cb =
		// fn` in init, later called as `this.cb()`): Get_Field_Slot/
		// Set_Field_Slot only exist for the .Get/.Set/.Compound_Set shapes
		// emit_field_slot_access handles -- see chunk.odin's opcode doc
		// comment. this.field(...) keeps compiling through the ordinary
		// Invoke path unconditionally; its correctness for a slotted field
		// is handled at the vm/call.odin invoke level instead (see
		// core.instance_get_field).
		v.field_slot = -1
		if v.kind != .Invoke {
			if _, is_this := v.object.(^Expr_This); is_this && rs.current_class != nil {
				if slot, found := rs.current_class.field_slots[lexeme(v.name)]; found {
					v.field_slot = slot
				}
			}
		}
	case ^Expr_Subscript:
		resolve_expr(rs, v.object)
		resolve_expr(rs, v.index)
		resolve_expr(rs, v.slice_start)
		resolve_expr(rs, v.slice_end)
		resolve_expr(rs, v.assign_value)
	case ^Expr_List:
		for el in v.elements {
			resolve_expr(rs, el)
		}
	case ^Expr_Dict:
		for entry in v.entries {
			resolve_expr(rs, entry.key)
			resolve_expr(rs, entry.value)
		}
	case ^Expr_Lambda:
		resolve_function_decl(rs, v.decl)
	}
}

// resolve_assign matches named_variable's assignment branch: resolve the
// target *then* the RHS (see resolve_variable_rs's own doc comment --
// order between the two never changes what either resolves to, but this
// keeps the sequencing identical to today for closeness of fit). Only a
// true local's const-ness is checked, matching named_variable's own
// `get_op == .Get_Local` condition exactly -- an upvalue-captured const
// is not caught at compile time today either.
@(private = "file")
resolve_assign :: proc(rs: ^Resolver, v: ^Expr_Assign) {
	v.resolved = resolve_variable_rs(rs, v.name)
	if v.resolved.kind == .Local && v.resolved.is_const {
		resolve_error(rs, v.name, fmt.tprintf("Cannot assign to const '%s'.", lexeme(v.name)))
	}
	resolve_expr(rs, v.value)
}

@(private = "file")
resolve_super :: proc(rs: ^Resolver, v: ^Expr_Super) {
	if rs.current_class == nil {
		resolve_error(rs, v.token, "Can't use 'super' outside of a class.")
	} else if !rs.current_class.has_superclass {
		resolve_error(rs, v.token, "Can't use 'super' in a class with no superclass.")
	}
	v.this_ref = resolve_variable_rs(rs, synthetic_token(.Identifier, "this", v.token.line))
	v.super_ref = resolve_variable_rs(rs, synthetic_token(.Identifier, "super", v.token.line))
	for a in v.args {
		resolve_expr(rs, a)
	}
}
