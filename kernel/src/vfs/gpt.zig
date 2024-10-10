const std = @import("std");

/// Mixed endian
pub const GUID = [16]u8;

pub const TableHeader = extern struct {
    // Should be `EFI PART`
    signature: [8]u8,
    /// Should be `00 01 00 00`
    revision: u32,
    /// Should be 92
    header_size: u32,
    header_crc32: u32,
    reserved1: u32,
    header_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: GUID,
    partition_entries_start_lba: u64,
    partition_entries_count: u32,
    /// Should be 128
    partition_entry_size: u32,
    partition_entries_crc32: u32,

    pub fn verify(self: *const @This()) bool {
        return std.mem.eql(u8, &self.signature, "EFI PART");
    }
};

pub const PartitionEntry = extern struct {
    type_guid: GUID,
    guid: GUID,
    first_lba: u64,
    /// Inclusive
    last_lba: u64,
    flags: u64,
    // UTF-16LE
    name: [72]u8,

    pub fn valid(self: *const @This()) bool {
        return !std.mem.allEqual(u8, std.mem.asBytes(self), 0);
    }
};

/// Using the data from the given `header` read the partition entries from the given `block_device`.
///
/// The `block_device` should support the following methods:
/// - `getBlockSize()` should return an integer indicating the size of each block
/// - `readBlocks(start, count, buf)` should read `count` blocks starting at `start` into `buf`
pub fn readPartitions(header: *const TableHeader, block_device: anytype, allocator: std.mem.Allocator) !std.ArrayList(PartitionEntry) {
    var entries = std.ArrayList(PartitionEntry).init(allocator);
    errdefer entries.deinit();

    const buf = try allocator.alignedAlloc(u8, @alignOf(PartitionEntry), block_device.getBlockSize());
    errdefer allocator.free(buf);

    var entries_left_count = header.partition_entries_count;
    const entry_blocks_count = header.partition_entries_count * header.partition_entry_size / block_device.getBlockSize();
    const entries_per_block_count = block_device.getBlockSize() / header.partition_entry_size;
    outer: for (0..entry_blocks_count) |bi| {
        try block_device.readBlocks(@intCast(header.partition_entries_start_lba + bi), 1, buf);

        const these_entries = std.mem.bytesAsSlice(PartitionEntry, buf);
        for (0..entries_per_block_count) |pi| {
            const entry = these_entries[pi];

            if (!entry.valid()) {
                continue;
            }

            try entries.append(entry);

            entries_left_count -= 1;
            if (entries_left_count == 0) {
                break :outer;
            }
        }
    }

    return entries;
}

pub fn PartitionBlockDevice(comptime BlockDevice: type) type {
    return struct {
        inner: BlockDevice,
        layout: PartitionEntry,

        const Self = @This();

        pub fn getBlockSize(self: Self) usize {
            return self.inner.getBlockSize();
        }

        pub fn readBlocks(self: Self, start: u32, count: u8, buf: []u8) !void {
            const part_len = self.layout.last_lba - self.layout.first_lba;

            if (start + count > part_len) {
                return error.OutOfRange;
            }

            return self.inner.readBlocks(@intCast(self.layout.first_lba + start), count, buf);
        }
    };
}

test "table header field offsets" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(0, @offsetOf(TableHeader, "signature"));
    try expectEqual(8, @offsetOf(TableHeader, "revision"));
    try expectEqual(12, @offsetOf(TableHeader, "header_size"));
    try expectEqual(16, @offsetOf(TableHeader, "header_crc32"));
    try expectEqual(20, @offsetOf(TableHeader, "reserved1"));
    try expectEqual(24, @offsetOf(TableHeader, "header_lba"));
    try expectEqual(32, @offsetOf(TableHeader, "backup_lba"));
    try expectEqual(40, @offsetOf(TableHeader, "first_usable_lba"));
    try expectEqual(48, @offsetOf(TableHeader, "last_usable_lba"));
    try expectEqual(56, @offsetOf(TableHeader, "disk_guid"));
    try expectEqual(72, @offsetOf(TableHeader, "partition_entries_start_lba"));
    try expectEqual(80, @offsetOf(TableHeader, "partition_entries_count"));
    try expectEqual(84, @offsetOf(TableHeader, "partition_entry_size"));
    try expectEqual(88, @offsetOf(TableHeader, "partition_entries_crc32"));
}

test "partition entry field offsets" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(0, @offsetOf(PartitionEntry, "type_guid"));
    try expectEqual(16, @offsetOf(PartitionEntry, "guid"));
    try expectEqual(32, @offsetOf(PartitionEntry, "first_lba"));
    try expectEqual(40, @offsetOf(PartitionEntry, "last_lba"));
    try expectEqual(48, @offsetOf(PartitionEntry, "flags"));
    try expectEqual(56, @offsetOf(PartitionEntry, "name"));
}
