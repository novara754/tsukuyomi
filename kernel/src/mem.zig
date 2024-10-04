//! This module contains function for working with
//! - paging
//! - physical and virtual
//! - a page allocator

const limine = @import("limine.zig");
const uart = @import("uart.zig");
const panic = @import("panic.zig").panic;
const Spinlock = @import("Spinlock.zig");
const x86 = @import("x86.zig");

/// Size of page in bytes
pub const PAGE_SIZE: usize = 4096;

/// The kernel has full access to all physical memory using offset mapping.
/// The limine bootloader maps al physical memory such that `virt = offset + phys`.
/// After booting the kernel asks limine what the offset is and stores it in this variable
/// through `init`.
/// This constant is used by the `p2v` and `v2p` functions.
var PHYS_MEM_OFFSET: usize = 0;

/// Helper function to read `PHYS_MEM_OFFSET` and checking that its set.
pub fn physMemOffset() usize {
    if (PHYS_MEM_OFFSET == 0) {
        @panic("PHYS_MEM_OFFSET not initialized");
    }
    return PHYS_MEM_OFFSET;
}

/// Translate a physical address to a virtual address the kernel can use to
/// access the memory. Only the kernel can use the pointer returned by this function.
pub fn p2v(phys: usize) *anyopaque {
    return @ptrFromInt(phys + physMemOffset());
}

/// Translate a virtual address into the corresponding physical
/// address.
/// It is important to note that this only works for virtual addresses beyond `PHYS_MEM_OFFSET`,
/// i.e. addresses that were mapping as part of the offset mapping.
pub fn v2p(ptr: *const anyopaque) usize {
    const addr = @intFromPtr(ptr);
    if (addr < physMemOffset()) {
        panic("v2p called with invalid addr: {x}", .{ptr});
    } else {
        return addr - physMemOffset();
    }
}

/// A pointer to the top-level page table the bootloader created for the kernel.
/// This page-table only maps virtual address that are important for the kernel to run, as such
/// it as basically "as clean as it can get".
/// New page tables (such as for user processes) can then be created based on this.
var KERNEL_PML4: *const PageTable = undefined;

/// Initialize the memory management module (this module).
pub fn init(
    /// Physical memory offset used for offset mapping by the bootloader
    phys_mem_offset_: usize,
    /// Memory map used to initialize the page allocator
    memory_map: *const limine.MemoryMapResponse,
) void {
    @atomicStore(usize, &PHYS_MEM_OFFSET, phys_mem_offset_, .seq_cst);

    for (memory_map.entries[0..memory_map.entry_count]) |entry| {
        if (entry.ty != limine.MemoryMapEntryType.usable) {
            continue;
        }
        var page = entry.base;
        const end = entry.base + entry.length;
        while (page < end) : (page += PAGE_SIZE) {
            PAGE_ALLOCATOR.free(@alignCast(p2v(page)));
        }
    }

    KERNEL_PML4 = @alignCast(@ptrCast(p2v(x86.readCR3().page_table)));
}

/// Create a copy of the `KERNEL_PML4` page table.
pub fn createPML4() *PageTable {
    const new_pml4: *PageTable = @ptrCast(PAGE_ALLOCATOR.alloc());
    new_pml4.* = KERNEL_PML4.*;
    return new_pml4;
}

/// Activate the given page table
pub fn setPML4(
    /// Physical address of the new page table to use
    pml4_phys: u64,
) void {
    const flags = x86.readCR3().flags;
    x86.writeCR3(pml4_phys, flags);
}

/// Set the active page table to be the "clean" kernel page table (`KERNEL_PML4`)
pub fn restoreKernelPML4() void {
    setPML4(v2p(KERNEL_PML4));
}

