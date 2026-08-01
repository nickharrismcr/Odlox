package natives

import "../core"
import "../vm"
import "core:fmt"
import "core:mem"
import "core:strings"
import rl "vendor:raylib"

// gfx_image: Image_Data wraps a CPU-side (RAM) raylib image -- the
// source gfx.texture() loads a GPU texture from. The underlying rl.Image
// is freed on collection: Image's own Lox-facing surface (width/height)
// never touches the pixel data again once a Texture has been built from
// it, so freeing it when the Image object itself becomes unreachable
// changes no observable behavior.

Image_Data :: struct {
	width, height: int,
	image:         rl.Image,
}

@(private = "file")
image_vtable := core.Userdata_Vtable {
	tag       = "Image",
	free      = image_data_free,
	to_string = image_to_string,
	size      = image_data_size,
	invoke    = image_invoke,
}

@(private = "file")
image_to_string :: proc(data: rawptr, allocator: mem.Allocator) -> string {
	img := cast(^Image_Data)data
	return fmt.aprintf("<Image %dx%d>", img.width, img.height, allocator = allocator)
}

// Dominated by the CPU-side pixel buffer, same reasoning as Float_Array.
@(private = "file")
image_data_size :: proc(data: rawptr) -> int {
	img := cast(^Image_Data)data
	return size_of(Image_Data) + img.width * img.height * 4
}

@(private = "file")
image_data_free :: proc(data: rawptr) {
	img := cast(^Image_Data)data
	rl.UnloadImage(img.image)
	free(img)
}

// is_image_value/image_data_of: package-private since gfx_texture's
// texture() constructor needs them too.
@(private)
is_image_value :: proc(v: core.Value) -> bool {
	return v.type == .Obj && v.obj_type == .Userdata && core.as_userdata(v).vtable == &image_vtable
}

@(private)
image_data_of :: proc(v: core.Value) -> ^Image_Data {
	return cast(^Image_Data)core.as_userdata(v).data
}

// gfx_image loads an rl.Image from a file into CPU memory. A failed
// load raises a catchable Lox runtime_error rather than crashing the
// process, matching how native failures are surfaced throughout this
// module.
@(private)
gfx_image :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr)
	if argc != 1 {
		vm.runtime_error(v, "image() expects 1 argument (filename).")
		return core.NIL_VALUE
	}
	filename_val := v.stack[arg_stack_ptr]
	if !core.is_string(filename_val) {
		vm.runtime_error(v, "image() argument must be a string.")
		return core.NIL_VALUE
	}
	cfilename := strings.clone_to_cstring(core.string_get(core.as_string(filename_val)))
	defer delete(cfilename)
	img := rl.LoadImage(cfilename)
	if img.data == nil {
		vm.runtime_error(v, "Failed to load image from '%s'.", core.string_get(core.as_string(filename_val)))
		return core.NIL_VALUE
	}
	data := new(Image_Data)
	data.width = int(img.width)
	data.height = int(img.height)
	data.image = img
	o := core.make_userdata_object(&image_vtable, data)
	vm.gc_track(v, &o.obj)
	return core.make_object_value(&o.obj, true)
}

@(private = "file")
image_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
	v := vm.native_vm(vm_ctx)
	img := cast(^Image_Data)data
	result: core.Value
	switch name {
	case "width":
		if arg_count != 0 {
			vm.runtime_error(v, "width() takes no arguments.")
			return false
		}
		result = core.make_int_value(img.width, true)
	case "height":
		if arg_count != 0 {
			vm.runtime_error(v, "height() takes no arguments.")
			return false
		}
		result = core.make_int_value(img.height, true)
	case:
		vm.runtime_error(v, "Undefined Image method '%s'.", name)
		return false
	}
	vm.collapse_call(v, arg_count, result)
	return true
}
