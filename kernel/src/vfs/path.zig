//! Miscellaneous functions for working with filepaths
//!
//! An absolute path is a path that starts with the `SEPARATOR`.
//! For example `/efi/boot/bootx64.efi` is an absolute path but `hello/world.txt` is not.
//!
//! Relative paths are paths that are not absolute. A relative path can be resolved into
//! an absolute path by specifying a "starting point", i.e. an absolute path from which to
//! start the relative path.
//! The relative path `hello/world.txt` can be resolved with `/root` into the absolute path
//! `/root/hello/world.txt`.
//!
//! Paths are allowed to have a trailing `SEPARATOR` if they identify a directory.

const std = @import("std");
const panic = @import("../panic.zig").panic;

pub const MAX_PATH_LEN = 256;

pub const SEPARATOR = '/';

pub fn isAbsolute(path: []const u8) bool {
    return path[0] == SEPARATOR;
}

/// Turn the relative path `rel` into an absolute path by using `base` as the starting point.
/// Panics if `base` is not an absolute path.
/// Panics if `rel` is not a relative path.
/// Fails if `buf` is not big enough.
pub fn resolve(buf: []u8, base: []const u8, rel: []const u8) ![]const u8 {
    if (!isAbsolute(base)) {
        panic("path.resolve: `base` is not an absolute path", .{});
    }

    if (isAbsolute(rel)) {
        panic("path.resolve: `rel` is not a relative path", .{});
    }

    if (std.mem.eql(u8, rel, ".")) {
        return base;
    }

    return concat(buf, base, rel);
}

/// Concatenate two paths.
/// `left` is allowed to end with `SEPARATOR`.
/// `right` is allowed to start with `SEPARATOR`.
/// Fails if `buf` is not big enough.
pub fn concat(buf: []u8, left: []const u8, right: []const u8) ![]const u8 {
    var left_clean = left;
    var right_clean = right;

    if (left_clean[left_clean.len - 1] == SEPARATOR) left_clean = left_clean[0 .. left_clean.len - 1];
    if (right_clean[0] == SEPARATOR) right_clean = right_clean[1..];

    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ left_clean, SEPARATOR, right_clean });
}

test concat {
    const expectEqualStrings = std.testing.expectEqualStrings;

    var buf: [MAX_PATH_LEN]u8 = undefined;
    try expectEqualStrings("a/b/c", try concat(&buf, "a/b", "c"));
    try expectEqualStrings("a/b/c", try concat(&buf, "a/b/", "c"));
    try expectEqualStrings("a/b/c", try concat(&buf, "a/b", "/c"));
    try expectEqualStrings("a/b/c", try concat(&buf, "a/b/", "/c"));
    try expectEqualStrings("/a/b/c", try concat(&buf, "/a/b", "c"));
    try expectEqualStrings("/a/b/c", try concat(&buf, "/a/b/", "c"));
    try expectEqualStrings("/a/b/c", try concat(&buf, "/a/b", "/c"));
    try expectEqualStrings("/a/b/c", try concat(&buf, "/a/b/", "/c"));
}

test resolve {
    const expectEqualStrings = std.testing.expectEqualStrings;

    var buf: [MAX_PATH_LEN]u8 = undefined;
    try expectEqualStrings("/a/b/c", try resolve(&buf, "/a/b", "c"));
    try expectEqualStrings("/a/b/c", try resolve(&buf, "/a/b/", "c"));
}
