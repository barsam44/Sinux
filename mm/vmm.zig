//! Virtual Memory Manager (VMM) for Sinux kernel
//! Manages 4-level page tables (PML4/PDPT/PDT/PT)
//! Replaces mm/vmm.c with type-safe Zig and better abstractions

const std = @import("std");
const string = @import("../lib/string");
const pmm = @import("pmm");

const PAGE_SIZE = 4096;

// Page table entry flags
pub const VMM_PRESENT = 1 << 0;
pub const VMM_WRITABLE = 1 << 1;
pub const VMM_USER = 1 << 2;
pub const VMM_WRITE_THROUGH = 1 << 3;
pub const VMM_CACHE_DISABLED = 1 << 4;
pub const VMM_ACCESSED = 1 << 5;
pub const VMM_HUGE = 1 << 7;
pub const VMM_NX = 1 << 63;

// Memory layout constants
pub const KERNEL_PHYS_BASE = 0x100000;
pub const KERNEL_VIRT_BASE = 0xFFFFFFFF80000000;
pub const KERNEL_MAP_SIZE = 64 * 1024 * 1024;

pub const USER_LOAD_BASE = 0x400000;
pub const USER_STACK_TOP = 0x7FFFFFF00000;
pub const USER_STACK_SIZE = 2 * 1024 * 1024;

var kernel_pml4: ?[*]u64 = null;
var slab_ready = false;

// Page table type alias
const PageTable = [512]u64;

/// Get or allocate a page table entry
fn get_or_alloc(table: [*]u64, idx: usize, flags: u64) ![*]u64 {
    if ((table[idx] & VMM_PRESENT) == 0) {
        const page = pmm.pmm_alloc() orelse return error.OutOfMemory;
        @memset(@as([*]u8, @ptrCast(page))[0..PAGE_SIZE], 0);
        table[idx] = @intFromPtr(page) | flags;
    }
    return @as([*]u64, @ptrFromInt(table[idx] & ~@as(u64, 0xFFF)));
}

/// Index extractors for virtual address
inline fn p4_idx(virt: u64) usize {
    return @as(usize, @intCast((virt >> 39) & 0x1FF));
}

inline fn p3_idx(virt: u64) usize {
    return @as(usize, @intCast((virt >> 30) & 0x1FF));
}

inline fn p2_idx(virt: u64) usize {
    return @as(usize, @intCast((virt >> 21) & 0x1FF));
}

inline fn p1_idx(virt: u64) usize {
    return @as(usize, @intCast((virt >> 12) & 0x1FF));
}

/// Reconstruct virtual address from table indices
inline fn reconstruct_vaddr(p4: u64, p3: u64, p2: u64, p1: u64) u64 {
    return (p4 << 39) | (p3 << 30) | (p2 << 21) | (p1 << 12);
}

/// Map a single virtual page to physical
pub fn vmm_map(pml4: [*]u64, virt: u64, phys: u64, flags: u64) !void {
    const tbl_flags = VMM_PRESENT | VMM_WRITABLE | (flags & VMM_USER);

    const pdpt = try get_or_alloc(pml4, p4_idx(virt), tbl_flags);
    const pdt = try get_or_alloc(pdpt, p3_idx(virt), tbl_flags);
    const pt = try get_or_alloc(pdt, p2_idx(virt), tbl_flags);

    const p1 = p1_idx(virt);
    pt[p1] = (phys & ~@as(u64, 0xFFF)) | (flags & 0xFFF) | VMM_PRESENT;
    if ((flags & VMM_NX) != 0) pt[p1] |= VMM_NX;

    // Invalidate TLB entry
    asm volatile ("invlpg (%[virt])" : : [virt] "r" (virt) : "memory");
}

