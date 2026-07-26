package compiler

import "../core"

// Per-function compilation state, scope/local/upvalue bookkeeping, and
// bytecode emission. One Compiler exists per function currently being
// compiled (including the top-level script), chained to its lexically
// enclosing one via `enclosing` -- exactly the clox-style nested-compiler
// design, just structs instead of a C stack of them.

Function_Type :: enum {
	Function,
	Script,
	Method,
	Initializer,
}

Local :: struct {
	name:           Token,
	lexeme:         string,
	depth:          int, // -1 = declared but not yet initialised
	is_captured:    bool,
	is_const:       bool,
	debug_info_idx: int, // index into current chunk's local_vars, for end_ip patching
}

Upvalue :: struct {
	index:    u8,
	is_local: bool,
}

// Loop tracks one enclosing loop's patch lists. scope_depth is the
// depth the loop's *own* control-variable scope lives at (e.g. a
// `for`'s init-variable) -- break/continue must not pop locals below
// this, only ones declared inside the loop body itself.
Loop :: struct {
	start:       int,
	breaks:      [dynamic]int,
	is_foreach:  bool, // continue forward-jumps to OP_NEXT instead of back-jumping to start
	continues:   [dynamic]int,
	previous:    ^Loop,
	scope_depth: int,
}

Parser_Snapshot :: struct {
	current, previous: Token,
	token_idx:         int,
}

// Try_Finally / Trampoline_Site implement the try/except/finally
// compiler-side design documented in full in glox's own
// docs/exception-handling.md (read that before touching this code) --
// summarized in docs/ARCHITECTURE.md's Exceptions section. In short:
// `finally` is parsed *last*, so a return/break/continue written inside
// the try body can't know yet whether cleanup code needs to run first;
// it defers ("trampolines") into `pending` instead of emitting its
// terminal instruction immediately, and tryExceptStatement resolves
// every pending site once it learns whether a finally exists.
Try_Finally :: struct {
	scope_depth_at_entry: int,
	has_finally:          bool,
	finally_snapshot:     Parser_Snapshot, // token position to replay the finally body from
	pending:              [dynamic]Trampoline_Site,
	previous:             ^Try_Finally,
}

Trampoline_Site :: struct {
	jump_offset:             int,
	remaining:               [dynamic]^Try_Finally, // further outer trys this same jump also crosses
	local_count_at_crossing: int,
	retval_slot:             int, // -1 for break/continue; the anchored __retval slot for return
	finalize:                proc(p: ^Parser), // emits the real terminal instruction once `remaining` is exhausted
}

Class_Compiler :: struct {
	enclosing:      ^Class_Compiler,
	has_superclass: bool,
}

Compiler :: struct {
	enclosing:   ^Compiler,
	function:    ^core.Function_Object,
	type:        Function_Type,
	locals:      [256]Local,
	local_count: int,
	scope_depth: int,
	loop:        ^Loop,
	tries:       ^Try_Finally,
	upvalues:    [256]Upvalue,
	environment: ^core.Environment,
}

// -----------------------------------------------------------------------
// Compiler lifecycle

// init_root_compiler starts compiling the top-level script. Unlike a
// nested function, it gets a *fresh* Environment (the caller's, e.g. a
// new one per file run, or a persistent one across REPL lines) rather
// than inheriting one from an enclosing compiler -- there is no
// enclosing compiler.
init_root_compiler :: proc(p: ^Parser, environment: ^core.Environment) {
	c := new(Compiler)
	c.type = .Script
	c.environment = environment
	c.function = core.make_function_object(p.filename, environment)
	p.current_compiler = c

	add_local(p, synthetic_token(.Identifier, "", 0))
	mark_initialised(p)
}

// init_function_compiler starts compiling a nested function/method/
// initializer, chaining it to the currently-active compiler. Every
// function in one compilation unit shares its Environment (globals are
// per-*script*, not per-function) -- see docs/ARCHITECTURE.md's
// Environment & globals section.
init_function_compiler :: proc(p: ^Parser, type: Function_Type, name: string) {
	c := new(Compiler)
	c.enclosing = p.current_compiler
	c.type = type
	c.environment = c.enclosing.environment
	fn := core.make_function_object(p.filename, c.environment)
	fn.name = core.intern_string(name)
	c.function = fn
	p.current_compiler = c

	// Slot 0 is always reserved for the enclosing-context value: `this`
	// for methods/initializers, otherwise unnamed (functions/lambdas
	// take no implicit receiver, but the slot still exists so argument
	// slots 1.. line up the same way either kind of call fills them).
	slot0_name := "this" if (type == .Method || type == .Initializer) else ""
	add_local(p, synthetic_token(.Identifier, slot0_name, p.previous.line))
	mark_initialised(p)
}

