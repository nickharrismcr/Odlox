package compiler

import "../core"

// AST node types built by the parser, annotated in place by the Resolver,
// and walked by the Emitter to produce bytecode. `Function_Type` and
// `Upvalue` are declared in resolve.odin and reused here rather than
// redeclared. Expr/Stmt are unions of *pointer* variants (^Expr_Literal,
// ^Stmt_If, ...), so a node reference is typed plain `Expr`/`Stmt`, never
// `^Expr`/`^Stmt` -- the indirection is already inside the union.

// Node_Base is embedded (`using base: Node_Base`) in every node so error
// reporting has a token to point at, matching what error_at_current/error
// use directly today during parsing.
Node_Base :: struct {
	token: Token,
}

// ---------------------------------------------------------------------
// Expressions

Expr :: union {
	^Expr_Literal,
	^Expr_Str_Call,
	^Expr_Tuple,
	^Expr_Unary,
	^Expr_Binary,
	^Expr_Logical,
	^Expr_Conditional,
	^Expr_Variable,
	^Expr_Assign,
	^Expr_This,
	^Expr_Super,
	^Expr_Call,
	^Expr_Property,
	^Expr_Subscript,
	^Expr_List,
	^Expr_Dict,
	^Expr_Lambda,
}

Literal_Kind :: enum {
	Int,
	Float,
	String,
	Bool,
	Nil,
}

// Expr_Literal's value is constructed at parse time exactly as
// int_literal/float_literal/string_literal do today -- a literal's value
// doesn't depend on resolution or (later) type-checking.
Expr_Literal :: struct {
	using base: Node_Base,
	kind:       Literal_Kind,
	value:      core.Value, // unused when kind == .Nil
}

// Expr_Str_Call is the reserved `str(expr)` form, compiled straight to
// Op_Code.Str today -- kept distinct from an ordinary call since it isn't
// one (no callee expression, no argument-count checking).
Expr_Str_Call :: struct {
	using base: Node_Base,
	inner:      Expr,
}

// A tuple literal `(a, b, ...)`. Plain `(expr)` grouping isn't a node at
// all: the parser returns the inner expression directly and only builds
// Expr_Tuple when a trailing comma follows, matching grouping()'s own
// `count > 1` check today.
Expr_Tuple :: struct {
	using base: Node_Base,
	elements:   []Expr,
}

Expr_Unary :: struct {
	using base: Node_Base,
	op:         Token_Type, // .Minus or .Bang
	operand:    Expr,
}

Expr_Binary :: struct {
	using base: Node_Base,
	op:         Token_Type,
	left:       Expr,
	right:      Expr,
}

// Expr_Logical covers `and`/`or`, kept distinct from Expr_Binary since
// both short-circuit -- Emit has to branch instead of unconditionally
// evaluating the right side, unlike every other binary operator.
Expr_Logical :: struct {
	using base: Node_Base,
	op:         Token_Type, // .And or .Or
	left:       Expr,
	right:      Expr,
}

Expr_Conditional :: struct {
	using base:  Node_Base,
	condition:   Expr,
	then_branch: Expr,
	else_branch: Expr,
}

Var_Ref_Kind :: enum {
	Unresolved, // zero value; the Resolver must overwrite every one of these
	Local,
	Upvalue,
	Global,
}

// Var_Ref holds only *where a variable lives*, not which Op_Code reads or
// writes it -- the Emitter derives Get_Local/Get_Global/etc. from `kind`
// itself. Today's resolve_variable returns (arg, get_op, set_op),
// conflating "where is this" with "which opcode" -- keeping those
// separate is a small cleanup this split enables, and it's also what
// lets a future type-checker consume `kind`/`slot` without caring about
// bytecode at all.
Var_Ref :: struct {
	kind:     Var_Ref_Kind,
	slot:     int,
	is_const: bool,
}

// Local_Exit tells the Emitter which local slots go out of scope at a
// scope-closing point, in declaration order, and whether each was captured
// as an upvalue (Close_Upvalue) or not (plain Pop). Stored on each
// scope-owning node since captured-ness is only known once the whole scope
// is resolved. Function-body scopes don't need this: Op_Return discards
// the whole frame instead.
Local_Exit :: struct {
	slot:        int,
	is_captured: bool,
}

Expr_Variable :: struct {
	using base: Node_Base,
	name:       Token,
	resolved:   Var_Ref, // filled in by the Resolver
}