/// Unmap a virtual page
pub fn vmm_unmap(pml4: [*]u64, virt: u64) void {
    if ((pml4[p4_idx(virt)] & VMM_PRESENT) == 0) return;
    const pdpt = @as([*]u64, @ptrFromInt(pml4[p4_idx(virt)] & ~@as(u64, 0xFFF)));

    if ((pdpt[p3_idx(virt)] & VMM_PRESENT) == 0) return;
    const pdt = @as([*]u64, @ptrFromInt(pdpt[p3_idx(virt)] & ~@as(u64, 0xFFF)));

    if ((pdt[p2_idx(virt)] & VMM_PRESENT) == 0) return;
    const pt = @as([*]u64, @ptrFromInt(pdt[p2_idx(virt)] & ~@as(u64, 0xFFF)));

    pt[p1_idx(virt)] = 0;
    asm volatile ("invlpg (%[virt])" : : [virt] "r" (virt) : "memory");
}

/// Get physical address for virtual address
pub fn vmm_get_phys(pml4: [*]u64, virt: u64) u64 {
    if ((pml4[p4_idx(virt)] & VMM_PRESENT) == 0) return 0;
    const pdpt = @as([*]u64, @ptrFromInt(pml4[p4_idx(virt)] & ~@as(u64, 0xFFF)));

    if ((pdpt[p3_idx(virt)] & VMM_PRESENT) == 0) return 0;
    const pdt = @as([*]u64, @ptrFromInt(pdpt[p3_idx(virt)] & ~@as(u64, 0xFFF)));

    if ((pdt[p2_idx(virt)] & VMM_PRESENT) == 0) return 0;
    const pt = @as([*]u64, @ptrFromInt(pdt[p2_idx(virt)] & ~@as(u64, 0xFFF)));

    return pt[p1_idx(virt)] & ~@as(u64, 0xFFF);
}

/// Map a range of virtual memory
pub fn vmm_map_range(pml4: [*]u64, virt: u64, phys: u64, size: usize, flags: u64) !void {
    var offset: usize = 0;
    while (offset < size) : (offset += PAGE_SIZE) {
        try vmm_map(pml4, virt + offset, phys + offset, flags);
    }
}

/// Get current kernel PML4
pub fn vmm_kernel_pml4() ?[*]u64 {
    return kernel_pml4;
}

/// Get current page table (CR3)
pub fn vmm_current() [*]u64 {
    var cr3: u64 = undefined;
    asm volatile ("mov %%cr3, %[cr3]" : [cr3] "=r" (cr3));
    return @as([*]u64, @ptrFromInt(cr3 & ~@as(u64, 0xFFF)));
}

/// Switch to new page table
pub fn vmm_switch(pml4: [*]u64) void {
    asm volatile ("mov %[pml4], %%cr3" : : [pml4] "r" (@intFromPtr(pml4)) : "memory");
}

/// Create a new PML4 (kernel mappings copied)
pub fn vmm_new_pml4() ?[*]u64 {
    const pml4 = pmm.pmm_alloc() orelse return null;
    @memset(@as([*]u8, @ptrCast(pml4))[0..PAGE_SIZE], 0);

    if (kernel_pml4) |kpml4| {
        // Copy kernel mappings (indices 256-511)
        const src_pt = @as([*]u64, @ptrCast(pml4));
        const dst_pt = @as([*]u64, @ptrCast(kpml4));
        @memcpy(src_pt[256..512], dst_pt[256..512]);
    }

    return @as([*]u64, @ptrCast(pml4));
}

/// Destroy PML4 and free all user pages
pub fn vmm_destroy_pml4(pml4: [*]u64) void {
    // Only walk user space (indices 0-255)
    for (0..256) |p4| {
        if ((pml4[p4] & VMM_PRESENT) == 0) continue;

        const pdpt = @as([*]u64, @ptrFromInt(pml4[p4] & ~@as(u64, 0xFFF)));
        for (0..512) |p3| {
            if ((pdpt[p3] & VMM_PRESENT) == 0) continue;

            const pdt = @as([*]u64, @ptrFromInt(pdpt[p3] & ~@as(u64, 0xFFF)));
            for (0..512) |p2| {
                if ((pdt[p2] & VMM_PRESENT) == 0) continue;

                const pt = @as([*]u64, @ptrFromInt(pdt[p2] & ~@as(u64, 0xFFF)));
                for (0..512) |p1| {
                    if ((pt[p1] & VMM_PRESENT) != 0) {
                        pmm.pmm_free(@as(*anyopaque, @ptrFromInt(pt[p1] & ~@as(u64, 0xFFF))));
                    }
                }
                pmm.pmm_free(@as(*anyopaque, @ptrFromInt(@intFromPtr(pt))));
            }
            pmm.pmm_free(@as(*anyopaque, @ptrFromInt(@intFromPtr(pdt))));
        }
        pmm.pmm_free(@as(*anyopaque, @ptrFromInt(@intFromPtr(pdpt))));
    }
    pmm.pmm_free(@as(*anyopaque, @ptrFromInt(@intFromPtr(pml4))));
}