/// The page allocator allows allocating and freeing physical pages.
/// This is the basis for all memory allocation in the OS.
const PageAllocator = struct {
    lock: Spinlock = Spinlock{},
    root_node: ?*align(PAGE_SIZE) Node = null,

    const Self = @This();

    const Node = struct {
        next: ?*align(PAGE_SIZE) Node,
    };

    /// Allocate a new physical page and return a pointer to it based on offset mapping.
    /// The pointer returned is only usable by the kernel.
    pub fn alloc(self: *Self) *align(PAGE_SIZE) anyopaque {
        self.lock.acquire();
        defer self.lock.release();

        if (self.root_node) |node| {
            self.root_node = node.next;
            return @ptrCast(node);
        } else {
            @panic("PageAllocator.alloc: out of memory");
        }
    }

    /// Like `PageAllocator.alloc` but also zeroes the entire page.
    /// Useful for things like allocating a new empty page table.
    pub fn allocZeroed(self: *Self) *align(PAGE_SIZE) anyopaque {
        const ret = self.alloc();
        const page: *[PAGE_SIZE]u8 = @ptrCast(ret);
        page.* = [1]u8{0} ** PAGE_SIZE;
        return ret;
    }

    /// Free the page identified by the given pointer.
    /// Only valid if the pointer was previously returned by `PageAllocator.alloc` or
    /// `PageAllocator.allocZeroed`.
    pub fn free(self: *Self, page: *align(PAGE_SIZE) anyopaque) void {
        self.lock.acquire();
        defer self.lock.release();

        var node: *align(PAGE_SIZE) Node = @ptrCast(page);
        node.next = self.root_node;
        self.root_node = node;
    }

    /// Count and return the number of free pages.
    pub fn countFree(self: *Self) usize {
        self.lock.acquire();
        defer self.lock.release();

        var count: usize = 0;
        var node = self.root_node;
        while (node) |n| : (node = n.next) {
            count += 1;
        }
        return count;
    }
};

/// Singleton for the page allocator.
pub var PAGE_ALLOCATOR = PageAllocator{};

/// Page table entry flag: Present
/// Signifies whether the given entry is valid
const PTE_P = 1 << 0;
/// Page table entry flag: Readable & Writeable
const PTE_RW = 1 << 1;
/// Page table entry flag: User
/// Signifies whether the given entry is valid in user mode
const PTE_US = 1 << 2;
/// Page table entry flag: Page Size
/// In PDPT entry: entry points to 1 GiB page
/// In PD entry: entry points to 2 MiB page
const PTE_PS = 1 << 7;

/// Represents a single page table entry.
const PageTableEntry = extern struct {
    raw: u64,

    const Self = @This();

    /// Create a new entry from the given physical address and flags.
    /// Address must be page aligned.
    fn pack(addr: u64, flags: u64) PageTableEntry {
        return .{ .raw = addr | flags };
    }

    /// Get the physical address of the page pointed to by this page table entry.
    pub fn frame(self: *const Self) u64 {
        return self.raw & 0o777_777_777_777_0000;
    }

    /// Get the Present flag
    pub fn present(self: *const Self) bool {
        return self.raw & PTE_P != 0;
    }

    /// Get the Page Size flag
    pub fn pageSize(self: *const Self) bool {
        return self.raw & PTE_PS != 0;
    }
};

/// Represents a page table.
/// 512 64-bit entries = 4 KiB, a page table takes up one page.
pub const PageTable = [512]PageTableEntry;

/// Enumeration of possible page sizes.
/// Returned by `Mapper.translate` function.
pub const PageSize = enum {
    _4KiB,
    _2MiB,
    _1GiB,
};

/// Enumeration of page access levels.
/// Used by `Mapper.map` function.
pub const PageAccess = enum {
    kernel,
    user,
};

/// Enumeration of mapping modes.
/// Used by `Mapper.map` function.
pub const MapMode = enum {
    panic,
    overwrite,
};

