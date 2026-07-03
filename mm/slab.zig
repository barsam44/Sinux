//! Slab Allocator for Sinux kernel
//! Replaces mm/slab.c with type-safe Zig and better performance

const std = @import("std");
const vmm = @import("vmm");
const pmm = @import("pmm");
const string = @import("../lib/string");

const PAGE_SIZE = 4096;
const MAX_CACHES = 32;
const SLAB_MAGIC = 0x5AB0BEEF;

// Slab header at start of each page
const SlabHeader = packed struct {
    magic: u32,
    obj_size: u32,
    total_objs: u32,
    free_objs: u32,
    free_bitmap: [59]u64,  // 59*8*64 = 30336 bits for ~504 objects
    next: ?*SlabHeader = null,
};

// Slab cache metadata
const SlabCache = struct {
    name: [*:0]const u8,
    obj_size: usize,
    align: usize,
    partial: ?*SlabHeader,
    full: ?*SlabHeader,
    num_allocs: u64,
    num_frees: u64,
    num_slabs: u64,
};

var caches: [MAX_CACHES]?*SlabCache = [_]?*SlabCache{null} ** MAX_CACHES;
var num_caches: usize = 0;
var size_caches: [8]SlabCache = undefined;

// Bitmap operations
inline fn bitmap_set(bm: [*]u64, idx: usize) void {
    bm[idx / 64] |= @as(u64, 1) << @as(u6, @intCast(idx % 64));
}

inline fn bitmap_clear(bm: [*]u64, idx: usize) void {
    bm[idx / 64] &= ~(@as(u64, 1) << @as(u6, @intCast(idx % 64)));
}

inline fn bitmap_test(bm: [*]u64, idx: usize) bool {
    return ((bm[idx / 64] >> @as(u6, @intCast(idx % 64))) & 1) != 0;
}

fn bitmap_find_free(bm: [*]u64, max: usize) ?usize {
    for (0..max) |i| {
        if (!bitmap_test(bm, i)) return i;
    }
    return null;
}

/// Create a new slab
fn slab_create(obj_size: usize) ?*SlabHeader {
    const page = pmm.pmm_alloc() orelse return null;
    @memset(@as([*]u8, @ptrCast(page))[0..PAGE_SIZE], 0);

    const slab = @as(*SlabHeader, @ptrCast(page));
    slab.magic = SLAB_MAGIC;
    slab.obj_size = @as(u32, @intCast(obj_size));

    const usable = PAGE_SIZE - @sizeOf(SlabHeader);
    slab.total_objs = @min(@as(u32, @intCast(usable / obj_size)), 504);
    slab.free_objs = slab.total_objs;
    slab.next = null;

    return slab;
}

fn slab_get_obj(slab: *SlabHeader, idx: usize) *anyopaque {
    const base = @as([*]u8, @ptrCast(slab)) + @sizeOf(SlabHeader);
    return @as(*anyopaque, @ptrFromInt(@intFromPtr(base) + idx * slab.obj_size));
}

fn slab_find_obj_idx(slab: *SlabHeader, ptr: *anyopaque) ?usize {
    const base = @as([*]u8, @ptrCast(slab)) + @sizeOf(SlabHeader);
    const p = @as([*]u8, @ptrCast(ptr));

    if (@intFromPtr(p) < @intFromPtr(base)) return null;

    const offset = @intFromPtr(p) - @intFromPtr(base);
    if (offset % slab.obj_size != 0) return null;

    const idx = offset / slab.obj_size;
    if (idx >= slab.total_objs) return null;

    return idx;
}

/// Create a cache for objects of given size
pub fn slab_cache_create(name: [*:0]const u8, size: usize, align: usize) ?*SlabCache {
    if (num_caches >= MAX_CACHES or size == 0 or size > PAGE_SIZE / 2) return null;

    const aligned_size = std.mem.alignForwardUnsafe(size, align);
    const aligned_size_fixed = @max(aligned_size, 16);

    const cache = vmm.kmalloc(@sizeOf(SlabCache)) orelse return null;
    const cache_ptr = @as(*SlabCache, @ptrCast(cache));

    cache_ptr.name = name;
    cache_ptr.obj_size = aligned_size_fixed;
    cache_ptr.align = align;
    cache_ptr.partial = null;
    cache_ptr.full = null;
    cache_ptr.num_allocs = 0;
    cache_ptr.num_frees = 0;
    cache_ptr.num_slabs = 0;

    caches[num_caches] = cache_ptr;
    num_caches += 1;

    return cache_ptr;
}

