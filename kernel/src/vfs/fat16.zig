const std = @import("std");
const vfs = @import("../vfs.zig");
const fat16 = @import("../fs.zig").fat16;
const panic = @import("../panic.zig").panic;

pub const File = struct {
    first_cluster: u16,
    offset: usize,
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
            const direntry = try fat16.findFile(path, self.ebpb, self.fat, self.block_device, self.allocator);
            return .{
                .first_cluster = direntry.cluster_lo,
                .offset = 0,
            };
        }

        pub fn getdirents(self: *Self, file: File, dst: []vfs.DirEntry) !usize {
            const cluster_offset = file.offset / self.ebpb.bpb.bytesPerCluster();
            const offset_in_cluster = file.offset % self.ebpb.bpb.bytesPerCluster();

            var cluster_idx = file.first_cluster;
            for (0..cluster_offset) |_| {
                cluster_idx = self.fat[cluster_idx];
                if (cluster_idx == self.fat[1]) {
                    panic("fat16.Driver.getdirents: file offset is out of range (offset is {})", .{file.offset});
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
            return i;
        }
    };
}