Expr_Assign :: struct {
	using base:  Node_Base,
	name:        Token,
	resolved:    Var_Ref, // filled in by the Resolver
	is_compound: bool,
	compound_op: Token_Type, // meaningful only if is_compound (+=, -=, *=, /=, %=)
	value:       Expr,
}

Expr_This :: struct {
	using base: Node_Base,
	resolved:   Var_Ref, // filled in by the Resolver
}

// Expr_Super needs two independent resolutions, mirroring super_()'s use
// of push_named for both names today: `this_ref` for the current
// instance (always a local in the enclosing method, but a nested
// function/lambda referencing `super` still climbs through upvalues to
// reach it), and `super_ref` for the synthetic `super` local a class
// declaration with `< Superclass` introduces.
Expr_Super :: struct {
	using base:  Node_Base,
	method_name: Token,
	has_args:    bool, // distinguishes Super_Invoke from plain Get_Super
	args:        []Expr, // meaningful only if has_args
	this_ref:    Var_Ref, // filled in by the Resolver
	super_ref:   Var_Ref, // filled in by the Resolver
}

Expr_Call :: struct {
	using base: Node_Base,
	callee:     Expr,
	args:       []Expr,
}

Property_Kind :: enum {
	Get,
	Set,
	Compound_Set,
	Invoke,
}

// Expr_Property covers all four forms dot() compiles today: plain
// `.name` read, `.name = value` write, `.name <op>= value` compound
// write, and `.name(args)` invoke.
Expr_Property :: struct {
	using base:  Node_Base,
	object:      Expr,
	name:        Token,
	kind:        Property_Kind,
	compound_op: Token_Type, // meaningful only if kind == .Compound_Set
	value:       Expr, // meaningful only if kind == .Set or .Compound_Set
	field_slot:  int, // filled in by the Resolver; >= 0 only when object is Expr_This and name is in the enclosing class's discovered field-slot table (see resolve.odin's discover_field_slots), else -1
	args:        []Expr, // meaningful only if kind == .Invoke
}

// Expr_Subscript covers all four forms subscript()/finish_subscript()
// compile today: index read/write and slice read/write. slice_start/
// slice_end are nil for an open bound (`a[:i]`, `a[i:]`, `a[:]`).
Expr_Subscript :: struct {
	using base:   Node_Base,
	object:       Expr,
	is_slice:     bool,
	index:        Expr, // meaningful only if !is_slice
	slice_start:  Expr, // meaningful only if is_slice
	slice_end:    Expr, // meaningful only if is_slice
	assign_value: Expr, // non-nil for an assignment/slice-assignment form
}

Expr_List :: struct {
	using base: Node_Base,
	elements:   []Expr,
}

Dict_Entry :: struct {
	key:   Expr,
	value: Expr,
}

Expr_Dict :: struct {
	using base: Node_Base,
	entries:    []Dict_Entry,
}

Expr_Lambda :: struct {
	using base: Node_Base,
	decl:       ^Function_Decl,
}

// ---------------------------------------------------------------------
// Functions/params -- shared by declared functions, lambdas, and methods,
// exactly as functions.odin's compile_function/compile_function_body is
// shared by all three today.

Param :: struct {
	name:          Token,
	default:       Expr, // nil if this param has no default
	is_rest:       bool, // `*rest`; must be the last param if set
	declared_slot: int, // filled in by the Resolver
}

Function_Decl :: struct {
	using base: Node_Base,
	name:       Token, // empty/synthetic token for a lambda
	params:     []Param,
	body:       []Stmt,
	fn_type:    Function_Type,
	upvalues:   []Upvalue, // filled in by the Resolver
}

// ---------------------------------------------------------------------
// Statements

Stmt :: union {
	^Stmt_Expression,
	^Stmt_Print,
	^Stmt_Raise,
	^Stmt_Breakpoint,
	^Stmt_Var_Decl,
	^Stmt_Implicit_Assign,
	^Stmt_Destructure,
	^Stmt_Block,
	^Stmt_If,
	^Stmt_While,
	^Stmt_For,
	^Stmt_Foreach,
	^Stmt_Break,
	^Stmt_Continue,
	^Stmt_Return,
	^Stmt_Function_Decl,
	^Stmt_Class_Decl,
	^Stmt_Try,
	^Stmt_Import,
	^Stmt_From_Import,
}

Stmt_Expression :: struct {
	using base: Node_Base,
	expr:       Expr,
}

