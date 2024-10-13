//! FAT16 filesystem driver
//!
//! The drive/partition is divided into equally-sized clusters.
//! These clusters are chained together into linked lists by the File Allocation Table,
//! where each linked list corresponds to a file.
//!
//! All multi-byte values are little endian.
//!
//! See also:
//! - https://en.wikipedia.org/wiki/File_Allocation_Table
//! - https://en.wikipedia.org/wiki/Design_of_the_FAT_file_system
//! - https://wiki.osdev.org/FAT

const std = @import("std");
const panic = @import("../panic.zig").panic;

/// The BIOS Parameter Block is stored in the first sector (bootsector)
/// of a drive/partition and contain generated metadata about the drive and
/// the FAT filesystem stored on it.
pub const BPB = extern struct {
    /// The first 3 bytes of the BPB are typically a jmp instruction
    /// that jumps over the BPB into the bootloader code.
    jmp: [3]u8,
    oem_id: [8]u8,
    bytes_per_sector: u16 align(1),
    sectors_per_cluster: u8,
    reserved_sectors_count: u16,
    /// Number of file allocation tables
    fat_count: u8,
    /// Number of entries in the root directory.
    /// Must be set such that the root directory occupies a whole number of sectors.
    root_dir_entry_count: u16 align(1),
    /// Total number of sectors in this volume.
    /// If `0` the actual value is stored in `sector_count_large`
    sector_count: u16 align(1),
    media_descriptor: u8,
    /// Number of sectors per file allocation table.
    sectors_per_fat: u16,
    /// Used for CHS addressing
    sectors_per_track: u16,
    /// Used for CHS addressing
    heads_count: u16,
    hidden_sectors_count: u32,
    /// Only valid if `sector_count` is `0`
    sector_count_large: u32,

    const Self = @This();

    /// Returns first block address of FAT region
    pub fn startOfFATRegion(self: *const Self) u32 {
        return self.reserved_sectors_count;
    }

    /// Returns first block address of root directory region
    pub fn startOfRootDir(self: *const Self) u32 {
        return self.startOfFATRegion() + self.sectors_per_fat * self.fat_count;
    }

    /// Returns first block address of data region
    pub fn startOfDataRegion(self: *const Self) u32 {
        return self.startOfRootDir() + self.root_dir_entry_count * @sizeOf(DirEntry) / self.bytes_per_sector;
    }

    /// Returns first block address of the given cluster
    /// `0` and `1` are not valid indices.
    pub fn startOfCluster(self: *const Self, idx: u16) u32 {
        return self.startOfDataRegion() + (idx - 2) * self.sectors_per_cluster;
    }

    pub fn bytesPerCluster(self: *const Self) usize {
        return self.bytes_per_sector * self.sectors_per_cluster;
    }
};

/// FAT16 Extension to the BIOS Parameter Block
pub const EBPB = extern struct {
    bpb: BPB,
    /// Drive number of drive during formatting
    drive_number: u8,
    /// Flags used by Windows NT
    nt_flags: u8,
    /// `0x28` or `0x29`
    signature: u8,
    volume_id: [4]u8,
    volume_label: [11]u8,
    /// Name of the filesystem padded with spaces. Not to be trusted
    fs_name: [8]u8,

    pub fn valid(self: *const @This()) bool {
        return self.signature == 0x28 or self.signature == 0x29;
    }
};

/// File Allocation Table
///
/// Each entry entry represents a cluster and the value is the index
/// of the next cluster belonging to a linked list.
///
/// The first entry in the FAT holds the FAT ID, the second
/// entry contains the special value to use as the "end of chain"
/// marker to mark the end of a cluster list.
/// This means the first usable entry is at index 2.
/// This also means clusters 0 and 1 do not exist as data clusters.
///
/// Special values:
/// - `0x0000` indicates an unused cluster
/// - `0x0001` should also be treated as "end of chain"
/// - `0xFFF7` indicates a bad cluster
///
/// The size of the FAT is specified by `BPB.sectors_per_fat`
pub const FAT = []u16;

pub const DirEntryAttribute = struct {
    /// Not allowed to be modified
    pub const read_only = 0x01;
    /// Do not show during normal directory listings
    pub const hidden = 0x02;
    /// File may not be physically moved
    pub const system = 0x04;
    /// Directory entry is not a file but the volume label
    pub const volume_label = 0x08;
    /// Entry is a directory
    pub const directory = 0x10;
    /// File is has been modified and backup software needs
    /// to create a backup
    pub const archive = 0x20;
    /// Character device
    pub const device = 0x40;
    /// Must not be changed
    pub const reserved = 0x80;

    /// Entry is not actually an entry but part of a VFAT long name
    pub const vfat = 0x0f;
};

