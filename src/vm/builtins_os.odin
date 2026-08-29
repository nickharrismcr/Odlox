package vm

import "../core"
import "core:os"
import "core:strings"

// The os.* module: file open/close/readln/write/read_all plus the
// directory/path-manipulation functions. File_Object's actual
// read/write/close behavior lives in core/obj_file.odin (core owns the
// object, vm owns the native functions that construct/use it -- same
// split as every other object kind).

@(private)
define_os_builtins :: proc(vm: ^VM) {
	define_builtin(vm, "os", "open", open_builtin)
	define_builtin(vm, "os", "close", close_builtin)
	define_builtin(vm, "os", "readln", readln_builtin)
	define_builtin(vm, "os", "write", write_builtin)
	define_builtin(vm, "os", "read_all", read_all_builtin)
	define_builtin(vm, "os", "read_bytes", read_bytes_builtin)
	define_builtin(vm, "os", "listdir", listdir_builtin)
	define_builtin(vm, "os", "isdir", isdir_builtin)
	define_builtin(vm, "os", "isfile", isfile_builtin)
	define_builtin(vm, "os", "exists", exists_builtin)
	define_builtin(vm, "os", "mkdir", mkdir_builtin)
	define_builtin(vm, "os", "rmdir", rmdir_builtin)
	define_builtin(vm, "os", "remove", remove_builtin)
	define_builtin(vm, "os", "getcwd", getcwd_builtin)
	define_builtin(vm, "os", "chdir", chdir_builtin)
	define_builtin(vm, "os", "join", join_builtin)
	define_builtin(vm, "os", "dirname", dirname_builtin)
	define_builtin(vm, "os", "basename", basename_builtin)
	define_builtin(vm, "os", "splitext", splitext_builtin)
}

@(private = "file")
open_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 2 || !core.is_string(vm.stack[arg_stack_ptr]) || !core.is_string(vm.stack[arg_stack_ptr + 1]) {
		runtime_error(vm, "Invalid argument type to open.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	mode := core.string_get(core.as_string(vm.stack[arg_stack_ptr + 1]))

	handle: ^os.File
	err: os.Error
	switch mode {
	case "r":
		handle, err = os.open(path, os.O_RDONLY)
	case "w":
		handle, err = os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	case "a":
		handle, err = os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	case:
		runtime_error(vm, "invalid mode: %s", mode)
		return core.NIL_VALUE
	}
	if err != nil {
		runtime_error(vm, "%v", err)
		return core.NIL_VALUE
	}

	f := core.make_file_object(handle)
	gc_track(vm, &f.obj)
	return core.make_object_value(&f.obj)
}

@(private = "file")
close_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !is_file_value(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to close.")
		return core.NIL_VALUE
	}
	core.file_close(core.as_file(vm.stack[arg_stack_ptr]))
	return core.make_bool_value(true)
}

@(private = "file")
readln_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !is_file_value(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to readln.")
		return core.NIL_VALUE
	}
	f := core.as_file(vm.stack[arg_stack_ptr])
	if f.closed {
		runtime_error(vm, "readln attempted on closed file.")
		return core.NIL_VALUE
	}
	line, ok := core.file_read_line(f)
	if !ok {
		runtime_error_named(vm, "EOFError", "End of file reached")
		return core.NIL_VALUE
	}
	return core.make_string_value(line)
}

@(private = "file")
write_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 2 || !is_file_value(vm.stack[arg_stack_ptr]) || !core.is_string(vm.stack[arg_stack_ptr + 1]) {
		runtime_error(vm, "Invalid argument type to write.")
		return core.NIL_VALUE
	}
	f := core.as_file(vm.stack[arg_stack_ptr])
	if f.closed {
		runtime_error(vm, "write attempted on closed file.")
		return core.NIL_VALUE
	}
	core.file_write(f, core.string_get(core.as_string(vm.stack[arg_stack_ptr + 1])))
	return core.make_bool_value(true)
}

@(private = "file")
read_all_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to read_all.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		runtime_error(vm, "%v", err)
		return core.NIL_VALUE
	}
	defer delete(data)
	// make_tracked_string_value, not plain core.make_string_value: a
	// whole file's contents is exactly the unbounded-external-data shape
	// that should actually be collectible once long, not just skip
	// interning -- see obj_string.odin's STRING_INTERN_MAX_LEN.
	return make_tracked_string_value(vm, string(data))
}

// read_bytes reads a whole file as a List of ints (0-255), one per byte --
// for extracting numeric data from binary files, which read_all's string
// result can't do (no ord()/byte-indexing exists at the script level).
@(private = "file")
read_bytes_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to read_bytes.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		runtime_error(vm, "%v", err)
		return core.NIL_VALUE
	}
	defer delete(data)
	items := make([dynamic]core.Value, len(data))
	for b, i in data {
		items[i] = core.make_int_value(int(b))
	}
	list := core.make_list_object(items)
	gc_track(vm, &list.obj)
	return core.make_object_value(&list.obj)
}

