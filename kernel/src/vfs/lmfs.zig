const std = @import("std");
const limine = @import("../limine.zig");
const Spinlock = @import("../Spinlock.zig");

pub const File = struct {
    ref: *const limine.File,
    offset: u64 = 0,
};

var LOCK = Spinlock{};
var FILE_COUNT: usize = 0;
var FILES = [1]?*const limine.File{null} ** 16;

pub fn registerFile(file: *const limine.File) !void {
    LOCK.acquire();
    defer LOCK.release();

    if (FILE_COUNT == FILES.len) {
        return error.TooManyFiles;
    }

    FILES[FILE_COUNT] = file;
    FILE_COUNT += 1;
}

pub fn open(path: []const u8) ?File {
    LOCK.acquire();
    defer LOCK.release();

    for (FILES[0..FILE_COUNT]) |file| {
        if (file) |f| {
            if (std.mem.eql(u8, path, f.path_slice())) {
                return .{ .ref = f };
            }
        }
    }

    return null;
}
