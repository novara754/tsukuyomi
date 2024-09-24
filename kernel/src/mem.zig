const limine = @import("limine.zig");
const uart = @import("uart.zig");
const Spinlock = @import("Spinlock.zig");

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
}

const PageAllocator = struct {
    lock: Spinlock = Spinlock{},
    root_node: ?*Node = null,

    const Self = @This();

    const Node = struct {
        next: ?*Node,
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

    pub fn free(self: *Self, page: *align(PAGE_SIZE) anyopaque) void {
        self.lock.acquire();
        defer self.lock.release();

        var node: *Node = @ptrCast(page);
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