/// Allocate from cache
pub fn slab_alloc(cache: *SlabCache) ?*anyopaque {
    if (cache.partial == null) {
        const new_slab = slab_create(cache.obj_size) orelse return null;
        new_slab.next = cache.partial;
        cache.partial = new_slab;
        cache.num_slabs += 1;
    }

    var slab = cache.partial orelse unreachable;

    if (bitmap_find_free(@ptrCast(&slab.free_bitmap), slab.total_objs)) |idx| {
        bitmap_set(@ptrCast(&slab.free_bitmap), idx);
        slab.free_objs -= 1;
        cache.num_allocs += 1;

        if (slab.free_objs == 0) {
            cache.partial = slab.next;
            slab.next = cache.full;
            cache.full = slab;
        }

        return slab_get_obj(slab, idx);
    }

    return null;
}

/// Free from cache
pub fn slab_free(cache: *SlabCache, ptr: *anyopaque) void {
    const slab_addr = @intFromPtr(ptr) & ~@as(usize, PAGE_SIZE - 1);
    const slab = @as(*SlabHeader, @ptrFromInt(slab_addr));

    if (slab.magic != SLAB_MAGIC) return;
    if (slab_find_obj_idx(slab, ptr)) |idx| {
        if (!bitmap_test(@ptrCast(&slab.free_bitmap), idx)) return;

        const was_full = slab.free_objs == 0;
        bitmap_clear(@ptrCast(&slab.free_bitmap), idx);
        slab.free_objs += 1;
        cache.num_frees += 1;

        if (was_full) {
            if (cache.full == slab) {
                cache.full = slab.next;
            } else if (cache.full) |full_slab| {
                var prev = full_slab;
                while (prev.next != slab) {
                    prev = prev.next orelse break;
                }
                if (prev.next == slab) prev.next = slab.next;
            }
            slab.next = cache.partial;
            cache.partial = slab;
        }
    }
}

/// Destroy cache and free all slabs
pub fn slab_cache_destroy(cache: *SlabCache) void {
    var slab = cache.partial;
    while (slab) |s| {
        const next = s.next;
        pmm.pmm_free(@as(*anyopaque, @ptrCast(s)));
        slab = next;
    }

    slab = cache.full;
    while (slab) |s| {
        const next = s.next;
        pmm.pmm_free(@as(*anyopaque, @ptrCast(s)));
        slab = next;
    }

    // Remove from registry
    for (0..num_caches) |i| {
        if (caches[i] == cache) {
            caches[i] = caches[num_caches - 1];
            num_caches -= 1;
            break;
        }
    }

    vmm.kfree(@as(*anyopaque, @ptrCast(cache)));
}

/// Initialize standard size caches
pub fn slab_init() void {
    const sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
    const names = [_][*:0]const u8{
        "kmalloc-16", "kmalloc-32", "kmalloc-64", "kmalloc-128",
        "kmalloc-256", "kmalloc-512", "kmalloc-1024", "kmalloc-2048",
    };

    for (0..8) |i| {
        size_caches[i] = SlabCache{
            .name = names[i],
            .obj_size = sizes[i],
            .align = 16,
            .partial = null,
            .full = null,
            .num_allocs = 0,
            .num_frees = 0,
            .num_slabs = 0,
        };
    }
}

/// Allocate with slab caches
pub fn kmalloc_slab(size: usize) ?*anyopaque {
    if (size == 0) return null;

    if (size > 2048) {
        // Large allocations: use PMM
        const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;
        return pmm.pmm_alloc();
    }

    // Find appropriate size cache
    for (0..8) |i| {
        if (size <= size_caches[i].obj_size) {
            return slab_alloc(&size_caches[i]);
        }
    }

    return null;
}

/// Free with slab caches
pub fn kfree_slab(ptr: ?*anyopaque) void {
    if (ptr == null) return;

    const slab_addr = @intFromPtr(ptr) & ~@as(usize, PAGE_SIZE - 1);
    const slab = @as(*SlabHeader, @ptrFromInt(slab_addr));

    if (slab.magic != SLAB_MAGIC) {
        pmm.pmm_free(ptr);
        return;
    }

    // Find cache by object size
    for (0..8) |i| {
        if (size_caches[i].obj_size == slab.obj_size) {
            slab_free(&size_caches[i], ptr.?);
            return;
        }
    }

    for (0..num_caches) |i| {
        if (caches[i]) |cache| {
            if (cache.obj_size == slab.obj_size) {
                slab_free(cache, ptr.?);
                return;
            }
        }
    }
}
