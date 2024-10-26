const std = @import("std");
const vfs = @import("../vfs.zig");
const fat16 = @import("../fs.zig").fat16;
const panic = @import("../panic.zig").panic;

pub const FileKind = enum {
    root_dir,
    file,
};

pub const File = union(FileKind) {
    root_dir: struct {
        offset: usize,
    },
    file: struct {
        first_cluster: u16,
        offset: usize,
        is_dir: bool,
    },
};

pub fn Driver(comptime BlockDevice: type) type {
    return struct {
        allocator: std.mem.Allocator = undefined,
        block_device: BlockDevice = undefined,
        ebpb: *fat16.EBPB = undefined,
        fat: fat16.FAT = undefined,

        const Self = @This();

        pub fn init(self: *Self, block_device: BlockDevice, allocator: std.mem.Allocator) !void {
            self.allocator = allocator;
            self.block_device = block_device;

            self.ebpb = try fat16.readEBPB(block_device, allocator);
            self.fat = try fat16.readFAT(self.ebpb, block_device, allocator);
        }

        pub fn open(self: *Self, path: []const u8) !File {
            if (std.mem.eql(u8, path, "/")) {
                return .{
                    .root_dir = .{
                        .offset = 0,
                    },
                };
            }
            const direntry = try fat16.findFile(path, self.ebpb, self.fat, self.block_device, self.allocator);
            return .{
                .file = .{
                    .first_cluster = direntry.cluster_lo,
                    .offset = 0,
                    .is_dir = direntry.isDir(),
                },
            };
        }

        pub fn getdirents(self: *Self, file: *File, dst: []vfs.DirEntry) !usize {
            switch (file.*) {
                .root_dir => |*f| {
                    const entries = try fat16.readRootDir(self.ebpb, self.block_device, self.allocator);
                    defer self.allocator.free(entries);

                    var i: usize = 0;
                    for (entries[f.offset..]) |entry| {
                        if (entry.thisAndRestEmpty()) break;
                        if (!entry.valid()) continue;
                        if (entry.isVFAT()) continue;
                        if (entry.extension().len == 0) {
                            _ = try std.fmt.bufPrint(&dst[i].name, "{s}", .{entry.filename()});
                        } else {
                            _ = try std.fmt.bufPrint(&dst[i].name, "{s}.{s}", .{ entry.filename(), entry.extension() });
                        }
                        i += 1;
                    }

                    f.offset += i;

                    return i;
                },
                .file => |*f| {
                    if (!f.is_dir) {
                        return error.NotADirectory;
                    }

                    const cluster_offset = f.offset / self.ebpb.bpb.bytesPerCluster();
                    const offset_in_cluster = f.offset % self.ebpb.bpb.bytesPerCluster();

                    var cluster_idx = f.first_cluster;
                    for (0..cluster_offset) |_| {
                        cluster_idx = self.fat[cluster_idx];
                        if (cluster_idx == self.fat[1]) {
                            panic("fat16.Driver.getdirents: file offset is out of range (offset is {})", .{f.offset});
                        }
                    }

                    const cluster = try fat16.readCluster(cluster_idx, self.ebpb, self.block_device, self.allocator);
                    defer self.allocator.free(cluster);

                    const entries: []fat16.DirEntry = @alignCast(std.mem.bytesAsSlice(fat16.DirEntry, cluster[offset_in_cluster..]));

                    var i: usize = 0;
                    for (entries) |entry| {
                        if (entry.thisAndRestEmpty()) break;
                        if (!entry.valid()) continue;
                        if (entry.isVFAT()) continue;
                        if (entry.extension().len == 0) {
                            _ = try std.fmt.bufPrint(&dst[i].name, "{s}", .{entry.filename()});
                        } else {
                            _ = try std.fmt.bufPrint(&dst[i].name, "{s}.{s}", .{ entry.filename(), entry.extension() });
                        }
                        i += 1;
                    }

                    f.offset += self.ebpb.bpb.bytesPerCluster();

                    return i;
                },
            }
        }
    };
}
