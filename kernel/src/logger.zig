const uart = @import("uart.zig");

pub const Level = enum {
    err,
    warn,
    info,
    debug,
};

pub const Config = struct {
    /// Any logs with a level below this will not be displayed.
    /// Order: .err < .warn < .info < .debug
    maxLevel: Level = .debug,
    /// If true logs with `.info` level will be dimmed, this can make it easier to see
    /// error, warning and debug logs.
    dimInfo: bool = true,
};

var CONFIG: Config = .{};

/// Modify behaviour for future logs.
pub fn configure(config: Config) void {
    CONFIG = config;
}

/// Logs will be sent to UART1.
pub fn log(comptime level: Level, comptime tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(CONFIG.maxLevel)) {
        return;
    }

    if (level == .info and CONFIG.dimInfo) {
        uart.print("\x1b[2m", .{});
    }

    const levelColor = switch (level) {
        .debug => "\x1b[36m",
        .info => "\x1b[32m",
        .warn => "\x1b[33m",
        .err => "\x1b[31m",
    };
    uart.print("[{s}{s:<5}\x1b[39m] [\x1b[35m{s:<8}\x1b[39m] ", .{ levelColor, @tagName(level), tag });
    uart.print(fmt ++ "\n", args);

    if (level == .info and CONFIG.dimInfo) {
        uart.print("\x1b[22m", .{});
    }
}
