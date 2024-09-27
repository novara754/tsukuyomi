const irq = @import("irq.zig");

const IOAPICID: u32 = 0;
const IOAPICVER: u32 = 1;

const INT_DISABLED: u32 = 1 << 16;

const IOAPIC = struct {
    ioregsel: *volatile u32,
    ioregwin: *volatile u32,

    const Self = @This();

    fn write(self: *Self, reg: u32, value: u32) void {
        self.ioregsel.* = reg;
        self.ioregwin.* = value;
    }

    fn read(self: *Self, reg: u32) u32 {
        self.ioregsel.* = reg;
        return self.ioregwin.*;
    }
};

pub fn init(base_ptr: [*]u32) void {
    var ioapic = IOAPIC{
        .ioregsel = &base_ptr[0x00],
        .ioregwin = &base_ptr[0x10 / @sizeOf(u32)],
    };

    const max_interrupts = (ioapic.read(IOAPICVER) >> 16) & 0xFF;
    var i: u32 = 0;
    while (i < max_interrupts) : (i += 1) {
        ioapic.write(0x10 + 2 * i, INT_DISABLED | (irq.OFFSET + i));
        ioapic.write(0x10 + 2 * i + 1, 0);
    }
}