// end_compiler finalizes the current function: emits the implicit
// return, runs the compile-time peephole pass, publishes the global
// name table (top-level chunk only -- see Chunk's doc comment in
// core/chunk.odin), and pops back to the enclosing compiler.
//
// Returns the just-finished Compiler (not just its Function_Object):
// callers that go on to emit Op_Code.Closure (functions.odin's
// emit_closure) need its `upvalues` array too, and that lives on the
// Compiler, not on Function_Object -- only `function.upvalue_count`
// (the *count*, used to size Closure_Object.upvalues at runtime) does.
end_compiler :: proc(p: ^Parser) -> ^Compiler {
	emit_return(p)
	finished := p.current_compiler
	fn := finished.function

	if finished.enclosing == nil {
		fn.chunk.global_count = p.global_count
		for name in p.global_names_by_slot {
			append(&fn.chunk.global_names, name)
		}
		if fn.environment != nil {
			for name in p.global_names_by_slot {
				append(&fn.environment.global_names, name)
			}
		}
	}

	if !p.skip_peephole {
		peephole_optimise(fn.chunk)
	}

	p.current_compiler = finished.enclosing
	return finished
}

// DebugSkipPeephole mirrors glox's core.DebugSkipPeephole (`-n`/
// `--no-peephole`) -- a package-level toggle rather than a CLI flag
// wired up yet (that lands with the rest of main.odin's argument
// parsing in Phase 4). Read only when constructing a Parser (see
// Compile/Compile_Repl), which copies it into that Parser's own
// skip_peephole field -- end_compiler reads *that*, not this global
// directly, so one compile's behavior is a stable snapshot rather than
// shared mutable state another concurrent compile could flip mid-run
// (see parser.odin's skip_peephole field for the race this avoids).
DebugSkipPeephole := false

// -----------------------------------------------------------------------
// Scopes

begin_scope :: proc(p: ^Parser) {
	p.current_compiler.scope_depth += 1
}

// end_scope pops every local declared at a depth deeper than the scope
// being exited, closing it (OP_Close_Upvalue) if a nested closure
// captured it, or just discarding it (OP_Pop) otherwise -- and records
// each one's end_ip for debug info.
end_scope :: proc(p: ^Parser) {
	c := p.current_compiler
	c.scope_depth -= 1
	for c.local_count > 0 && c.locals[c.local_count - 1].depth > c.scope_depth {
		local := &c.locals[c.local_count - 1]
		if local.is_captured {
			emit_op(p, .Close_Upvalue)
		} else {
			emit_op(p, .Pop)
		}
		current_chunk(p).local_vars[local.debug_info_idx].end_ip = len(current_chunk(p).code)
		c.local_count -= 1
	}
}

// -----------------------------------------------------------------------
// Locals

add_local :: proc(p: ^Parser, name: Token) {
	c := p.current_compiler
	if c.local_count == 256 {
		error(p, "Too many local variables in function.")
		return
	}
	lex := lexeme(name)
	slot := c.local_count
	append(&current_chunk(p).local_vars, core.Local_Var_Info{
		name     = lex,
		start_ip = len(current_chunk(p).code),
		end_ip   = -1,
		slot     = slot,
	})
	c.locals[slot] = Local{
		name           = name,
		lexeme         = lex,
		depth          = -1,
		debug_info_idx = len(current_chunk(p).local_vars) - 1,
	}
	c.local_count += 1
}

// declare_variable is a no-op at global scope (globals are slot-assigned
// by name via global_slot, not declared into a Compiler's locals array).
declare_variable :: proc(p: ^Parser) {
	c := p.current_compiler
	if c.scope_depth == 0 {
		return
	}
	name := p.previous
	lex := lexeme(name)
	for i := c.local_count - 1; i >= 0; i -= 1 {
		local := c.locals[i]
		if local.depth != -1 && local.depth < c.scope_depth {
			break
		}
		if local.lexeme == lex {
			error(p, "Already a variable with this name in this scope.")
		}
	}
	add_local(p, name)
}

