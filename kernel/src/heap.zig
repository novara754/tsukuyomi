const std = @import("std");
const mem = @import("mem.zig");
const panic = @import("panic.zig").panic;

const HEAP_START = 0xFFFF_9000_0000_0000;
const HEAP_SIZE = 4 * 1024 * mem.PAGE_SIZE;

var ALLOCATOR: std.heap.FixedBufferAllocator = undefined;

pub fn init() void {
    if (!mem.isBasePageAligned(HEAP_START)) {
        panic("heap.init: HEAP_START is not base page aligned", .{});
    }
    const heap_end = HEAP_START + HEAP_SIZE;
    var mapper = mem.Mapper.forCurrentPML4();
    var addr: u64 = HEAP_START;
    while (addr < heap_end) : (addr += mem.PAGE_SIZE) {
        const frame = mem.v2p(mem.PAGE_ALLOCATOR.alloc());
        mapper.map(addr, frame, .kernel, .panic);
    }

    var heap: [*]u8 = @ptrFromInt(HEAP_START);
    ALLOCATOR = std.heap.FixedBufferAllocator.init(heap[0..HEAP_SIZE]);
}

pub fn allocator() std.mem.Allocator {
    return ALLOCATOR.allocator();
}
