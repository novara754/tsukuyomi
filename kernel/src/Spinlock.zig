//! Spinlock

const x86 = @import("x86.zig");

locked: bool = false,
disabledInterrupts: bool = false,

const Self = @This();

/// Acquire the lock. If the lock is currently held this will enter a spin loop
/// until the lock can be acquired.
pub fn acquire(self: *Self) void {
    // TODO: would be nice to remove this in the future and handle
    // deadlocks in a way that wouldnt require turning off interrupts
    // completely
    if (x86.interruptsEnabled()) {
        self.disabledInterrupts = true;
        x86.cli();
    } else {
        self.disabledInterrupts = false;
    }
    while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) {
        x86.pause();
    }
}

/// Release the lock.
pub fn release(self: *Self) void {
    @atomicStore(bool, &self.locked, false, .release);
    if (self.disabledInterrupts) {
        x86.sti();
    }
}