pub const DirEntry = extern struct {
    /// Padded with spaces
    ///
    /// The first byte can have the following special values:
    /// - `0x00`: This entry and all subsequent entries are empty
    /// - `0x05`: Should be translated to `0xE5`
    /// - `0x2E`: Dot entry (`.` or `..`)
    /// - `0xE5`: Entry is "erased" or available
    short_filename: [8]u8,
    /// Padded with spaces
    short_extension: [3]u8,
    attributes: u8,
    /// Operating system specific
    reserved: u8,
    /// 10ms unit of creation time
    ///
    /// If entry is marked as "erased" this stores
    /// the first character of the short filename
    creation_time_ms: u8,
    /// Creation time
    ///
    /// Bits:
    /// - 0-4: seconds / 2
    /// - 5-10: minutes
    /// - 11-15: hours
    creation_time: u16,
    /// Creation date
    ///
    /// Bits:
    /// - 0-4: day
    /// - 5-8: month
    /// - 9-15: year - 1980
    creation_date: u16,
    /// Last accessed date
    ///
    /// For format see `creation_date`
    last_accessed_date: u16,
    /// High 16 bits of cluster index.
    /// `0` for FAT16.
    cluster_hi: u16,
    /// Last modification time
    ///
    /// For format see `creation_time`
    last_modification_time: u16,
    /// Last modification date
    ///
    /// For format see `creation_date`
    last_modification_date: u16,
    /// Low 16 bits of cluster index
    cluster_lo: u16,
    /// File size in bytes
    filesize: u32,

    const Self = @This();

    pub fn valid(self: *const Self) bool {
        const c = self.short_filename[0];
        return c != 0x00 and c != 0xe5;
    }

    /// Returns true if this empty and all subsequent entries are empty.
    pub fn thisAndRestEmpty(self: *const Self) bool {
        return self.short_filename[0] == 0x00;
    }

    /// Returns true if this entry is part of a vfat long filename entry.
    pub fn isVFAT(self: *const Self) bool {
        return self.attributes == DirEntryAttribute.vfat;
    }

    pub fn filename(self: *const Self) []const u8 {
        const i = std.mem.indexOf(u8, &self.short_filename, " ") orelse self.short_filename.len;
        return self.short_filename[0..i];
    }

    pub fn extension(self: *const Self) []const u8 {
        const i = std.mem.indexOf(u8, &self.short_extension, " ") orelse self.short_extension.len;
        return self.short_extension[0..i];
    }

    pub fn isDir(self: *const Self) bool {
        return self.attributes & DirEntryAttribute.directory != 0;
    }
};

pub fn readEBPB(block_device: anytype, allocator: std.mem.Allocator) !*EBPB {
    const buf = try allocator.alignedAlloc(u8, @alignOf(EBPB), block_device.getBlockSize());
    errdefer allocator.free(buf);

    try block_device.readBlocks(0, 1, buf);
    return std.mem.bytesAsValue(EBPB, buf);
}

pub fn readFAT(ebpb: *const EBPB, block_device: anytype, allocator: std.mem.Allocator) !FAT {
    if (ebpb.bpb.bytes_per_sector != block_device.getBlockSize()) {
        panic("fat16.readFAT: block size mismatch", .{});
    }

    const buf = try allocator.alignedAlloc(u8, @alignOf(u16), ebpb.bpb.sectors_per_fat * ebpb.bpb.bytes_per_sector);
    errdefer allocator.free(buf);

    try block_device.readBlocks(ebpb.bpb.startOfFATRegion(), @intCast(ebpb.bpb.sectors_per_fat), buf);
    return std.mem.bytesAsSlice(u16, buf);
}

