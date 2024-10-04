//! Spinlock

const x86 = @import("x86.zig");

locked: bool = false,

const Self = @This();

/// Acquire the lock. If the lock is currently held this will enter a spin loop
/// until the lock can be acquired.
pub fn acquire(self: *Self) void {
    while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) {
        x86.pause();
    }
}

/// Release the lock.
pub fn release(self: *Self) void {
    @atomicStore(bool, &self.locked, false, .release);
}
