package debug

import "../core"
import "../vm"
import "core:fmt"
import "core:path/filepath"

// frame_dict_value builds a dict describing vm's current call frame --
// function name, source line/file, arguments, locals currently in scope,
// every defined global, and (recursively) the same for every enclosing
// frame under "prev_frame", down to and including the top-level script's
// own frame. Ported from glox's src/debug/inspect.go
// (FrameDictValue/FrameDictValueFromFrame).
frame_dict_value :: proc(v: ^vm.VM) -> core.Value {
	return frame_dict_at(v, v.frame_count - 1)
}

@(private = "file")
frame_dict_at :: proc(v: ^vm.VM, frame_idx: int) -> core.Value {
	if frame_idx < 0 {
		return core.NIL_VALUE
	}
	frame := &v.frames[frame_idx]
	function := frame.closure.function

	d := core.make_dict_object()
	core.dict_set(d, core.intern_string("function"), core.make_object_value(&function.name.obj, true))
	core.dict_set(d, core.intern_string("line"), core.make_int_value(chunk_line_at(function.chunk, frame.ip), true))
	core.dict_set(d, core.intern_string("file"), core.make_string_value(filepath.base(v.script)))
	core.dict_set(d, core.intern_string("args"), args_list(v, frame))
	core.dict_set(d, core.intern_string("locals"), locals_dict(v, frame))
	core.dict_set(d, core.intern_string("globals"), globals_dict(v))
	core.dict_set(d, core.intern_string("prev_frame"), frame_dict_at(v, frame_idx - 1))
	return core.make_object_value(&d.obj)
}

// chunk_line_at clamps ip into range before indexing chunk.lines -- a
// frame caught between instructions (ip at either end of the code) must
// never index out of range just to answer an introspection query.
@(private = "file")
chunk_line_at :: proc(chunk: ^core.Chunk, ip: int) -> int {
	i := ip
	if i < 0 {
		i = 0
	}
	if i >= len(chunk.lines) {
		i = len(chunk.lines) - 1
	}
	if i < 0 {
		return 0
	}
	return chunk.lines[i]
}

// args_list mirrors glox's own ListOfArgs exactly: slots
// [frame.slots .. frame.slots+arity] inclusive -- slot 0 is the
// function/closure value itself (`this`, for a method), slots 1..arity
// the actual arguments, matching this compiler's own calling convention
// (see compiler_state.odin's init_function_compiler, which reserves slot
// 0 the same way).
@(private = "file")
args_list :: proc(v: ^vm.VM, frame: ^vm.Call_Frame) -> core.Value {
	arity := frame.closure.function.arity
	items: [dynamic]core.Value
	for i in 0 ..= arity {
		append(&items, v.stack[frame.slots + i])
	}
	l := core.make_list_object(items)
	return core.make_object_value(&l.obj)
}

// locals_dict finds every local variable currently in scope at frame's
// own ip, by name -- using this compiler's existing per-local debug info
// (Chunk.local_vars, populated by compiler_state.odin's add_local/
// end_scope) rather than re-deriving scope boundaries from arity the way
// glox's own DictOfLocals does; slot numbers there already run from 0
// (the same reserved slot0 args_list above also uses), so a local's
// absolute stack position is simply frame.slots + its recorded slot.
@(private = "file")
locals_dict :: proc(v: ^vm.VM, frame: ^vm.Call_Frame) -> core.Value {
	d := core.make_dict_object()
	chunk := frame.closure.function.chunk
	for info in chunk.local_vars {
		if info.name == "" {
			continue
		}
		if frame.ip < info.start_ip {
			continue
		}
		if info.end_ip != -1 && frame.ip >= info.end_ip {
			continue
		}
		slot := frame.slots + info.slot
		if slot < 0 || slot >= v.stack_top {
			continue
		}
		core.dict_set(d, core.intern_string(info.name), v.stack[slot])
	}
	return core.make_object_value(&d.obj)
}

// globals_dict mirrors glox's own DictOfGlobals: every currently-defined
// global, by name.
@(private = "file")
globals_dict :: proc(v: ^vm.VM) -> core.Value {
	d := core.make_dict_object()
	env := v.environment
	for slot in 0 ..< len(env.global_names) {
		if slot >= len(env.defined) || !env.defined[slot] {
			continue
		}
		core.dict_set(d, core.intern_string(env.global_names[slot]), env.globals[slot])
	}
	return core.make_object_value(&d.obj)
}

// dump_frame prints vm's current frame (name, ip), its live stack
// slots, and every defined global to stdout -- a plain-text debugging
// aid, ported from glox's own DumpFrameBuiltIn/ShowGlobals
// (core_functions.go / debug.go). Format is this port's own rendering,
// not a byte-for-byte match of glox's (nothing depends on that level of
// detail; only the "Frame: <name> (ip=<N>)" line itself is checked by
// the ported test suite).
dump_frame :: proc(v: ^vm.VM) {
	frame := &v.frames[v.frame_count - 1]
	function := frame.closure.function
	name := core.string_get(function.name)
	if name == "" {
		name = "<script>"
	}
	fmt.println("=====================================================")
	fmt.printfln("Frame: %s (ip=%d)", name, frame.ip)
	fmt.println("Stack:")
	for i in 1 ..< v.stack_top {
		fmt.printfln("  [%d] %s", i, core.value_to_string(v.stack[i]))
	}
	fmt.println("Globals:")
	env := v.environment
	for slot in 0 ..< len(env.global_names) {
		if slot >= len(env.defined) || !env.defined[slot] {
			continue
		}
		fmt.printfln("  %s = %s", env.global_names[slot], core.value_to_string(env.globals[slot]))
	}
	fmt.println("=====================================================")
}