pub fn readRootDir(ebpb: *const EBPB, block_device: anytype, allocator: std.mem.Allocator) ![]DirEntry {
    var sp = asm volatile ("mov %rsp, %rax"
        : [ret] "={rax}" (-> u64),
        :
        : "{rax}"
    );
    @import("../logger.zig").log(.debug, "fat16", "1, sp={x}", .{sp});

    if (ebpb.bpb.bytes_per_sector != block_device.getBlockSize()) {
        panic("fat16.readFAT: block size mismatch", .{});
    }

    sp = asm volatile ("mov %rsp, %rax"
        : [ret] "={rax}" (-> u64),
        :
        : "{rax}"
    );
    @import("../logger.zig").log(.debug, "fat16", "1, sp={x}", .{sp});

    @import("../logger.zig").log(.debug, "fat16", "#1", .{});

    const root_dir_size = ebpb.bpb.root_dir_entry_count * @sizeOf(DirEntry);
    const buf = try allocator.alignedAlloc(u8, @alignOf(DirEntry), root_dir_size);
    errdefer allocator.free(buf);

    @import("../logger.zig").log(.debug, "fat16", "#2", .{});
    try block_device.readBlocks(
        ebpb.bpb.startOfRootDir(),
        @intCast(root_dir_size / ebpb.bpb.bytes_per_sector),
        buf,
    );
    @import("../logger.zig").log(.debug, "fat16", "#3", .{});
    return std.mem.bytesAsSlice(DirEntry, buf);
}

pub fn readCluster(idx: u16, ebpb: *const EBPB, block_device: anytype, allocator: std.mem.Allocator) ![]align(@alignOf(DirEntry)) u8 {
    if (ebpb.bpb.bytes_per_sector != block_device.getBlockSize()) {
        panic("fat16.readFAT: block size mismatch", .{});
    }

    const buf = try allocator.alignedAlloc(u8, @alignOf(DirEntry), ebpb.bpb.bytes_per_sector * ebpb.bpb.sectors_per_cluster);
    errdefer allocator.free(buf);

    try block_device.readBlocks(ebpb.bpb.startOfCluster(idx), ebpb.bpb.sectors_per_cluster, buf);
    return buf;
}

pub fn findFile(path: []const u8, ebpb: *const EBPB, fat: FAT, block_device: anytype, allocator: std.mem.Allocator) !DirEntry {
    if (path[0] != '/') {
        return error.PathNotAbsolute;
    }

    var pathCleaned = path[1..];
    if (pathCleaned[pathCleaned.len - 1] == '/') {
        pathCleaned = pathCleaned[0 .. pathCleaned.len - 1];
    }

    var segments = std.mem.splitScalar(u8, pathCleaned, '/');

    const sp = asm volatile ("mov %rsp, %rax"
        : [ret] "={rax}" (-> u64),
        :
        : "{rax}"
    );
    @import("../logger.zig").log(.debug, "fat16", "1, sp={x}", .{sp});

    const root_dir = try readRootDir(ebpb, block_device, allocator);
    @import("../logger.zig").log(.debug, "fat16", "2", .{});
    defer allocator.free(fat);

    const first_segment = segments.next() orelse return error.EmptyPath;

    var dir_entry: DirEntry = try findEntry(root_dir, first_segment);

    @import("../logger.zig").log(.debug, "fat16", "3", .{});

    while (segments.next()) |segment| {
        if (!dir_entry.isDir()) return error.NotADirectory;

        var cluster_idx = dir_entry.cluster_lo;
        while (true) {
            const cluster = try readCluster(cluster_idx, ebpb, block_device, allocator);
            defer allocator.free(cluster);

            const entries = std.mem.bytesAsSlice(DirEntry, cluster);
            if (findEntry(entries, segment)) |e| {
                dir_entry = e;
                break;
            } else |_| {}

            cluster_idx = fat[cluster_idx];
            if (cluster_idx == fat[1]) {
                return error.NoSuchFile;
            }
        }
    }

    return dir_entry;
}

fn entryNameMatches(entry: DirEntry, name: []const u8) bool {
    if (entry.extension().len == 0) {
        return std.mem.eql(u8, name, entry.filename());
    } else {
        if (entry.filename().len + entry.extension().len + 1 != name.len) return false;
        if (!std.mem.startsWith(u8, name, entry.filename())) return false;
        if (name[entry.filename().len] != '.') return false;
        return std.mem.endsWith(u8, name, entry.extension());
    }
}

fn findEntry(entries: []const DirEntry, name: []const u8) !DirEntry {
    for (entries) |entry| {
        if (!entry.valid()) continue;

        if (entryNameMatches(entry, name)) {
            return entry;
        }
    }
    return error.NoSuchFile;
}

