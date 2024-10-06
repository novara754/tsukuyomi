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

/// Enumeration of available filesystem drivers.
/// This is used as the discriminant for the `File` type which is a union
/// containing the necessary data for operating on files for the corresponding filesystem.
pub const Driver = enum(usize) {
    limine,
    tty,
};

/// Basic file handle which contains metadata required for the corresponding filesystem
/// drivers.
/// Process file descriptors are mapped to these handles.
pub const File = union(Driver) {
    limine: lmfs.File,
    tty: void,
};

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

    return null;
}

pub fn read(file: File, dst: []u8) u64 {
    return switch (file) {
        .tty => |_| tty.read(dst),
        .limine => |_| unreachable,
    };
}

pub fn write(file: File, src: []const u8) u64 {
    return switch (file) {
        .tty => |_| tty.write(src),
        .limine => |_| unreachable,
    };
}
