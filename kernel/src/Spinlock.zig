const x86 = @import("x86.zig");

locked: bool = false,

const Self = @This();

pub fn acquire(self: *Self) void {
    while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) {
        x86.spin();
    }
}

pub fn release(self: *Self) void {
    @atomicStore(bool, &self.locked, false, .release);
}
