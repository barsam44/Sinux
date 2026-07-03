//! Physical Memory Manager (PMM) for Sinux kernel
//! Manages physical page allocation using a bitmap
//! Replaces mm/pmm.c with type-safe Zig implementation

const std = @import("std");
const string = @import("../lib/string");

const PAGE_SIZE = 4096;
const BITMAP_MAX_PAGES = 16 * 1024 * 1024; // 64 GiB max addressable

// Multiboot2 constants
const MB2_MAGIC = 0x36D76289;
const TAG_END = 0;
const TAG_MMAP = 6;

// Multiboot2 structures (packed)
const MB2Hdr = packed struct {
    total: u32,
    reserved: u32,
};

const MB2Tag = packed struct {
    type: u32,
    size: u32,
};

const MB2MmapTag = packed struct {
    type: u32,
    size: u32,
    entry_size: u32,
    entry_ver: u32,
};

const MB2MmapEntry = packed struct {
    base: u64,
    len: u64,
    type: u32,
    _reserved: u32,
};

var bitmap: [*]u8 = undefined;
var total_pages: usize = 0;
var free_pages: usize = 0;
var bitmap_size: usize = 0;

// Bitmap operations
inline fn bitmap_set(idx: usize) void {
    bitmap[idx / 8] |= @as(u8, 1) << @as(u3, @intCast(idx % 8));
}

inline fn bitmap_clear(idx: usize) void {
    bitmap[idx / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(idx % 8)));
}

inline fn bitmap_test(idx: usize) bool {
    return ((bitmap[idx / 8] >> @as(u3, @intCast(idx % 8))) & 1) != 0;
}

/// Initialize PMM from Multiboot2 memory map
pub fn pmm_init(magic: u32, info_addr: u64) void {
    if (magic != MB2_MAGIC) return;

    const hdr = @as([*]MB2Hdr, @ptrFromInt(info_addr))[0];
    var ptr = @as([*]u8, @ptrFromInt(info_addr)) + 8;
    const end = @as([*]u8, @ptrFromInt(info_addr)) + hdr.total;

    // Phase 1: Find maximum memory address
    var max_addr: u64 = 0;
    while (@intFromPtr(ptr) + @sizeOf(MB2Tag) <= @intFromPtr(end)) {
        const tag = @as(*const MB2Tag, @ptrCast(ptr));
        if (tag.type == TAG_END) break;

        if (tag.type == TAG_MMAP) {
            const mmap_tag = @as(*const MB2MmapTag, @ptrCast(ptr));
            var ep = ptr + @sizeOf(MB2MmapTag);
            const ee = ptr + mmap_tag.size;

            while (@intFromPtr(ep) + mmap_tag.entry_size <= @intFromPtr(ee)) {
                const entry = @as(*const MB2MmapEntry, @ptrCast(ep));
                if (entry.type == 1) {
                    const top = entry.base + entry.len;
                    if (top > max_addr) max_addr = top;
                }
                ep += mmap_tag.entry_size;
            }
        }

        ptr += (tag.size + 7) & ~@as(u32, 7);
    }

    total_pages = @min(@as(usize, @intCast(max_addr / PAGE_SIZE)), BITMAP_MAX_PAGES);
    bitmap_size = (total_pages + 7) / 8;

    // Phase 2: Find a suitable location for the bitmap (at 0x200000)
    ptr = @as([*]u8, @ptrFromInt(info_addr)) + 8;
    var bitmap_placed = false;

    while (@intFromPtr(ptr) + @sizeOf(MB2Tag) <= @intFromPtr(end) and !bitmap_placed) {
        const tag = @as(*const MB2Tag, @ptrCast(ptr));
        if (tag.type == TAG_END) break;

        if (tag.type == TAG_MMAP) {
            const mmap_tag = @as(*const MB2MmapTag, @ptrCast(ptr));
            var ep = ptr + @sizeOf(MB2MmapTag);
            const ee = ptr + mmap_tag.size;

            while (@intFromPtr(ep) + mmap_tag.entry_size <= @intFromPtr(ee) and !bitmap_placed) {
                const entry = @as(*const MB2MmapEntry, @ptrCast(ep));
                if (entry.type == 1 and entry.base >= 0x200000 and entry.len >= bitmap_size) {
                    bitmap = @as([*]u8, @ptrFromInt(entry.base));
                    bitmap_placed = true;
                }
                ep += mmap_tag.entry_size;
            }
        }

        ptr += (tag.size + 7) & ~@as(u32, 7);
    }

    if (!bitmap_placed) return;

    // Phase 3: Mark all pages as used initially
    @memset(bitmap[0..bitmap_size], 0xFF);
    free_pages = 0;

    // Phase 4: Mark free pages from memory map
    ptr = @as([*]u8, @ptrFromInt(info_addr)) + 8;
    while (@intFromPtr(ptr) + @sizeOf(MB2Tag) <= @intFromPtr(end)) {
        const tag = @as(*const MB2Tag, @ptrCast(ptr));
        if (tag.type == TAG_END) break;

        if (tag.type == TAG_MMAP) {
            const mmap_tag = @as(*const MB2MmapTag, @ptrCast(ptr));
            var ep = ptr + @sizeOf(MB2MmapTag);
            const ee = ptr + mmap_tag.size;

            while (@intFromPtr(ep) + mmap_tag.entry_size <= @intFromPtr(ee)) {
                const entry = @as(*const MB2MmapEntry, @ptrCast(ep));
                if (entry.type == 1) {
                    const start = (entry.base + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
                    const stop = (entry.base + entry.len) & ~@as(u64, PAGE_SIZE - 1);

                    var addr = start;
                    while (addr < stop) : (addr += PAGE_SIZE) {
                        const idx = @as(usize, @intCast(addr / PAGE_SIZE));
                        if (idx < total_pages) {
                            bitmap_clear(idx);
                            free_pages += 1;
                        }
                    }
                }
                ep += mmap_tag.entry_size;
            }
        }

        ptr += (tag.size + 7) & ~@as(u32, 7);
    }

    // Phase 5: Reserve pages used by kernel and bitmap
    var addr: u64 = 0;
    while (addr < 0x200000 + bitmap_size + PAGE_SIZE) : (addr += PAGE_SIZE) {
        const idx = @as(usize, @intCast(addr / PAGE_SIZE));
        if (idx < total_pages and !bitmap_test(idx)) {
            bitmap_set(idx);
            free_pages -= 1;
        }
    }
}

/// Allocate a single physical page
pub fn pmm_alloc() ?*anyopaque {
    for (0..total_pages) |i| {
        if (!bitmap_test(i)) {
            bitmap_set(i);
            free_pages -= 1;
            return @as(*anyopaque, @ptrFromInt(i * PAGE_SIZE));
        }
    }
    return null;
}

/// Free a physical page
pub fn pmm_free(page: *anyopaque) void {
    const idx = @intFromPtr(page) / PAGE_SIZE;
    if (idx < total_pages and bitmap_test(idx)) {
        bitmap_clear(idx);
        free_pages += 1;
    }
}

/// Get number of free pages
pub fn pmm_free_pages() usize {
    return free_pages;
}

/// Get total number of pages
pub fn pmm_total_pages() usize {
    return total_pages;
}
