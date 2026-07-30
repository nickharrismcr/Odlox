package core

import "core:math"
import "core:strings"
import rl "vendor:raylib"

// Batch_Instanced_Object: GPU-instanced rendering of a single textured
// cube mesh, for scenes with too many identical cubes for individual
// win.cube()/batch() draw calls to keep up (tens of thousands).
//
// The instancing shader (src/shaders/instanced/*) is loaded once, lazily,
// as a process-wide singleton shared by every Batch_Instanced_Object.
// The shader source is embedded directly into the binary via #load and
// loaded with rl.LoadShaderFromMemory rather than read from a disk path
// at runtime, since it's an internal implementation asset, not something
// a Lox script ever supplies or edits.
@(private = "file")
instanced_vs_src := #load("../shaders/instanced/base_lighting_instanced.vs", string)
@(private = "file")
instanced_fs_src := #load("../shaders/instanced/lighting.fs", string)

@(private = "file")
instanced_shader: rl.Shader
@(private = "file")
instanced_shader_ready: bool

@(private = "file")
instanced_shader_get :: proc() -> rl.Shader {
	if instanced_shader_ready {
		return instanced_shader
	}
	cvs := strings.clone_to_cstring(instanced_vs_src)
	defer delete(cvs)
	cfs := strings.clone_to_cstring(instanced_fs_src)
	defer delete(cfs)
	instanced_shader = rl.LoadShaderFromMemory(cvs, cfs)

	instanced_shader.locs[int(rl.ShaderLocationIndex.MATRIX_MVP)] = rl.GetShaderLocation(instanced_shader, "mvp")
	instanced_shader.locs[int(rl.ShaderLocationIndex.VECTOR_VIEW)] = rl.GetShaderLocation(instanced_shader, "viewPos")
	instanced_shader.locs[int(rl.ShaderLocationIndex.MATRIX_MODEL)] = rl.GetShaderLocationAttrib(instanced_shader, "instanceTransform")

	ambient_loc := rl.GetShaderLocation(instanced_shader, "ambient")
	ambient_values := [4]f32{10.0, 10.0, 10.0, 10.0}
	rl.SetShaderValue(instanced_shader, ambient_loc, &ambient_values, .VEC4)

	instanced_shader_ready = true
	return instanced_shader
}

Batch_Instanced_Entry :: struct {
	translation: rl.Matrix,
	rotation:    rl.Matrix,
}

Batch_Instanced_Object :: struct {
	using obj:     Obj,
	mesh:          rl.Mesh,
	material:      rl.Material,
	max_instances: int,
	entries:       [dynamic]Batch_Instanced_Entry,
	transforms:    [dynamic]rl.Matrix,
}

make_batch_instanced_object :: proc(texture: rl.Texture2D, cube_size: f32, max_instances: int) -> ^Batch_Instanced_Object {
	o := new(Batch_Instanced_Object)
	o.obj.type = .Batch_Instanced
	o.mesh = rl.GenMeshCube(cube_size, cube_size, cube_size)
	o.material = rl.LoadMaterialDefault()
	o.material.shader = instanced_shader_get()
	o.material.maps[rl.MaterialMapIndex.ALBEDO].texture = texture
	o.material.maps[rl.MaterialMapIndex.ALBEDO].color = rl.WHITE
	o.material.maps[rl.MaterialMapIndex.ALBEDO].value = 1.0
	o.max_instances = max_instances
	o.entries = make([dynamic]Batch_Instanced_Entry, 0, max_instances)
	o.transforms = make([dynamic]rl.Matrix, max_instances)
	return o
}

// batch_instanced_add has a fixed capacity set at construction
// (max_instances), returning false once full so the caller can raise a
// runtime error -- no silent growth past the pre-sized transforms array.
batch_instanced_add :: proc(b: ^Batch_Instanced_Object, x, y, z, axis_x, axis_y, axis_z, angle: f64) -> bool {
	if len(b.entries) >= b.max_instances {
		return false
	}
	translation := rl.MatrixTranslate(f32(x), f32(y), f32(z))
	axis := rl.Vector3Normalize(rl.Vector3{f32(axis_x), f32(axis_y), f32(axis_z)})
	rotation := rl.MatrixRotate(axis, f32(angle) * math.RAD_PER_DEG)
	append(&b.entries, Batch_Instanced_Entry{translation = translation, rotation = rotation})
	return true
}

// batch_instanced_make_transforms recomputes the whole transforms array
// from the current entries -- a separate, explicit step from add():
// scripts add every instance, then call make_transforms() once before
// the first draw().
batch_instanced_make_transforms :: proc(b: ^Batch_Instanced_Object) {
	for i in 0 ..< len(b.entries) {
		e := b.entries[i]
		// column-vector convention (v' = M*v) -- see vm/gfx_window.odin's
		// cube_rotated comment. rotation*translation (the reverse) applies
		// translation to the mesh's local-space vertices before rotation,
		// swinging every instance around the world origin instead of its
		// own center.
		b.transforms[i] = e.translation * e.rotation
	}
}

batch_instanced_count :: proc(b: ^Batch_Instanced_Object) -> int {
	return len(b.entries)
}

// batch_instanced_draw takes no camera argument even though the
// Lox-facing API is `.draw(camera)`: the MVP raylib uses comes from the
// active BeginMode3D(camera) call the script already made before
// drawing, not from an explicit parameter here. The dispatch layer
// (vm/gfx_batch_instanced.odin) still validates and requires a camera
// argument, to preserve the script-facing call shape.
batch_instanced_draw :: proc(b: ^Batch_Instanced_Object) {
	count := len(b.entries)
	if count == 0 {
		return
	}
	rl.DrawMeshInstanced(b.mesh, b.material, raw_data(b.transforms[:count]), i32(count))
}
