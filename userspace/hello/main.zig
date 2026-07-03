//! Hello World Userspace Program in Zig

const libc = @import("../../userspace/libc/lib.zig");

export fn _start() noreturn {
    _ = libc.printf("Hello from Sinux userspace!\n", .{});
    _ = libc.printf("PID: %d\n", .{libc.getpid()});
    libc.exit(0);
}
