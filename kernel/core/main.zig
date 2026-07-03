//! Sinux Kernel Main Entry Point (Zig Edition)
//! This replaces kernel/core/main.c with type-safe Zig

const std = @import("std");
const string = @import("lib_string");
const printk = @import("lib_printk");
const errno = @import("lib_errno");

// Multiboot2 structures
pub const MultibootHeader = extern struct {
    magic: u32,
    arch: u32,
    header_length: u32,
    checksum: u32,
};

pub const MultibootInfo = extern struct {
    size: u32,
    reserved: u32,
};

// Forward declarations for arch-specific functions
extern fn gdt_init() void;
extern fn idt_init() void;
extern fn pic_init() void;
extern fn pit_init() void;
extern fn keyboard_init() void;
extern fn pmm_init(magic: u32, info: u64) void;
extern fn vmm_init() void;
extern fn bga_init(width: u32, height: u32, bpp: u8) u32;
extern fn bga_fb_phys_addr() u64;
extern fn vmm_map_range(pml4: u64, virt: u64, phys: u64, size: u64, flags: u32) void;
extern fn vfs_init() void;
extern fn ramfs_mount(path: [*:0]const u8) void;
extern fn procfs_mount(path: [*:0]const u8) void;
extern fn tty_init() void;
extern fn tty_dev_init() void;
extern fn tty_setcolor_info() void;
extern fn tty_setcolor_reset() void;
extern fn tty_puts(s: [*:0]const u8) void;
extern fn fb_init() void;
extern fn ata_init() void;
extern fn proc_init() void;
extern fn sched_init() void;
extern fn syscall_init() void;
extern fn proc_spawn_init() i32;

const PAGE_SIZE = 0x1000;
const VMM_PRESENT = 1;
const VMM_WRITABLE = 2;

var cwd: [256]u8 = [_]u8{0} ** 256;
var g_mb2_magic: u32 = 0;
var g_mb2_info: u64 = 0;

pub export fn kernel_main(mb2_magic: u32, mb2_info: u64) void {
    g_mb2_magic = mb2_magic;
    g_mb2_info = mb2_info;

    // Stage 1: Initialize CPU and memory
    gdt_init();
    idt_init();
    pic_init();
    pit_init();
    keyboard_init();
    pmm_init(mb2_magic, mb2_info);
    vmm_init();

    // Stage 2: Graphics setup
    if (bga_init(1024, 768, 32) == 0) {
        const fb_phys = bga_fb_phys_addr();
        vmm_map_range(
            vmm_kernel_pml4(),
            fb_phys,
            fb_phys,
            1024 * 768 * 4,
            VMM_PRESENT | VMM_WRITABLE,
        );
        fb_init();
    }

    tty_init();

    // Stage 3: Filesystem and subsystems
    vfs_init();
    ramfs_mount("/");
    procfs_mount("/proc");
    tty_dev_init();
    proc_init();
    sched_init();
    syscall_init();

    ata_init();

    // Create filesystem directories
    vfs_create("/root", 1);
    vfs_create("/home", 1);
    vfs_create("/etc", 1);
    vfs_create("/tmp", 1);
    vfs_create("/bin", 1);
    vfs_create("/lib", 1);
    vfs_create("/usr", 1);

    _ = string.strcpy(@ptrCast(&cwd), "/root");

    // Enable interrupts
    asm volatile ("sti");

    // Print banner
    tty_setcolor_info();
    tty_puts(
        "############################################\n" ++
        "#                  Sinux                  #\n" ++
        "#    Made By SUN (Sinux Users Network)    #\n" ++
        "############################################\n",
    );
    tty_setcolor_reset();

    // Attempt to spawn init
    if (proc_spawn_init() == 0) {
        while (true) {
            asm volatile ("hlt");
        }
    }

    // Fallback: kernel shell would go here
    while (true) {
        asm volatile ("hlt");
    }
}

// Stub implementations (replace with real ones)
fn vmm_kernel_pml4() u64 {
    return 0;
}

fn vfs_create(path: [*:0]const u8, flags: u32) i32 {
    _ = path;
    _ = flags;
    return 0;
}