/// Deep copy user address space for fork()
pub fn vmm_clone_pml4(src: [*]u64) ?[*]u64 {
    const dst = vmm_new_pml4() orelse return null;

    // Walk user space only (0-255)
    for (0..256) |p4| {
        if ((src[p4] & VMM_PRESENT) == 0) continue;

        const src_pdpt = @as([*]u64, @ptrFromInt(src[p4] & ~@as(u64, 0xFFF)));

        for (0..512) |p3| {
            if ((src_pdpt[p3] & VMM_PRESENT) == 0) continue;

            const src_pdt = @as([*]u64, @ptrFromInt(src_pdpt[p3] & ~@as(u64, 0xFFF)));

            for (0..512) |p2| {
                if ((src_pdt[p2] & VMM_PRESENT) == 0) continue;

                const src_pt = @as([*]u64, @ptrFromInt(src_pdt[p2] & ~@as(u64, 0xFFF)));

                for (0..512) |p1| {
                    if ((src_pt[p1] & VMM_PRESENT) == 0) continue;

                    const src_phys = src_pt[p1] & ~@as(u64, 0xFFF);
                    const flags = src_pt[p1] & 0xFFF;

                    // Allocate new page and copy
                    const new_page = pmm.pmm_alloc() orelse {
                        vmm_destroy_pml4(dst);
                        return null;
                    };
                    @memcpy(
                        @as([*]u8, @ptrCast(new_page))[0..PAGE_SIZE],
                        @as([*]u8, @ptrFromInt(src_phys))[0..PAGE_SIZE],
                    );

                    // Reconstruct virtual address
                    const virt = reconstruct_vaddr(
                        @as(u64, @intCast(p4)),
                        @as(u64, @intCast(p3)),
                        @as(u64, @intCast(p2)),
                        @as(u64, @intCast(p1)),
                    );

                    vmm_map(dst, virt, @intFromPtr(new_page), flags) catch {
                        vmm_destroy_pml4(dst);
                        return null;
                    };
                }
            }
        }
    }
    return dst;
}

/// Initialize VMM - capture kernel PML4 from CR3
pub fn vmm_init() void {
    var cr3: u64 = undefined;
    asm volatile ("mov %%cr3, %[cr3]" : [cr3] "=r" (cr3));
    kernel_pml4 = @as([*]u64, @ptrFromInt(cr3 & ~@as(u64, 0xFFF)));
    slab_ready = false;
}

/// Kernel malloc (fallback to PMM before slab is ready)
pub fn kmalloc(size: usize) ?*anyopaque {
    if (size == 0) return null;

    const aligned_size = (size + 15) & ~@as(usize, 15);
    const pages_needed = (aligned_size + PAGE_SIZE - 1) / PAGE_SIZE;

    var first_page = pmm.pmm_alloc() orelse return null;
    var current_ptr = first_page;

    // Allocate additional pages if needed
    for (1..pages_needed) |_| {
        _ = pmm.pmm_alloc() orelse {
            // Cleanup on failure
            for (0..pages_needed - 1) |_| {
                if (current_ptr) |p| pmm.pmm_free(p);
            }
            return null;
        };
    }

    return first_page;
}

/// Kernel malloc with zero fill
pub fn kmalloc_zero(size: usize) ?*anyopaque {
    if (kmalloc(size)) |ptr| {
        @memset(@as([*]u8, @ptrCast(ptr))[0..size], 0);
        return ptr;
    }
    return null;
}

/// Kernel free
pub fn kfree(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        pmm.pmm_free(p);
    }
}
