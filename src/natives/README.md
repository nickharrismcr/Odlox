# Adding a native module

`natives` is where every non-core-language capability lives: raylib
(`gfx`, `sound`), the hand-rolled physics sim (`physics`), regex
(`re`), subprocesses (`process`), pickling, colour utilities,
inspection. `define_natives` in [natives.odin](natives.odin) is the
single entry point `main.odin` calls after `vm.define_builtins`; each
module is one `register_X :: proc(v: ^vm.VM)` in its own file, added to
that list.

Two different things get wired in here, and they have different
amounts of ceremony:

- **Plain native functions** (`sound.init()`, `re.compile(...)`,
  `physics.step(...)`) -- a name in a module that runs Odin code and
  returns a `core.Value`. No new heap-object kind involved.
- **Native object kinds** (`Sound`, `PhysicsWorld`, `Texture`, ...) --
  values with their own methods (`sound_obj.play()`), constructed by a
  native function and then dispatched to by `.method(...)` call sites
  at the Lox level.

## Plain native functions

```odin
@(private)
register_widget :: proc(v: ^vm.VM) {
	vm.make_builtin_module(v, "widget")
	vm.define_builtin(v, "widget", "frobnicate", widget_frobnicate)
}

@(private = "file")
widget_frobnicate :: proc(argc: int, arg_stack_ptr: int, vm_ptr: rawptr) -> core.Value {
	v := vm.native_vm(vm_ptr) // the one place the rawptr boundary gets cast back to ^vm.VM
	if argc != 1 {
		vm.runtime_error(v, "frobnicate() expects 1 argument.")
		return core.NIL_VALUE
	}
	arg := v.stack[arg_stack_ptr]
	// ... do the thing, using vm.peek/vm.runtime_error/vm.collapse_call as needed ...
	return core.make_float_value(42)
}
```

`vm_ptr: rawptr` (not `^vm.VM`) is not a style choice -- `core`, which
declares `Builtin_Fn`, sits below `vm` in the package graph
(`core ← compiler ← vm ← natives`) and can't spell `^vm.VM`. See
[obj_native.odin](../core/obj_native.odin)'s doc comment for the full
rationale. `vm.native_vm` is the typed wrapper every native function
starts with instead of writing the cast inline.

Add `register_widget(v)` to `define_natives` in
[natives.odin](natives.odin) and that's the whole module wired in --
nothing outside this one file changes.

## Native object kinds: `Userdata_Object`