// mark_initialised flips the most-recently-added local from "declared"
// to "usable" by setting its depth to the compiler's current scope
// depth (see add_local's -1 sentinel and resolve_local's self-reference
// check). Every caller only ever calls this right after add_local, so
// local_count is always >= 1 here -- no early-return-on-scope-depth-0
// guard is needed (an earlier version of this had one, on the theory
// that scope_depth == 0 means "we're at global scope, nothing to mark" --
// wrong specifically for init_function_compiler/init_root_compiler's
// reserved slot 0, which is added and must be marked *before*
// begin_scope bumps the depth off zero; that stray guard left `this`
// permanently looking uninitialised to every method body).
mark_initialised :: proc(p: ^Parser) {
	c := p.current_compiler
	c.locals[c.local_count - 1].depth = c.scope_depth
}

mark_local_const :: proc(p: ^Parser) {
	p.current_compiler.locals[p.current_compiler.local_count - 1].is_const = true
}

// resolve_local reports whether name is currently a local in c
// (searching innermost-declared-first, so shadowing works), erroring if
// it's found but not yet initialised (`var x = x` self-reference).
resolve_local :: proc(p: ^Parser, c: ^Compiler, name: Token) -> int {
	lex := lexeme(name)
	for i := c.local_count - 1; i >= 0; i -= 1 {
		if c.locals[i].lexeme == lex {
			if c.locals[i].depth == -1 {
				error(p, "Can't read local variable in its own initializer.")
			}
			return i
		}
	}
	return -1
}

// -----------------------------------------------------------------------
// Upvalues

add_upvalue :: proc(p: ^Parser, c: ^Compiler, index: u8, is_local: bool) -> int {
	count := c.function.upvalue_count
	for i in 0 ..< count {
		uv := c.upvalues[i]
		if uv.index == index && uv.is_local == is_local {
			return i // already captured -- reuse the same upvalue slot
		}
	}
	if count == 256 {
		error(p, "Too many closure variables in function.")
		return 0
	}
	c.upvalues[count] = Upvalue{index = index, is_local = is_local}
	c.function.upvalue_count += 1
	return count
}

// resolve_upvalue is the recursive clox-style climb: is `name` a local
// one scope out? capture it directly. Otherwise, does the enclosing
// function *itself* already capture it as an upvalue? capture that
// transitively. This is what lets a doubly-nested closure reach a
// variable declared two functions out.
resolve_upvalue :: proc(p: ^Parser, c: ^Compiler, name: Token) -> int {
	if c.enclosing == nil {
		return -1
	}
	if local := resolve_local(p, c.enclosing, name); local != -1 {
		c.enclosing.locals[local].is_captured = true
		return add_upvalue(p, c, u8(local), true)
	}
	if upvalue := resolve_upvalue(p, c.enclosing, name); upvalue != -1 {
		return add_upvalue(p, c, u8(upvalue), false)
	}
	return -1
}

// -----------------------------------------------------------------------
// Globals: compile-time slot assignment, not a runtime map. See
// docs/ARCHITECTURE.md's Compiler section -- a name gets a slot on
// first *mention* (read or write), so forward references to a
// not-yet-declared global just work.

global_slot :: proc(p: ^Parser, name: string) -> int {
	if slot, ok := p.globals[name]; ok {
		return slot
	}
	slot := p.global_count
	p.globals[name] = slot
	p.global_count += 1
	append(&p.global_names_by_slot, name)
	return slot
}

mark_global_declared :: proc(p: ^Parser, name: string) {
	p.globals_declared[name] = true
}

is_global_declared :: proc(p: ^Parser, name: string) -> bool {
	return p.globals_declared[name] or_else false
}

// resolve_variable is the three-tier dispatcher every name reference
// goes through: local, then upvalue, then (falling back) global.
resolve_variable :: proc(p: ^Parser, name: Token) -> (arg: int, get_op, set_op: core.Op_Code) {
	if local := resolve_local(p, p.current_compiler, name); local != -1 {
		return local, .Get_Local, .Set_Local
	}
	if upvalue := resolve_upvalue(p, p.current_compiler, name); upvalue != -1 {
		return upvalue, .Get_Upvalue, .Set_Upvalue
	}
	return global_slot(p, lexeme(name)), .Get_Global, .Set_Global
}

