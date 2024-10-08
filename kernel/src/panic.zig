const spin = @import("x86.zig").spin;
const logger = @import("logger.zig");

/// Print a formatted message to UART1 and hang.
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    asm volatile ("cli");
    logger.log(.err, "kernel", "panic: " ++ fmt ++ "\n", args);
    spin();
}
