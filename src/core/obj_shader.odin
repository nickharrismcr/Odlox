package core

import rl "vendor:raylib"

// Shader_Object wraps a raylib GLSL shader program. Two construction
// paths: gfx.shader(vertex_file, fragment_file) loads compiled GLSL from
// disk immediately; gfx.shader() (no arguments) constructs an empty,
// not-yet-loaded shader (rl.Shader{}) for a script to fill in afterward
// via .load_from_memory(vertex_code, fragment_code), for GLSL source
// embedded as Lox string literals rather than read from a file.
Shader_Object :: struct {
	using obj: Obj,
	shader:    rl.Shader,
	freed:     bool, // idempotent-unload guard, same convention as Texture_Object/Render_Texture_Object
}

make_shader_object :: proc(shader: rl.Shader) -> ^Shader_Object {
	o := new(Shader_Object)
	o.obj.type = .Shader
	o.shader = shader
	return o
}

shader_unload :: proc(s: ^Shader_Object) {
	if s.freed {
		return
	}
	s.freed = true
	rl.UnloadShader(s.shader)
}
