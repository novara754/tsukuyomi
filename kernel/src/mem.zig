const limine = @import("limine.zig");
const uart = @import("uart.zig");
const panic = @import("panic.zig").panic;
const Spinlock = @import("Spinlock.zig");
const x86 = @import("x86.zig");

pub const PAGE_SIZE: usize = 4096;

var PHYS_MEM_OFFSET: usize = 0;

pub fn phys_mem_offset() usize {
    if (PHYS_MEM_OFFSET == 0) {
        @panic("g_phys_mem_offset not initialized");
    }
    return PHYS_MEM_OFFSET;
}

pub fn p2v(phys: usize) *anyopaque {
    return @ptrFromInt(phys + phys_mem_offset());
}

pub fn v2p(ptr: *const anyopaque) usize {
    return @intFromPtr(ptr) - phys_mem_offset();
}

var KERNEL_PML4: *const PageTable = undefined;

pub fn init(phys_mem_offset_: usize, memory_map: *const limine.MemoryMapResponse) void {
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

pub fn createPML4() *PageTable {
    const new_pml4: *PageTable = @ptrCast(PAGE_ALLOCATOR.alloc());
    new_pml4.* = KERNEL_PML4.*;
    return new_pml4;
}

pub fn setPML4(pml4_phys: u64) void {
    const flags = x86.readCR3().flags;
    x86.writeCR3(pml4_phys, flags);
}

pub fn restoreKernelPML4() void {
    setPML4(v2p(KERNEL_PML4));
}

const PageAllocator = struct {
    lock: Spinlock = Spinlock{},
    root_node: ?*align(PAGE_SIZE) Node = null,

    const Self = @This();

    const Node = struct {
        next: ?*align(PAGE_SIZE) Node,
    };

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

    pub fn allocZeroed(self: *Self) *align(PAGE_SIZE) anyopaque {
        const ret = self.alloc();
        const page: *[PAGE_SIZE]u8 = @ptrCast(ret);
        page.* = [1]u8{0} ** PAGE_SIZE;
        return ret;
    }

    pub fn free(self: *Self, page: *align(PAGE_SIZE) anyopaque) void {
        self.lock.acquire();
        defer self.lock.release();

        var node: *align(PAGE_SIZE) Node = @ptrCast(page);
        node.next = self.root_node;
        self.root_node = node;
    }

    pub fn count_free(self: *Self) usize {
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

pub var PAGE_ALLOCATOR = PageAllocator{};

const PTE_P = 1 << 0;
const PTE_RW = 1 << 1;
const PTE_US = 1 << 2;
const PTE_PS = 1 << 7;

const PageTableEntry = extern struct {
    raw: u64,

    const Self = @This();

    fn pack(addr: u64, flags: u64) PageTableEntry {
        return .{ .raw = addr | flags };
    }

    pub fn frame(self: *const Self) u64 {
        return self.raw & 0o777_777_777_777_0000;
    }

    pub fn present(self: *const Self) bool {
        return self.raw & PTE_P != 0;
    }

    pub fn pageSize(self: *const Self) bool {
        return self.raw & PTE_PS != 0;
    }
};

pub const PageTable = [512]PageTableEntry;

pub const PageSize = enum {
    _4KiB,
    _2MiB,
    _1GiB,
};

pub const Mapper = struct {
    pml4: *PageTable,

    const Self = @This();

    pub fn forCurrentPML4() Self {
        const cr3 = x86.readCR3();
        return .{
            .pml4 = @alignCast(@ptrCast(p2v(cr3.page_table))),
        };
    }

    pub fn forPML4(pml4: *PageTable) Self {
        return .{ .pml4 = pml4 };
    }

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

    pub fn map(self: *Self, virt: u64, phys: u64, is_user: bool) void {
        if (!isBasePageAligned(virt)) {
            panic("Mapper.map: `virt` is not page aligned (virt = {x})", .{virt});
        }

        if (!isBasePageAligned(phys)) {
            panic("Mapper.map: `phys` is not page aligned (phys = {x})", .{phys});
        }

        const flags: u64 = if (is_user) (PTE_P | PTE_RW | PTE_US) else (PTE_P | PTE_RW);

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
        if (pt_entry.present()) {
            panic("Mapper.map: `virt` is in use (virt = {x})", .{virt});
        }

        pt_entry.* = PageTableEntry.pack(phys, flags);

        asm volatile ("invlpg (%rax)"
            :
            : [addr] "{rax}" (virt),
        );
    }
};

fn isBasePageAligned(addr: u64) bool {
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
