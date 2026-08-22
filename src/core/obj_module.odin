package core

// Module_Object wraps an Environment. Both an `import mod` result and
// every built-in module (`sys`, `gfx`, ...) share this shape, just
// populated differently. `environment` is stored by reference so writes to
// a module attribute (`mod.attr = x`) are visible through every reference.
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
