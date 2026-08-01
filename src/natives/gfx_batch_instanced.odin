package natives

import "../core"
import "../vm"
import "core:math"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"

// gfx_batch_instanced: Batch_Instanced_Data -- GPU-instanced rendering
// of a single textured cube mesh, for scenes with too many identical
// cubes for individual win.cube()/batch() draw calls to keep up (tens of
// thousands).
//
// The instancing shader (src/shaders/instanced/*) is loaded once, lazily,
// as a process-wide singleton shared by every Batch_Instanced_Data. The
// shader source is embedded directly into the binary via #load and
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

Batch_Instanced_Data :: struct {
	mesh:          rl.Mesh,
	material:      rl.Material,
	max_instances: int,
	entries:       [dynamic]Batch_Instanced_Entry,
	transforms:    [dynamic]rl.Matrix,
}

@(private = "file")
batch_instanced_vtable := core.Userdata_Vtable {
	tag       = "BatchInstanced",
	free      = batch_instanced_data_free,
	to_string = batch_instanced_to_string,
	size      = batch_instanced_data_size,
	invoke    = batch_instanced_invoke,
}

// Unlike every other native type here, this returns a plain,
// unembellished string rather than the "<Type ...>" bracket convention.
@(private = "file")
batch_instanced_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	return "BatchInstancedObject"
}

@(private = "file")
batch_instanced_data_size :: proc(data: rawptr) -> int {
	b := cast(^Batch_Instanced_Data)data
	return size_of(Batch_Instanced_Data) +
		len(b.entries) * size_of(Batch_Instanced_Entry) +
		len(b.transforms) * size_of(rl.Matrix)
}

@(private = "file")
batch_instanced_data_free :: proc(data: rawptr) {
	b := cast(^Batch_Instanced_Data)data
	delete(b.entries)
	delete(b.transforms)
	free(b)
}

// batch_instanced_add has a fixed capacity set at construction
// (max_instances), returning false once full so the caller can raise a
// runtime error -- no silent growth past the pre-sized transforms array.
@(private = "file")
batch_instanced_add :: proc(b: ^Batch_Instanced_Data, x, y, z, axis_x, axis_y, axis_z, angle: f64) -> bool {
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
@(private = "file")
batch_instanced_make_transforms :: proc(b: ^Batch_Instanced_Data) {
	for i in 0 ..< len(b.entries) {
		e := b.entries[i]
		// column-vector convention (v' = M*v) -- see gfx_window.odin's
		// cube_rotated comment. rotation*translation (the reverse) applies
		// translation to the mesh's local-space vertices before rotation,
		// swinging every instance around the world origin instead of its
		// own center.
		b.transforms[i] = e.translation * e.rotation
	}
}

@(private = "file")
batch_instanced_count :: proc(b: ^Batch_Instanced_Data) -> int {
	return len(b.entries)
}

// batch_instanced_draw takes no camera argument even though the
// Lox-facing API is `.draw(camera)`: the MVP raylib uses comes from the
// active BeginMode3D(camera) call the script already made before
// drawing, not from an explicit parameter here. batch_instanced_invoke
// still validates and requires a camera argument, to preserve the
// script-facing call shape.
@(private = "file")
batch_instanced_draw :: proc(b: ^Batch_Instanced_Data) {
	count := len(b.entries)
	if count == 0 {
		return
	}
	rl.DrawMeshInstanced(b.mesh, b.material, raw_data(b.transforms[:count]), i32(count))
}

// gfx_batch_instanced: (texture, cube_size: float, max_instances: int)
// -- a fixed-capacity instanced batch of one textured cube mesh, for
// scenes with too many identical cubes for win.cube()/gfx.batch() to
// keep up.
@(private)
gfx_batch_instanced :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 3 {
		vm.runtime_error(v, "batch_instanced() expects 3 arguments (texture, cube_size, max_instances).")
		return core.NIL_VALUE
	}
	tex_val, size_val, max_val := v.stack[arg_stack_ptr], v.stack[arg_stack_ptr + 1], v.stack[arg_stack_ptr + 2]
	if !is_texture_value(tex_val) {
		vm.runtime_error(v, "batch_instanced() first argument must be a texture.")
		return core.NIL_VALUE
	}
	if !core.is_float(size_val) {
		vm.runtime_error(v, "batch_instanced() second argument must be a float (cube_size).")
		return core.NIL_VALUE
	}
	if !core.is_int(max_val) {
		vm.runtime_error(v, "batch_instanced() third argument must be an int (max_instances).")
		return core.NIL_VALUE
	}
	texture := texture_data_of(tex_val).texture
	cube_size := f32(core.as_float(size_val))
	max_instances := core.as_int(max_val)

	data := new(Batch_Instanced_Data)
	data.mesh = rl.GenMeshCube(cube_size, cube_size, cube_size)
	data.material = rl.LoadMaterialDefault()
	data.material.shader = instanced_shader_get()
	data.material.maps[rl.MaterialMapIndex.ALBEDO].texture = texture
	data.material.maps[rl.MaterialMapIndex.ALBEDO].color = rl.WHITE
	data.material.maps[rl.MaterialMapIndex.ALBEDO].value = 1.0
	data.max_instances = max_instances
	data.entries = make([dynamic]Batch_Instanced_Entry, 0, max_instances)
	data.transforms = make([dynamic]rl.Matrix, max_instances)

	o := core.make_userdata_object(&batch_instanced_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
batch_instanced_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	b := cast(^Batch_Instanced_Data)data
	result: core.Value
	switch name {
	case "add":
		if arg_count != 3 {
			vm.runtime_error(v, "add() expects 3 arguments (position, rotation axis, angle).")
			return false
		}
		pos_val, axis_val, angle_val := vm.peek(v, 2), vm.peek(v, 1), vm.peek(v, 0)
		if !core.is_vec3(pos_val) {
			vm.runtime_error(v, "add() first argument must be a vec3 (position).")
			return false
		}
		if !core.is_vec3(axis_val) {
			vm.runtime_error(v, "add() second argument must be a vec3 (rotation axis).")
			return false
		}
		if !core.is_float(angle_val) {
			vm.runtime_error(v, "add() third argument must be a float (angle).")
			return false
		}
		pos := core.as_vec3(pos_val)
		axis := core.as_vec3(axis_val)
		angle := core.as_float(angle_val)
		if !batch_instanced_add(b, pos.x, pos.y, pos.z, axis.x, axis.y, axis.z, angle) {
			vm.runtime_error(v, "add(): max instances reached, cannot add more.")
			return false
		}
		result = core.NIL_VALUE
	case "make_transforms":
		if arg_count != 0 {
			vm.runtime_error(v, "make_transforms() expects no arguments.")
			return false
		}
		batch_instanced_make_transforms(b)
		result = core.NIL_VALUE
	case "draw":
		if arg_count != 1 {
			vm.runtime_error(v, "draw() expects 1 argument (camera).")
			return false
		}
		camera_val := vm.peek(v, 0)
		if !is_camera_value(camera_val) {
			vm.runtime_error(v, "draw() argument must be a camera.")
			return false
		}
		batch_instanced_draw(b)
		result = core.NIL_VALUE
	case "count":
		if arg_count != 0 {
			vm.runtime_error(v, "count() expects no arguments.")
			return false
		}
		result = core.make_int_value(batch_instanced_count(b), true)
	case:
		vm.runtime_error(v, "Unknown batch_instanced method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
