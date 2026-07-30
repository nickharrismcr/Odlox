package core

// Module_Object wraps an Environment (see environment.odin) -- both a
// `import mod` result and every built-in module (`sys`, `gfx`, ...) are
// exactly this shape, just populated differently (compiling `.lox`
// source vs. registering natives programmatically). `environment` is
// stored by reference: two "copies"
// of a module must share one live Environment, not each get their own,
// or writes to a module attribute (`mod.attr = x`) would land in a map
// only one of them can see.
Module_Object :: struct {
	using obj:   Obj,
	name:        string,
	environment: ^Environment,
}

make_module_object :: proc(name: string, environment: ^Environment) -> ^Module_Object {
	o := new(Module_Object)
	o.obj.type = .Module
	o.name = name
	o.environment = environment
	return o
}
