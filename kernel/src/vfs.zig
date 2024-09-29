const std = @import("std");
const lmfs = @import("vfs/lmfs.zig");
const uartfs = @import("vfs/uartfs.zig");

pub const Driver = enum(usize) {
    limine,
    uart,
};

pub const File = union(Driver) {
    limine: lmfs.File,
    uart: void,
};

pub fn open(path: []const u8) ?File {
    if (std.mem.eql(u8, path, "/dev/tty")) {
        return .{ .uart = {} };
    }

    if (std.mem.startsWith(u8, path, "//usr/")) {
        if (lmfs.open(path)) |file| {
            return .{ .limine = file };
        } else {
            return null;
        }
    }

    return null;
}

pub fn read(file: File, dst: []u8) u64 {
    return switch (file) {
        .uart => |_| uartfs.read(dst),
        .limine => |_| unreachable,
    };
}

pub fn write(file: File, src: []const u8) u64 {
    return switch (file) {
        .uart => |_| uartfs.write(src),
        .limine => |_| unreachable,
    };
}