Stmt_Print :: struct {
	using base: Node_Base,
	expr:       Expr,
}

Stmt_Raise :: struct {
	using base: Node_Base,
	expr:       Expr,
}

Stmt_Breakpoint :: struct {
	using base: Node_Base,
}

// Stmt_Var_Decl unifies var/const declarations, which already share
// finish_declare today.
Stmt_Var_Decl :: struct {
	using base:    Node_Base,
	name:          Token,
	init:          Expr, // nil if no initializer (the parser requires one when is_const)
	is_const:      bool,
	declared_slot: int, // filled in by the Resolver
	is_local:      bool, // filled in by the Resolver; local vs. global determines which opcode family Emit uses
}

// Stmt_Implicit_Assign is a bare `x = expr` at statement level for a name
// not yet known as a local -- also reused verbatim as `for`'s bare
// (non-`var`) init clause (see For_Init below), since both need
// identical "first mention creates a binding" resolution, matching how
// stmt.odin shares implicit_assignment_core between them today.
Stmt_Implicit_Assign :: struct {
	using base:    Node_Base,
	name:          Token,
	value:         Expr,
	resolved:      Var_Ref, // filled in by the Resolver
	declared_slot: int, // meaningful only if declares_new
	declares_new:  bool, // filled in by the Resolver -- true for the "first mention" local/global-declaring branches, false for a plain reassignment. Emit needs this: a new local leaves its value on the stack with no Set/Pop (same as Stmt_Var_Decl), a new global uses Define_Global, but an existing binding of any kind emits Set_*+Pop -- three different shapes that `resolved` alone can't distinguish (an existing local and a newly-declared local both resolve to kind == .Local).
}

Destructure_Target :: struct {
	name:          Token,
	declared_slot: int, // filled in by the Resolver
	is_local:      bool, // filled in by the Resolver
}

Stmt_Destructure :: struct {
	using base: Node_Base,
	targets:    []Destructure_Target,
	value:      Expr, // a tuple expression if more than one target
}

Stmt_Block :: struct {
	using base:   Node_Base,
	stmts:        []Stmt,
	local_exits:  []Local_Exit, // filled in by the Resolver, in declaration order
}

Stmt_If :: struct {
	using base:  Node_Base,
	condition:   Expr,
	then_branch: Stmt,
	else_branch: Stmt, // nil if no else
}

Stmt_While :: struct {
	using base: Node_Base,
	condition:  Expr,
	body:       Stmt,
}

// For_Init reuses Stmt_Var_Decl/Stmt_Implicit_Assign/Stmt_Expression
// verbatim rather than inventing a separate for-init-clause node type,
// matching how stmt.odin already shares parsing across all three forms.
// nil means no init clause (`for (; ...)`).
For_Init :: union {
	^Stmt_Var_Decl,
	^Stmt_Implicit_Assign,
	^Stmt_Expression,
}

Stmt_For :: struct {
	using base:       Node_Base,
	init:             For_Init,
	condition:        Expr, // nil = always true
	increment:        Expr, // nil = none
	body:             Stmt,
	init_local_exits: []Local_Exit, // filled in by the Resolver; the init-variable's own outer scope (body is its own Stmt_Block with its own local_exits)
}

Stmt_Foreach :: struct {
	using base:  Node_Base,
	var_name:    Token,
	var_slot:    int, // filled in by the Resolver; hidden loop-variable local
	iterable:    Expr,
	iter_slot:   int, // filled in by the Resolver; hidden `__iter` local
	body:        Stmt,
	local_exits: []Local_Exit, // filled in by the Resolver; covers var_name and the hidden __iter local, in that order
}

// pop_exits: a break/continue jumps out of every enclosing block up to (not
// including) the target loop's control-variable scope, bypassing each
// block's own local_exits cleanup, so those locals need Pop/Close_Upvalue
// emitted at the jump site. crosses_tries/local_count_at_crossing list
// every Stmt_Try crossed between here and the target, innermost first;
// each needs an Op_End_Try plus, if it has a finally, that re-emitted here.
Stmt_Break :: struct {
	using base:             Node_Base,
	pop_exits:              []Local_Exit, // filled in by the Resolver
	crosses_tries:          []^Stmt_Try, // filled in by the Resolver
	local_count_at_crossing: int, // filled in by the Resolver; meaningful only if crosses_tries is non-empty
}

