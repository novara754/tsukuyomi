//! The virtual file system (VFS) unifies different actual filesystem implementations.
//!
//! So far no persistent filesystem has been implemented, however the serial port
//! as well as modules loaded by the limine bootloader are exposed as files
//! to be read by processes.
//! `vfs/lmfs.zig` and `vfs/tty.zig` contain the relevant implementations.
//!
//! The VFS dispatches to the appropriate filesystem driver based on parts of the filepath
//! or the given file reference.
//! Currently this is all hardcoded to provide some basic functionality.
//!
//! Currently supported operations are:
//! - open
//! - read
//! - write

const std = @import("std");
const lmfs = @import("vfs/lmfs.zig");
const tty = @import("vfs/tty.zig");
const fat16 = @import("vfs/fat16.zig");
const gpt = @import("fs/gpt.zig");
const ata = @import("ata.zig");

/// Enumeration of available filesystem drivers.
/// This is used as the discriminant for the `File` type which is a union
/// containing the necessary data for operating on files for the corresponding filesystem.
pub const Driver = enum(usize) {
    limine,
    tty,
    fat16,
};

/// Basic file handle which contains metadata required for the corresponding filesystem
/// drivers.
/// Process file descriptors are mapped to these handles.
pub const File = union(Driver) {
    limine: lmfs.File,
    tty: void,
    fat16: fat16.File,
};

pub const DirEntry = extern struct {
    name: [256:0]u8,
};

var FAT16_DRIVER: fat16.Driver(gpt.PartitionBlockDevice(ata.BlockDevice)) = .{};

pub fn init(fat16_block_device: gpt.PartitionBlockDevice(ata.BlockDevice)) !void {
    try FAT16_DRIVER.init(fat16_block_device, @import("heap.zig").allocator());
}

pub fn open(path: []const u8) ?File {
    if (std.mem.eql(u8, path, "/dev/tty")) {
        return .{ .tty = {} };
    }

    if (std.mem.startsWith(u8, path, "//usr/")) {
        if (lmfs.open(path)) |file| {
            return .{ .limine = file };
        } else {
            return null;
        }
    }

    if (FAT16_DRIVER.open(path)) |file| {
        return .{ .fat16 = file };
    } else |_| {
        return null;
    }
}

pub fn read(file: File, dst: []u8) u64 {
    return switch (file) {
        .tty => |_| tty.read(dst),
        .limine => |_| unreachable,
        .fat16 => |_| unreachable,
    };
}

pub fn write(file: File, src: []const u8) u64 {
    return switch (file) {
        .tty => |_| tty.write(src),
        .limine => |_| unreachable,
        .fat16 => |_| unreachable,
    };
}

pub fn getdirents(file: File, entries: []DirEntry) !usize {
    return switch (file) {
        .tty => |_| unreachable,
        .limine => |_| unreachable,
        .fat16 => |f| FAT16_DRIVER.getdirents(f, entries),
    };
}
