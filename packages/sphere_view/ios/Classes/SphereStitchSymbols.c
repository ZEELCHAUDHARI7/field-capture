// Keeps the FFI entry points in the linked binary.
//
// Dart reaches the stitch pipeline with `DynamicLibrary.process()`, which
// searches symbols **already in the app binary** — iOS gives no supported way
// to load a `.dylib` at runtime. The pipeline is therefore linked in from a
// static archive, and static archives are pulled in member by member: the
// linker takes an object file only if something already in the link refers to
// a symbol it defines.
//
// Nothing does. `sv_stitch`, `sv_free` and `sv_version` have exactly one
// caller, and it is on the far side of an FFI boundary the linker cannot see.
// So without this file the archive members are never pulled in, the build
// succeeds, and the failure arrives at runtime — on a device, after a
// ninety-second capture — as `Failed to lookup symbol 'sv_stitch'`.
//
// `__attribute__((used))` is what stops the optimiser removing the table for
// being unread, and taking the addresses is what creates the references. This
// is preferred over `-force_load` in `OTHER_LDFLAGS` because Xcode's build
// system treats a `-force_load` path as a build *input* it must be able to
// find before the phase that produces it has run, which fails with "Build
// input file cannot be found" rather than with anything about linking.

#include "sphere_stitch.h"

__attribute__((used)) static const void* const sphere_stitch_ffi_entry_points[] = {
    (const void*)&sv_stitch,
    (const void*)&sv_free,
    (const void*)&sv_version,
};
