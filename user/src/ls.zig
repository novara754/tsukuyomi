const std = @import("std");
const lib = @import("lib.zig");

var entries: [64]lib.DirEntry = undefined;

export fn _start() noreturn {
    const dir = lib.open("/BOOT", lib.O_RDONLY);
    if (dir < 0) {
        @panic("failed to open /BOOT");
    }

    var count = entries.len;
    while (count == entries.len) {
        count = lib.getdirents(dir, &entries, entries.len);
        for (entries[0..count]) |entry| {
            const name_len = std.mem.indexOfScalar(u8, &entry.name, 0) orelse entry.name.len;
            _ = lib.write(lib.STDERR_FILENO, &entry.name, name_len);
            _ = lib.write(lib.STDERR_FILENO, "\n", 1);
        }
    }
    lib._exit(0);
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    lib._exit(200);
}