// -----------------------------------------------------------------------
// Bytecode emission

current_chunk :: proc(p: ^Parser) -> ^core.Chunk {
	return p.current_compiler.function.chunk
}

emit_byte :: proc(p: ^Parser, b: u8) {
	core.chunk_write_byte(current_chunk(p), b, p.previous.line)
}

emit_op :: proc(p: ^Parser, op: core.Op_Code) {
	core.chunk_write_op(current_chunk(p), op, p.previous.line)
}

emit_op_byte :: proc(p: ^Parser, op: core.Op_Code, b: u8) {
	emit_op(p, op)
	emit_byte(p, b)
}

emit_constant :: proc(p: ^Parser, v: core.Value) {
	emit_op_byte(p, .Constant, core.chunk_add_constant(current_chunk(p), v))
}

emit_return :: proc(p: ^Parser) {
	if p.current_compiler.type == .Initializer {
		emit_op_byte(p, .Get_Local, 0) // implicit `return this`
	} else {
		emit_op(p, .Nil)
	}
	emit_op(p, .Return)
}

// emit_jump writes op followed by a 2-byte placeholder offset, returning
// the offset of the placeholder for patch_jump to fill in once the
// jump's target is known.
emit_jump :: proc(p: ^Parser, op: core.Op_Code) -> int {
	emit_op(p, op)
	emit_byte(p, 0xff)
	emit_byte(p, 0xff)
	return len(current_chunk(p).code) - 2
}

patch_jump :: proc(p: ^Parser, offset: int) {
	jump := len(current_chunk(p).code) - offset - 2
	if jump > 0xffff {
		error(p, "Too much code to jump over.")
	}
	current_chunk(p).code[offset] = u8((jump >> 8) & 0xff)
	current_chunk(p).code[offset + 1] = u8(jump & 0xff)
}

emit_loop :: proc(p: ^Parser, loop_start: int) {
	emit_op(p, .Loop)
	offset := len(current_chunk(p).code) - loop_start + 2
	if offset > 0xffff {
		error(p, "Loop body too large.")
	}
	emit_byte(p, u8((offset >> 8) & 0xff))
	emit_byte(p, u8(offset & 0xff))
}

// -----------------------------------------------------------------------
// Compile-time peephole optimizer
//
// Rewrites two fixed-shape 8-byte instruction sequences in place,
// padding with Noop so already-computed jump offsets elsewhere in the
// chunk stay valid (nothing shifts). This is stage one of a two-stage
// design: the VM (Phase 4) further specializes Add_Nn/Incr_Const_N into
// their _Ii/_Ff type-specific children at runtime, on first execution
// (a minimal inline cache) -- see docs/ARCHITECTURE.md's Chunk section.

@(private = "file")
peephole_optimise :: proc(c: ^core.Chunk) {
	code := c.code
	i := 0
	for i + 7 < len(code) {
		is_get_local := code[i] == u8(core.Op_Code.Get_Local)
		set_matches := code[i + 5] == u8(core.Op_Code.Set_Local) &&
			code[i + 6] == code[i + 1] &&
			code[i + 7] == u8(core.Op_Code.Pop) &&
			code[i + 4] == u8(core.Op_Code.Add_Numeric)

		if is_get_local && set_matches && code[i + 2] == u8(core.Op_Code.Get_Local) {
			fuse(code, i, .Add_Nn, code[i + 1], code[i + 3])
			i += 8
			continue
		}
		if is_get_local && set_matches && code[i + 2] == u8(core.Op_Code.Constant) {
			fuse(code, i, .Incr_Const_N, code[i + 1], code[i + 3])
			i += 8
			continue
		}
		i += 1
	}
}

@(private = "file")
fuse :: proc(code: [dynamic]u8, i: int, op: core.Op_Code, a, b: u8) {
	code[i] = u8(op)
	code[i + 1] = a
	code[i + 2] = b
	for k in i + 3 ..= i + 7 {
		code[k] = u8(core.Op_Code.Noop)
	}
}
