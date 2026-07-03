const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Kernel executable
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = b.path("kernel/core/main.zig"),
        .target = target,
        .optimize = optimize,
        .pic = false,
        .link_libc = false,
    });

    // Disable stack probing and red zone for kernel
    kernel.code_model = .kernel;
    kernel.root_module.single_threaded = true;
    kernel.root_module.red_zone = false;

    // Assembly boot code
    const boot_asm = b.addObject(.{
        .name = "boot",
        .root_source_file = b.path("arch/x86_64/boot.S"),
        .target = target,
        .optimize = optimize,
    });

    kernel.addObject(boot_asm);

    // Library modules
    const lib_string = b.addModule("lib_string", .{
        .root_source_file = b.path("lib/string.zig"),
    });
    const lib_printk = b.addModule("lib_printk", .{
        .root_source_file = b.path("lib/printk.zig"),
    });
    const lib_errno = b.addModule("lib_errno", .{
        .root_source_file = b.path("lib/errno.zig"),
    });

    kernel.root_module.addImport("lib_string", lib_string);
    kernel.root_module.addImport("lib_printk", lib_printk);
    kernel.root_module.addImport("lib_errno", lib_errno);

    // Linker script
    kernel.setLinkerScript(b.path("arch/x86_64/linker.ld"));

    b.installArtifact(kernel);

    // Build userspace libc in Zig
    const libc = b.addStaticLibrary(.{
        .name = "libc",
        .root_source_file = b.path("userspace/libc/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    libc.code_model = .default;
    libc.root_module.single_threaded = true;
    libc.linkLibC();
    b.installArtifact(libc);

    // Build hello world userspace program
    const hello = b.addExecutable(.{
        .name = "hello.elf",
        .root_source_file = b.path("userspace/hello/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    hello.linkLibrary(libc);
    hello.setLinkerScript(b.path("userspace/linker.ld"));
    b.installArtifact(hello);

    // ISO building (still uses make)
    const iso_step = b.step("iso", "Build bootable ISO");
    const iso_cmd = b.addSystemCommand(&.{"make", "iso"});
    iso_step.dependOn(&iso_cmd.step);

    // QEMU running
    const run_bios = b.step("run-bios", "Run in QEMU (BIOS)");
    const run_bios_cmd = b.addSystemCommand(&.{"make", "run-bios"});
    run_bios.dependOn(&run_bios_cmd.step);
}
