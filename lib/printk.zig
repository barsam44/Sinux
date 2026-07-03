//! Kernel printf for freestanding Zig
//! Replaces lib/printk.c with type-safe Zig implementation

const std = @import("std");
const string = @import("lib_string");
const tty = @import("../../drivers/tty"); // forward reference

pub const KERN_INFO = "<6>";
pub const KERN_WARNING = "<4>";
pub const KERN_ERR = "<3>";

var log_level: u8 = 6; // INFO

pub fn set_log_level(level: u8) void {
    log_level = level;
}

pub fn printk_impl(level: u8, comptime fmt: []const u8, args: anytype) void {
    if (level > log_level) return;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;

    var arg_index: usize = 0;
    var i: usize = 0;

    while (i < fmt.len and pos < buf.len - 1) : (i += 1) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'd' => {
                    if (arg_index < args.len) {
                        var num_buf: [32]u8 = undefined;
                        const num_str = string.itoa(args[arg_index], &num_buf, 10);
                        const num_len = string.strlen(num_str);
                        if (pos + num_len < buf.len) {
                            @memcpy(buf[pos .. pos + num_len], num_str[0..num_len]);
                            pos += num_len;
                        }
                        arg_index += 1;
                    }
                }
                'u' => {
                    if (arg_index < args.len) {
                        var num_buf: [32]u8 = undefined;
                        const num = args[arg_index];
                        const num_str = string.itoa(@bitCast(num), &num_buf, 10);
                        const num_len = string.strlen(num_str);
                        if (pos + num_len < buf.len) {
                            @memcpy(buf[pos .. pos + num_len], num_str[0..num_len]);
                            pos += num_len;
                        }
                        arg_index += 1;
                    }
                }
                'x' => {
                    if (arg_index < args.len) {
                        var num_buf: [32]u8 = undefined;
                        const num = args[arg_index];
                        const num_str = string.itoa(@bitCast(num), &num_buf, 16);
                        const num_len = string.strlen(num_str);
                        if (pos + num_len < buf.len) {
                            @memcpy(buf[pos .. pos + num_len], num_str[0..num_len]);
                            pos += num_len;
                        }
                        arg_index += 1;
                    }
                }
                's' => {
                    if (arg_index < args.len) {
                        const str: [*:0]const u8 = args[arg_index];
                        const str_len = string.strlen(str);
                        if (pos + str_len < buf.len) {
                            @memcpy(buf[pos .. pos + str_len], str[0..str_len]);
                            pos += str_len;
                        }
                        arg_index += 1;
                    }
                }
                'c' => {
                    if (arg_index < args.len) {
                        buf[pos] = args[arg_index];
                        pos += 1;
                        arg_index += 1;
                    }
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
                't' => {
                    buf[pos] = '\t';
                    pos += 1;
                }
                else => {
                    buf[pos] = fmt[i];
                    pos += 1;
                }
            }
        } else {
            buf[pos] = fmt[i];
            pos += 1;
        }
    }
    buf[pos] = 0;

    // Output to TTY (will be implemented in tty module)
    tty.tty_puts(&buf[0]);
}

pub fn printk(comptime fmt: []const u8, args: anytype) void {
    printk_impl(6, fmt, args);
}