Stmt_Continue :: struct {
	using base:             Node_Base,
	pop_exits:              []Local_Exit, // filled in by the Resolver
	crosses_tries:          []^Stmt_Try, // filled in by the Resolver
	local_count_at_crossing: int, // filled in by the Resolver; meaningful only if crosses_tries is non-empty
}

Stmt_Return :: struct {
	using base:              Node_Base,
	value:                   Expr, // nil = bare `return`
	crosses_tries:           []^Stmt_Try, // filled in by the Resolver -- every enclosing try, innermost first
	retval_slot:             int, // filled in by the Resolver; meaningful only if crosses_tries is non-empty. Anchors the return value in a synthetic local before crossing so a crossed try's finally re-emission can't steal this slot number.
	local_count_at_crossing: int, // filled in by the Resolver; meaningful only if crosses_tries is non-empty. Includes retval_slot itself.
}

Stmt_Function_Decl :: struct {
	using base:    Node_Base,
	decl:          ^Function_Decl,
	declared_slot: int, // filled in by the Resolver; meaningful only for a local declaration
	is_local:      bool, // filled in by the Resolver
}

Class_Var_Member :: struct {
	name: Token,
	init: Expr,
}

Method :: struct {
	name:      Token,
	is_static: bool,
	decl:      ^Function_Decl,
}

// Class_Member preserves source order (methods and static fields can be
// interleaved), matching class_declaration's own member loop today --
// order matters for compile_test.odin's positional opcode assertions.
Class_Member :: union {
	^Method,
	^Class_Var_Member,
}

Stmt_Class_Decl :: struct {
	using base:        Node_Base,
	name:              Token,
	has_superclass:    bool,
	superclass:        Token, // meaningful only if has_superclass
	superclass_ref:    Var_Ref, // filled in by the Resolver; meaningful only if has_superclass -- the superclass *name's* resolution (may be local/upvalue/global)
	members:           []Class_Member,
	declared_slot:     int, // filled in by the Resolver; meaningful only for a local declaration
	is_local:          bool, // filled in by the Resolver
	super_slot:        int, // filled in by the Resolver; meaningful only if has_superclass -- the synthetic `super` local wrapping the whole member list
	super_is_captured: bool, // filled in by the Resolver; meaningful only if has_superclass
	field_slot_names:  []string, // filled in by the Resolver -- index -> name, this class's own discovered field slots only (see resolve.odin's discover_field_slots); may be empty
}

Except_Clause :: struct {
	type_name:    Token,
	has_binding:  bool,
	binding:      Token, // meaningful only if has_binding
	binding_slot: int, // filled in by the Resolver
	body:         []Stmt,
	local_exits:  []Local_Exit, // filled in by the Resolver; covers the binding (if any) and any locals declared in body
}

// has_finally/finally_body let the Emitter resolve return/break/continue
// crossings directly rather than deferring through a trampoline.
// body_local_exits/finally_local_exits reflect one normal-completion pass
// over each. A crossing return/break/continue re-resolves finally_body per
// crossing site instead, since its locals' slot numbers are
// replay-relative; finally_local_exits remains what the Emitter uses for
// the single normal-completion copy.
Stmt_Try :: struct {
	using base:          Node_Base,
	body:                []Stmt,
	excepts:             []Except_Clause,
	has_finally:         bool,
	finally_body:        []Stmt, // meaningful only if has_finally
	body_local_exits:    []Local_Exit, // filled in by the Resolver
	finally_local_exits: []Local_Exit, // filled in by the Resolver's single main-pass walk; meaningful only for validity-checking finally_body once -- Emit never reads this directly (see finally_ctx)
	finally_ctx:         ^Finally_Resolve_Ctx, // filled in by the Resolver; meaningful only if has_finally. Opaque outside resolve.odin/emit_stmt.odin -- lets Emit re-resolve finally_body's local slots fresh at each emission site (implementation phase 6; see resolve.odin's Finally_Resolve_Ctx doc comment for why).
}

Import_Item :: struct {
	module:        Token,
	has_alias:     bool,
	alias:         Token, // meaningful only if has_alias
	declared_slot: int, // filled in by the Resolver
}

Stmt_Import :: struct {
	using base: Node_Base,
	items:      []Import_Item,
}

From_Import_Name :: struct {
	name:          Token,
	declared_slot: int, // filled in by the Resolver
}

Stmt_From_Import :: struct {
	using base: Node_Base,
	module:     Token,
	wildcard:   bool, // `from mod import *`
	names:      []From_Import_Name, // meaningful only if !wildcard
}