@(private = "file")
listdir_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to listdir, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	entries, err := os.read_directory_by_path(path, -1, context.allocator)
	if err != nil {
		runtime_error(vm, "Failed to read directory '%s': %v", path, err)
		return core.NIL_VALUE
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	items := make([dynamic]core.Value, len(entries))
	for e, i in entries {
		items[i] = core.make_string_value(e.name)
	}
	list := core.make_list_object(items)
	gc_track(vm, &list.obj)
	return core.make_object_value(&list.obj)
}

@(private = "file")
isdir_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to isdir, expected string.")
		return core.NIL_VALUE
	}
	return core.make_bool_value(os.is_directory(core.string_get(core.as_string(vm.stack[arg_stack_ptr]))))
}

@(private = "file")
isfile_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to isfile, expected string.")
		return core.NIL_VALUE
	}
	return core.make_bool_value(os.is_file(core.string_get(core.as_string(vm.stack[arg_stack_ptr]))))
}

@(private = "file")
exists_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to exists, expected string.")
		return core.NIL_VALUE
	}
	return core.make_bool_value(os.exists(core.string_get(core.as_string(vm.stack[arg_stack_ptr]))))
}

@(private = "file")
mkdir_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to mkdir, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	if err := os.make_directory_all(path); err != nil {
		runtime_error(vm, "Failed to create directory '%s': %v", path, err)
		return core.NIL_VALUE
	}
	return core.make_bool_value(true)
}

// rmdir and remove are the same underlying operation, kept as two
// separate registered names rather than collapsed into one since
// script source calls them by these two distinct names.
@(private = "file")
rmdir_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to rmdir, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	if err := os.remove(path); err != nil {
		runtime_error(vm, "Failed to remove directory '%s': %v", path, err)
		return core.NIL_VALUE
	}
	return core.make_bool_value(true)
}

@(private = "file")
remove_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to remove, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	if err := os.remove(path); err != nil {
		runtime_error(vm, "Failed to remove file '%s': %v", path, err)
		return core.NIL_VALUE
	}
	return core.make_bool_value(true)
}

@(private = "file")
getcwd_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 0 {
		runtime_error(vm, "Invalid argument count to getcwd.")
		return core.NIL_VALUE
	}
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		runtime_error(vm, "Failed to get current directory: %v", err)
		return core.NIL_VALUE
	}
	defer delete(cwd)
	return core.make_string_value(cwd)
}

@(private = "file")
chdir_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to chdir, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	if err := os.change_directory(path); err != nil {
		runtime_error(vm, "Failed to change directory to '%s': %v", path, err)
		return core.NIL_VALUE
	}
	return core.make_bool_value(true)
}

// join/dirname/basename/splitext are hand-rolled slash-based string
// manipulation rather than core:path/filepath, since they intentionally
// don't do any OS-specific path cleaning -- just plain slash-splitting.

@(private = "file")
join_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc < 1 {
		runtime_error(vm, "join requires at least one argument.")
		return core.NIL_VALUE
	}
	for i in 0 ..< argc {
		if !core.is_string(vm.stack[arg_stack_ptr + i]) {
			runtime_error(vm, "Invalid argument type to join, expected string.")
			return core.NIL_VALUE
		}
	}
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, core.string_get(core.as_string(vm.stack[arg_stack_ptr])))
	for i in 1 ..< argc {
		part := core.string_get(core.as_string(vm.stack[arg_stack_ptr + i]))
		if s := strings.to_string(b); len(s) > 0 && (s[len(s) - 1] == '/' || s[len(s) - 1] == '\\') {
			// no separator needed -- already ends in one
		} else {
			strings.write_byte(&b, '/')
		}
		strings.write_string(&b, part)
	}
	return core.make_string_value(strings.to_string(b))
}

@(private = "file")
dirname_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to dirname, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	last_slash := last_separator(path)
	if last_slash == -1 {
		return core.make_string_value(".")
	}
	if last_slash == 0 {
		return core.make_string_value("/")
	}
	return core.make_string_value(path[:last_slash])
}

@(private = "file")
basename_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to basename, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	last_slash := last_separator(path)
	if last_slash == -1 {
		return core.make_string_value(path)
	}
	return core.make_string_value(path[last_slash + 1:])
}

@(private = "file")
splitext_builtin :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	vm := native_vm(vm_ptr)
	if argc != 1 || !core.is_string(vm.stack[arg_stack_ptr]) {
		runtime_error(vm, "Invalid argument type to splitext, expected string.")
		return core.NIL_VALUE
	}
	path := core.string_get(core.as_string(vm.stack[arg_stack_ptr]))
	last_dot := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '.' {
			last_dot = i
			break
		}
		if path[i] == '/' || path[i] == '\\' {
			break
		}
	}
	name, ext := path, ""
	if last_dot != -1 {
		name = path[:last_dot]
		ext = path[last_dot:]
	}
	items := make([dynamic]core.Value, 2)
	items[0] = core.make_string_value(name)
	items[1] = core.make_string_value(ext)
	list := core.make_list_object(items)
	gc_track(vm, &list.obj)
	return core.make_object_value(&list.obj)
}

@(private = "file")
last_separator :: proc(path: string) -> int {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return i
		}
	}
	return -1
}

@(private = "file")
is_file_value :: proc(v: core.Value) -> bool {
	return v.type == .Obj && v.obj_type == .File
}