/// Wraps a page table to provide function for adding new
/// address mappings and translating arbitrary virtual addresses to physical addresses.
pub const Mapper = struct {
    pml4: *PageTable,

    const Self = @This();

    /// Creates a `Mapper` for the currently active page table.
    pub fn forCurrentPML4() Self {
        const cr3 = x86.readCR3();
        return .{
            .pml4 = @alignCast(@ptrCast(p2v(cr3.page_table))),
        };
    }

    /// Create a `Mapper` for the given top-level page table.
    pub fn forPML4(pml4: *PageTable) Self {
        return .{ .pml4 = pml4 };
    }

    /// Walk the page table hierarchy to translate the given virtual address into
    /// a physical address.
    /// Also returns the size of the page.
    pub fn translate(self: *const Self, virt: u64) ?struct { phys: u64, size: PageSize } {
        const pml4_entry = &self.pml4[pml4Index(virt)];
        if (!pml4_entry.present()) {
            return null;
        }

        const pdpt: *PageTable = @alignCast(@ptrCast(p2v(pml4_entry.frame())));
        const pdpt_entry = &pdpt[pdptIndex(virt)];
        if (!pdpt_entry.present()) {
            return null;
        }

        if (pdpt_entry.pageSize()) {
            return .{
                .phys = pdpt_entry.frame() + hugePageOffset(virt),
                .size = PageSize._1GiB,
            };
        }

        const pd: *PageTable = @alignCast(@ptrCast(p2v(pdpt_entry.frame())));
        const pd_entry = &pd[pdIndex(virt)];
        if (!pd_entry.present()) {
            return null;
        }

        if (pd_entry.pageSize()) {
            return .{
                .phys = pd_entry.frame() + largePageOffset(virt),
                .size = PageSize._2MiB,
            };
        }

        const pt: *PageTable = @alignCast(@ptrCast(p2v(pd_entry.frame())));
        const pt_entry = &pt[ptIndex(virt)];
        if (!pt_entry.present()) {
            return null;
        }

        return .{
            .phys = pt_entry.frame() + basePageOffset(virt),
            .size = PageSize._4KiB,
        };
    }

    /// Add a mapping for the given (virt, phys) pair to the page table hierarchy.
    /// Allocates new page tables if necessary.
    pub fn map(
        self: *Self,
        virt: u64,
        phys: u64,
        /// `.kernel`: mapping is only valid in kernel mode
        /// `.user`: mapping is also valid in user mode
        access: PageAccess,
        /// `.panic`: if virtual address is already mapped, panic
        /// `.overwrite`: if virtual address is already mapped simply overwrite (does not free)
        mode: MapMode,
    ) void {
        if (!isBasePageAligned(virt)) {
            panic("Mapper.map: `virt` is not page aligned (virt = {x})", .{virt});
        }

        if (!isBasePageAligned(phys)) {
            panic("Mapper.map: `phys` is not page aligned (phys = {x})", .{phys});
        }

        const flags: u64 = if (access == .user) (PTE_P | PTE_RW | PTE_US) else (PTE_P | PTE_RW);

        const pml4_entry = &self.pml4[pml4Index(virt)];
        if (!pml4_entry.present()) {
            const pdpt = v2p(PAGE_ALLOCATOR.allocZeroed());
            pml4_entry.* = PageTableEntry.pack(pdpt, flags);
        }

        const pdpt: *PageTable = @alignCast(@ptrCast(p2v(pml4_entry.frame())));
        const pdpt_entry = &pdpt[pdptIndex(virt)];
        if (!pdpt_entry.present()) {
            const pd = v2p(PAGE_ALLOCATOR.allocZeroed());
            pdpt_entry.* = PageTableEntry.pack(pd, flags);
        }

        const pd: *PageTable = @alignCast(@ptrCast(p2v(pdpt_entry.frame())));
        const pd_entry = &pd[pdIndex(virt)];
        if (!pd_entry.present()) {
            const pt = v2p(PAGE_ALLOCATOR.allocZeroed());
            pd_entry.* = PageTableEntry.pack(pt, flags);
        }

        const pt: *PageTable = @alignCast(@ptrCast(p2v(pd_entry.frame())));
        const pt_entry = &pt[ptIndex(virt)];
        if (pt_entry.present() and mode == .panic) {
            panic("Mapper.map: `virt` is in use (virt = {x})", .{virt});
        }

        pt_entry.* = PageTableEntry.pack(phys, flags);

        asm volatile ("invlpg (%rax)"
            :
            : [addr] "{rax}" (virt),
        );
    }
};

pub fn isBasePageAligned(addr: u64) bool {
    return addr % PAGE_SIZE == 0;
}

fn pml4Index(virt: u64) usize {
    return @intCast((virt >> 39) & 0o777);
}

fn pdptIndex(virt: u64) usize {
    return @intCast((virt >> 30) & 0o777);
}

fn pdIndex(virt: u64) usize {
    return @intCast((virt >> 21) & 0o777);
}

fn ptIndex(virt: u64) usize {
    return @intCast((virt >> 12) & 0o777);
}

fn basePageOffset(virt: u64) usize {
    return @intCast(virt & 0o7777);
}

fn largePageOffset(virt: u64) usize {
    return @intCast(virt & 0o777_7777);
}

fn hugePageOffset(virt: u64) usize {
    return @intCast(virt & 0o777_777_7777);
}
