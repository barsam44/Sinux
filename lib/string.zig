//! String utilities for freestanding Zig kernel
//! Replaces lib/string.c with type-safe Zig equivalents

const std = @import("std");

pub fn strlen(s: [*:0]const u8) usize {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {}
    return i;
}

pub fn strcmp(a: [*:0]const u8, b: [*:0]const u8) i32 {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) {
            return @as(i32, a[i]) - @as(i32, b[i]);
        }
    }
    return @as(i32, a[i]) - @as(i32, b[i]);
}

pub fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) i32 {
    var i: usize = 0;
    while (i < n and a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) {
            return @as(i32, a[i]) - @as(i32, b[i]);
        }
    }
    if (i >= n) return 0;
    return @as(i32, a[i]) - @as(i32, b[i]);
}

pub fn strcpy(dest: [*]u8, src: [*:0]const u8) [*]u8 {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    dest[i] = 0;
    return dest;
}

pub fn strncpy(dest: [*]u8, src: [*:0]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    if (i < n) {
        dest[i] = 0;
    }
    return dest;
}

pub fn strncat(dest: [*:0]u8, src: [*:0]const u8, n: usize) [*:0]u8 {
    var dlen = strlen(dest);
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) {
        dest[dlen + i] = src[i];
    }
    dest[dlen + i] = 0;
    return dest;
}

pub fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

pub fn memmove(dest: [*]u8, src: [*]const u8, n: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        return memcpy(dest, src, n);
    }
    // Copy backwards to avoid overlap
    var i = n;
    while (i > 0) : (i -= 1) {
        dest[i - 1] = src[i - 1];
    }
    return dest;
}

pub fn memset(dest: [*]u8, value: u8, n: usize) [*]u8 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        dest[i] = value;
    }
    return dest;
}

pub fn memcmp(a: [*]const u8, b: [*]const u8, n: usize) i32 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) {
            return @as(i32, a[i]) - @as(i32, b[i]);
        }
    }
    return 0;
}

pub fn atoi(s: [*:0]const u8) i32 {
    var result: i32 = 0;
    var i: usize = 0;

    while (s[i] != 0 and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}

    const negative = s[i] == '-';
    if (s[i] == '-' or s[i] == '+') : (i += 1) {}

    while (s[i] != 0 and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i32, s[i] - '0');
    }

    return if (negative) -result else result;
}

pub fn itoa(value: i32, dest: [*]u8, radix: u32) [*]u8 {
    if (radix < 2 or radix > 36) {
        dest[0] = 0;
        return dest;
    }

    var buf: [32]u8 = undefined;
    var negative = false;
    var num = value;

    if (value < 0) {
        negative = true;
        num = -value;
    }

    var i: usize = 0;
    if (num == 0) {
        buf[i] = '0';
        i += 1;
    } else {
        while (num > 0) : (i += 1) {
            const digit = @as(u32, @intCast(num % @as(i32, @intCast(radix))));
            buf[i] = if (digit < 10) '0' + digit else 'a' + digit - 10;
            num /= @as(i32, @intCast(radix));
        }
    }

    if (negative) {
        buf[i] = '-';
        i += 1;
    }

    // Reverse
    var j: usize = 0;
    var k = i - 1;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[k];
        buf[k] = tmp;
        k -= 1;
    }

    memcpy(dest, &buf, i);
    dest[i] = 0;
    return dest;
}
