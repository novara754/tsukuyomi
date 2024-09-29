const std = @import("std");
const lib = @import("lib.zig");

export fn _start() noreturn {
    const message = "HELLO WORLD!\n";
    lib._exit(@intCast(lib.write(lib.STDOUT_FILENO, message, message.len)));
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    lib._exit(200);
}
