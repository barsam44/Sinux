//! Sinux libc in Zig
//! Minimal C library for userspace programs

const std = @import("std");

// Re-export string functions
pub const strlen = @import("../../lib/string.zig").strlen;
pub const strcmp = @import("../../lib/string.zig").strcmp;
pub const strcpy = @import("../../lib/string.zig").strcpy;
pub const memcpy = @import("../../lib/string.zig").memcpy;
pub const memset = @import("../../lib/string.zig").memset;

// Syscall wrappers
extern fn syscall(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) isize;

pub fn write(fd: usize, buf: [*]const u8, count: usize) isize {
    return syscall(1, fd, @intFromPtr(buf), count, 0, 0, 0);
}

pub fn read(fd: usize, buf: [*]u8, count: usize) isize {
    return syscall(0, fd, @intFromPtr(buf), count, 0, 0, 0);
}

pub fn getpid() usize {
    return @intCast(syscall(39, 0, 0, 0, 0, 0, 0));
}

pub fn exit(code: i32) noreturn {
    _ = syscall(60, @intCast(code), 0, 0, 0, 0, 0);
    unreachable;
}

pub fn printf(comptime fmt: []const u8, args: anytype) usize {
    var buf: [512]u8 = undefined;
    // Simple format string handling
    var pos: usize = 0;
    var i: usize = 0;
    var arg_idx: usize = 0;

    while (i < fmt.len and pos < buf.len - 1) : (i += 1) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'd' => {
                    if (arg_idx < args.len) {
                        var num_buf: [32]u8 = undefined;
                        const num_str = itoa(args[arg_idx], &num_buf, 10);
                        const len = strlen(num_str);
                        if (pos + len < buf.len) {
                            @memcpy(buf[pos .. pos + len], num_str[0..len]);
                            pos += len;
                        }
                        arg_idx += 1;
                    }
                }
                's' => {
                    if (arg_idx < args.len) {
                        const str: [*:0]const u8 = args[arg_idx];
                        const len = strlen(str);
                        if (pos + len < buf.len) {
                            @memcpy(buf[pos .. pos + len], str[0..len]);
                            pos += len;
                        }
                        arg_idx += 1;
                    }
                }
                'n' => {
                    buf[pos] = '\n';
                    pos += 1;
                }
                '%' => {
                    buf[pos] = '%';
                    pos += 1;
                }
                else => {
                    buf[pos] = fmt[i];
                    pos += 1;
                }
            }
        } else if (fmt[i] == '\\' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'n' => {
                    buf[pos] = '\n';
                    pos += 1;
                }
                else => {}
            }
        } else {
            buf[pos] = fmt[i];
            pos += 1;
        }
    }
    buf[pos] = 0;

    return @intCast(write(1, &buf[0], pos));
}

fn strlen(s: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

fn itoa(value: i32, dest: [*]u8, radix: u32) [*:0]u8 {
    if (radix < 2 or radix > 36) {
        dest[0] = 0;
        return dest;
    }

    var buf: [32]u8 = undefined;
    var num = @abs(value);
    var i: usize = 0;

    if (num == 0) {
        buf[0] = '0';
        i = 1;
    } else {
        while (num > 0) : (i += 1) {
            const digit = num % radix;
            buf[i] = if (digit < 10) '0' + @as(u8, @intCast(digit)) else 'a' + @as(u8, @intCast(digit - 10));
            num /= radix;
        }
    }

    if (value < 0) {
        buf[i] = '-';
        i += 1;
    }

    var j: usize = 0;
    var k = i - 1;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[k];
        buf[k] = tmp;
        if (k > 0) k -= 1;
    }

    @memcpy(dest[0..i], buf[0..i]);
    dest[i] = 0;
    return dest;
}