test "bpb field offsets" {
    const expectEqual = @import("std").testing.expectEqual;

    try expectEqual(0, @offsetOf(BPB, "jmp"));
    try expectEqual(3, @offsetOf(BPB, "oem_id"));
    try expectEqual(11, @offsetOf(BPB, "bytes_per_sector"));
    try expectEqual(13, @offsetOf(BPB, "sectors_per_cluster"));
    try expectEqual(14, @offsetOf(BPB, "reserved_sectors_count"));
    try expectEqual(16, @offsetOf(BPB, "fat_count"));
    try expectEqual(17, @offsetOf(BPB, "root_dir_entry_count"));
    try expectEqual(19, @offsetOf(BPB, "sector_count"));
    try expectEqual(21, @offsetOf(BPB, "media_descriptor"));
    try expectEqual(22, @offsetOf(BPB, "sectors_per_fat"));
    try expectEqual(24, @offsetOf(BPB, "sectors_per_track"));
    try expectEqual(26, @offsetOf(BPB, "heads_count"));
    try expectEqual(28, @offsetOf(BPB, "hidden_sectors_count"));
    try expectEqual(32, @offsetOf(BPB, "sector_count_large"));
}

test "ebpb field offsets" {
    const expectEqual = @import("std").testing.expectEqual;

    try expectEqual(0, @offsetOf(EBPB, "bpb"));
    try expectEqual(36, @offsetOf(EBPB, "drive_number"));
    try expectEqual(37, @offsetOf(EBPB, "nt_flags"));
    try expectEqual(38, @offsetOf(EBPB, "signature"));
    try expectEqual(39, @offsetOf(EBPB, "volume_id"));
    try expectEqual(43, @offsetOf(EBPB, "volume_label"));
    try expectEqual(54, @offsetOf(EBPB, "fs_name"));
}

test "dir entry field offsets and size" {
    const expectEqual = @import("std").testing.expectEqual;

    try expectEqual(0, @offsetOf(DirEntry, "short_filename"));
    try expectEqual(8, @offsetOf(DirEntry, "short_extension"));
    try expectEqual(11, @offsetOf(DirEntry, "attributes"));
    try expectEqual(12, @offsetOf(DirEntry, "reserved"));
    try expectEqual(13, @offsetOf(DirEntry, "creation_time_ms"));
    try expectEqual(14, @offsetOf(DirEntry, "creation_time"));
    try expectEqual(16, @offsetOf(DirEntry, "creation_date"));
    try expectEqual(18, @offsetOf(DirEntry, "last_accessed_date"));
    try expectEqual(20, @offsetOf(DirEntry, "cluster_hi"));
    try expectEqual(22, @offsetOf(DirEntry, "last_modification_time"));
    try expectEqual(24, @offsetOf(DirEntry, "last_modification_date"));
    try expectEqual(26, @offsetOf(DirEntry, "cluster_lo"));
    try expectEqual(28, @offsetOf(DirEntry, "filesize"));

    try expectEqual(32, @sizeOf(DirEntry));
}

test entryNameMatches {
    const expectEqual = @import("std").testing.expectEqual;

    var ent: DirEntry = undefined;

    ent.short_filename = "BOOTX64 ".*;
    ent.short_extension = "EFI".*;
    try expectEqual(true, entryNameMatches(ent, "BOOTX64.EFI"));

    ent.short_filename = "FILENAME".*;
    ent.short_extension = "COM".*;
    try expectEqual(true, entryNameMatches(ent, "FILENAME.COM"));

    ent.short_filename = "ADIRNAME".*;
    ent.short_extension = "   ".*;
    try expectEqual(true, entryNameMatches(ent, "ADIRNAME"));

    ent.short_filename = "ABCD1234".*;
    ent.short_extension = "EXE".*;
    try expectEqual(false, entryNameMatches(ent, "4321DCBA.EXE"));

    ent = .{
        .short_filename = .{ 69, 70, 73, 32, 32, 32, 32, 32 },
        .short_extension = .{ 32, 32, 32 },
        .attributes = 16,
        .reserved = 0,
        .creation_time_ms = 77,
        .creation_time = 44541,
        .creation_date = 22857,
        .last_accessed_date = 22857,
        .cluster_hi = 0,
        .last_modification_time = 44541,
        .last_modification_date = 22857,
        .cluster_lo = 3,
        .filesize = 0,
    };
    try expectEqual(true, entryNameMatches(ent, "EFI"));
}
