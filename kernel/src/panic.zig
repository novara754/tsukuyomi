const spin = @import("x86.zig").spin;
const uart = @import("uart.zig");

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    asm volatile ("cli");
    uart.print("PANIC: " ++ fmt ++ "\n", args);
    spin();
}
