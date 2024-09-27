const Spinlock = @import("../Spinlock.zig");
const panic = @import("../panic.zig").panic;
const irq = @import("irq.zig");

/// ID Register
const ID: u64 = 0x0020;

/// Version Register
const VER: u64 = 0x0030;

/// Task Priority Register
const TPR: u64 = 0x0080;

/// EOI Register
const EOI: u64 = 0x00B0;

/// Spurious Interrupt Vector Register
const SVR: u64 = 0x00F0;
/// Unit Enable
const SVR_ENABLE: u32 = (1 << 8);

/// Error Status Register
const ESR: u64 = 0x0280;

/// Interrupt Command Register
const ICRLO: u64 = 0x0300;
/// INIT/RESET
const ICR_INIT: u32 = 0x5 << 8;
/// Startup IPI
const ICR_STARTUP: u32 = 0x6 << 8;
/// Delivery status
const ICR_DELIVS: u32 = 1 << 12;
/// Assert interrupt
const ICR_ASSERT: u32 = 1 << 14;
/// Level triggered
const ICR_LEVEL: u32 = 1 << 15;
/// Broadcast to all APICs
const ICR_BROADCAST: u32 = 1 << 19;

/// Interrupt Command [63:32] Register
const ICRHI: u64 = 0x0310;

/// Local Vector Table 0 (TIMER) Register
const TIMER: u64 = 0x0320;
/// Periodic
const TIMER_PERIODIC: u32 = 1 << 17;

/// Performance Counter LVT Register
const PCINT: u64 = 0x0340;

/// Local Vector Table 1 (LINT0) Register
const LINT0: u64 = 0x0350;

/// Local Vector Table 2 (LINT1) Register
const LINT1: u64 = 0x0360;

/// Local Vector Table 3 (ERROR) Register
const ERROR: u64 = 0x0370;

/// Timer Initial Count Register
const TICR: u64 = 0x0380;

/// Timer Current Count Register
const TCCR: u64 = 0x0390;

/// Timer Divide Configuration Register
const TDCR: u64 = 0x03E0;
/// Timer Divide by 1
const TDCR_1: u32 = 0xB;

/// Interrupt masked
const INT_MASKED: u32 = 1 << 16;

const Lapic = struct {
    base: ?[*]volatile u32 = null,
    lock: Spinlock = Spinlock{},

    const Self = @This();

    pub fn id(self: *Self) u32 {
        return self.read(ID);
    }

    pub fn eoi(self: *Self) void {
        self.write(EOI, 0);
    }

    fn write(self: *Self, reg: u64, data: u32) void {
        const base = self.base orelse panic("Lapic.write: not initialized", .{});

        self.lock.acquire();
        defer self.lock.release();

        base[reg / @sizeOf(u32)] = data;
    }

    fn read(self: *Self, reg: u64) u32 {
        const base = self.base orelse panic("Lapic.write: not initialized", .{});

        self.lock.acquire();
        defer self.lock.release();

        return base[reg / @sizeOf(u32)];
    }
};

var LAPIC = Lapic{};

/// # Safety
///
/// `base_addr` must be the valid base address of the lapic memory IO region.
pub fn init(base_ptr: [*]u32) void {
    LAPIC.lock.acquire();
    LAPIC.base = base_ptr;
    LAPIC.lock.release();

    // Enable LAPIC and set spurious interrupt vector
    LAPIC.write(SVR, SVR_ENABLE | (irq.OFFSET + irq.SPURIOUS));

    // Timer repeatedly counts down at frequency in TICR
    // LAPIC.write(TDCR, TDCR_1);
    // LAPIC.write(TIMER, TIMER_PERIODIC | (irq.OFFSET + irq.TIMER));
    // LAPIC.write(TICR, 10000000);

    // Disable LVTs
    LAPIC.write(LINT0, INT_MASKED);
    LAPIC.write(LINT1, INT_MASKED);

    // Disable performance counter overflow interrupts
    // on machines that provide that interrupt entry
    if (((LAPIC.read(VER) >> 16) & 0xFF) >= 4) {
        LAPIC.write(PCINT, INT_MASKED);
    }

    // Set error interrupt vector
    LAPIC.write(ERROR, irq.OFFSET + irq.ERROR);

    // Clear error status which requires two writes
    LAPIC.write(ESR, 0);
    LAPIC.write(ESR, 0);

    // Clear any outstanding interrupts that have happened by now
    LAPIC.write(EOI, 0);

    // Send an Init Level De-Assert to synchronise arbitration ID's.
    // ???
    LAPIC.write(ICRHI, 0);
    LAPIC.write(ICRLO, ICR_BROADCAST | ICR_INIT | ICR_LEVEL);
    while (LAPIC.read(ICRLO) & ICR_DELIVS != 0) {}

    // Enable interrupts on the APIC.
    // This does not enable them on the processor
    LAPIC.write(TPR, 0);
}

pub fn eoi() void {
    LAPIC.eoi();
}

pub fn id() u32 {
    return LAPIC.id();
}