If your module needs its own heap-object kind with methods (not just
functions), use `core.Userdata_Object` -- see
[obj_userdata.odin](../core/obj_userdata.odin). This is the only
mechanism new native object kinds should use; **do not** add a new
`core.Object_Type` enum case for it. That older pattern (one enum tag,
with a case in `core/object.odin`'s `object_to_string`, and
`vm/gc.odin`'s `free_object`/`object_size`/`blacken_object`, and
`vm/call.odin`'s `invoke()`) is still how `Process`, `Physics_World`,
`Regex_Pattern`/`Regex_Match`, and the `gfx` cluster
(`Window`/`Image`/`Texture`/`Render_Texture`/`Shader`/`Camera`/`Batch`/
`Batch_Instanced`) work as of this writing, but that's legacy still
being migrated, not the model to copy -- it means touching four files
in two other packages for every new kind, which is exactly the
coupling `Userdata_Object` exists to remove. `Sound`/`Music` in
[sound.odin](sound.odin) is the reference example; the recipe below is
that file with the labels genericized.

### Recipe

1. **A plain data struct**, package-private, holding whatever the
   object needs. No `using obj: Obj` -- this struct is never itself a
   `core.Obj`, it's the payload a `Userdata_Object` points `.data` at.

   ```odin
   Widget_Data :: struct {
       handle: rl.SomeHandle,
       freed:  bool, // if the object has a resource that can double-free
   }
   ```

2. **A package-private vtable**, one `core.Userdata_Vtable` per
   concrete kind (not per instance -- every `Widget` shares this one):

   ```odin
   @(private = "file")
   widget_vtable := core.Userdata_Vtable{
       tag    = "widget", // used for default object_to_string ("<widget>") and error text
       free   = widget_data_free,
       invoke = widget_invoke,
       // mark/to_string/size are optional (nil is fine) -- see below
   }
   ```

3. **`free`** -- tears down the payload's own resources, then frees the
   payload struct itself. Runs both on an explicit `.unload()`-style
   script call *and* from a GC sweep, so make it idempotent the same
   way `sound_data_free`/`sound_unload` are (a `freed` bool guard) if
   the resource can't tolerate a double release:

   ```odin
   @(private = "file")
   widget_data_free :: proc(data: rawptr) {
       w := cast(^Widget_Data)data
       rl.UnloadSomeHandle(w.handle)
       free(w)
   }
   ```

4. **`invoke`** -- the method-dispatch switch, `name`-keyed exactly
   like the old per-type `invoke_builtin_X` procs used to be. Signature
   takes `vm_ctx: rawptr` for the same package-graph reason
   `Builtin_Fn` does -- cast it back with `vm.native_vm`:

   ```odin
   @(private = "file")
   widget_invoke :: proc(vm_ctx: rawptr, data: rawptr, name: string, arg_count: int) -> bool {
       v := vm.native_vm(vm_ctx)
       w := cast(^Widget_Data)data
       result: core.Value
       switch name {
       case "poke":
           if arg_count != 0 {
               vm.runtime_error(v, "poke() takes no arguments.")
               return false
           }
           rl.PokeSomeHandle(w.handle)
           result = core.NIL_VALUE
       case:
           vm.runtime_error(v, "Undefined Widget method '%s'.", name)
           return false
       }
       vm.collapse_call(v, arg_count, result)
       return true
   }
   ```

5. **Construction**, from whatever native function builds the object
   (`widget.create(...)` or similar) -- `core.make_userdata_object` +
   `vm.gc_track`, same as any other heap object:

   ```odin
   data := new(Widget_Data)
   data.handle = rl.MakeSomeHandle()
   o := core.make_userdata_object(&widget_vtable, data)
   vm.gc_track(v, &o.obj)
   return core.make_object_value(&o.obj, true)
   ```

That's the whole kind. `core/object.odin`, `vm/gc.odin`, and
`vm/call.odin` do not change -- they already have the one
`case .Userdata:` that dispatches through whichever vtable the object
carries.

### Optional vtable fields

- **`mark`** -- only needed if `data` holds a pointer to another
  `core.Obj` (a `Widget` that wraps a `List`, say). Cast `vm_ctx` back
  with `vm.native_vm` and call `vm.mark_object`. Leave `nil` (the
  common case, and what `sound_vtable`/`music_vtable` both do) if the
  payload is plain data/external handles only.
- **`to_string`** -- leave `nil` to get `"<tag>"` for free (what Sound/
  Music use, matching `"<sound>"`/`"<music>"`); only implement it if
  the printed form needs to include instance data (dimensions, a name,
  ...).
- **`size`** -- a byte estimate added on top of `size_of(Userdata_Object)`
  for the GC's heap-growth heuristic (see `vm/gc.odin`'s `object_size`
  doc comment). Only worth implementing if the payload's real footprint
  is large and variable (a backing buffer, a big map) -- exactness
  doesn't matter, only rough proportionality. `nil` is fine for a
  small fixed-size payload.

### One thing you lose

A typed `core.as_widget(v) -> ^Widget_Object` accessor can't live in
`core` anymore, because `core` never learns the concrete payload type
-- only the module that owns the type can spell it. Keep that cast
private to your native file (`cast(^Widget_Data)core.as_userdata(v).data`),
the way `sound_invoke`/`music_invoke` just cast `data` directly rather
than round-tripping through a named accessor.

## Testing

Real end-to-end tests live under `tests/new_tests/` (pytest,
`run_lox()` in `lox_helper.py` shells out to a built `bin/odlox.exe`).
Build with `bin/build.sh` after any change under `src/`, then run the
relevant `test_*.py` file (or the whole suite) before considering a
native module change done -- `odin check`/`odin test src/core` catch
type errors and core-language regressions, but they don't exercise
native dispatch at all; only running real `.lox` scripts through the
built interpreter does.
