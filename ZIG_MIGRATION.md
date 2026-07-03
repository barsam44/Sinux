# Sinux Zig Rewrite Migration Guide

## Overview

This document tracks the progressive migration of Sinux from C to Zig. The strategy is **hybrid first**, keeping low-level boot code in assembly while incrementally rewriting higher-level components in Zig.

## Completed ✓

### Phase 1: Build System
- [x] `build.zig` — Modern Zig build system replacing Makefile
- [x] Modular target configuration (kernel, libc, userspace)

### Phase 2: Library Code
- [x] `lib/string.zig` — String utilities (strlen, strcmp, strcpy, memcpy, etc.)
- [x] `lib/errno.zig` — Error code constants and mappings
- [x] `lib/printk.zig` — Kernel printing with format strings

### Phase 3: Kernel Core
- [x] `kernel/core/main.zig` — Kernel entry point and initialization
- [x] Architecture-agnostic kernel logic

### Phase 4: Userspace
- [x] `userspace/libc/lib.zig` — Minimal C library in Zig
- [x] `userspace/hello/main.zig` — Example Hello World program

## In Progress 🔄

- Memory management (PMM, VMM, slab allocator)
- Filesystem code (VFS, ramfs, ext2)
- Process management and scheduler
- Syscall dispatch and handlers

## Not Yet Started ⏳

- Driver code (TTY, framebuffer, ATA, keyboard, serial)
- IPC (pipes, signals)
- Boot code (remains in NASM assembly)

## Building

```bash
zig build
zig build -Doptimize=ReleaseSafe
zig build run-bios  # Requires Makefile targets
```

## Why Zig?

### Advantages
1. **Type safety** — Catches memory errors at compile time
2. **Lower-level control** — Direct hardware access without losing readability
3. **Bare-metal first** — Built for OS development
4. **Comptime** — Zero-cost abstractions, compile-time computation
5. **Seamless C interop** — Call existing C code without FFI overhead

### Challenges
1. **Assembly integration** — Must keep boot.asm in NASM
2. **Ecosystem maturity** — Fewer battle-tested libraries than C
3. **Build complexity** — Transitioning from Makefiles to build.zig

## Zig Idioms Used

### Freestanding Setup
```zig
const target = b.resolveTargetQuery(.{
    .cpu_arch = .x86_64,
    .os_tag = .freestanding,
    .abi = .none,
});
kernel.code_model = .kernel;
kernel.root_module.single_threaded = true;
kernel.root_module.red_zone = false;
```

### Error Handling
Zig's error sets replace C's errno:
```zig
const ErrorSet = error{
    PermissionDenied,
    FileNotFound,
    InvalidArgument,
};

pub fn errorToErrno(err: ErrorSet) i32 {
    return switch (err) {
        error.PermissionDenied => EACCES,
        // ...
    };
}
```

### String Handling
Zig slices replace C pointers:
```zig
pub fn strlen(s: [*:0]const u8) usize {
    // Sentinel-terminated pointer (null-terminated string)
}

pub fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}
```

## Testing

```bash
# Build only
zig build

# Build and verify linkage
zig build --verbose

# Check generated ELF
readelf -l zig-out/bin/kernel.elf

# Run in QEMU (requires make targets)
make run-bios
```

## Next Steps

1. Rewrite `mm/` (PMM, VMM) in Zig with better type safety
2. Rewrite `kernel/fs/` with safer VFS abstractions
3. Rewrite `kernel/proc/` with better process table management
4. Incrementally port `drivers/` — start with simple ones (serial, TTY)
5. Update boot code to call new Zig kernel_main

## References

- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Zig Bare Metal](https://github.com/ziglang/zig/wiki/Bare-metal-RISCV64)
- [OSDev: x86_64](https://wiki.osdev.org/X86-64)
