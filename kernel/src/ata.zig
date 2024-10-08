//! ATA PIO disk driver
//!
//! See also:
//! - https://wiki.osdev.org/ATA_PIO_Mode
//! - https://people.freebsd.org/~imp/asiabsdcon2015/works/d2161r5-ATAATAPI_Command_Set_-_3.pdf

const std = @import("std");
const x86 = @import("x86.zig");
const logger = @import("logger.zig");

const Commands = struct {
    /// IDENTIFY DEVICE command
    const identify = 0xec;
    /// READ SECTOR(S) command
    const read = 0x20;
};

/// Offsets from the IO base for each of the IO registers
const IORegisters = struct {
    /// RW: Data (16-bit)
    const data = 0;
    /// R: Errors
    /// W: Features
    const err_feat = 1;
    /// RW: Sector Count
    const sector_count = 2;
    /// RW: LSB of sector number
    const lba_lo = 3;
    /// RW: Second lowest byte of sector number
    const lba_mid1 = 4;
    /// RW: Third lowest byte of sector number
    const lba_mid2 = 5;
    /// RW: Drive select
    const drive_sel = 6;
    /// R: Status
    /// W: Command
    const status_cmd = 7;
};

/// Offsets from the Control base for each of the control registers
const CtrlRegisters = struct {
    /// R: Duplicate of status register
    /// W: Device control
    const status_ctrl = 0;
    /// R: Selected drive info
    const drive = 1;
};

/// Represents the error register
const ErrorRegister = packed struct {
    /// Address mark not found
    amnf: bool,
    /// Track zero not found
    tkznf: bool,
    /// Command aborted
    abrt: bool,
    /// Media change request
    mcr: bool,
    /// Id not found
    idnf: bool,
    /// Media changed
    mc: bool,
    /// Uncorrectable data error
    unc: bool,
    /// Bad block detected
    bbk: bool,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("ErrorRegister has wrong size");
    }
};

/// Represents the drive select register
const DriveSelRegister = packed struct {
    /// Top 4 bits of the LBA
    lba_hi: u4 = 0,
    /// Drive select
    drive: DriveE,
    /// Always one
    one1: bool = true,
    /// Whether to use CHS or LBA addressing, should always be one
    use_lba: bool = true,
    /// Always one
    one2: bool = true,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("DriveSelRegister has wrong size");
    }
};

/// Represents the status register
const StatusRegister = packed struct {
    /// An error has occursed
    err: bool,
    /// Always zero
    idx: bool,
    /// Corrected data, always zero
    corr: bool,
    /// Data ready to transfer
    drq: bool,
    /// Overlapped mode service request
    srv: bool,
    /// Drive fault (does not set `err`)
    df: bool,
    /// Drive is available to handle commands
    rdy: bool,
    /// Drive is processing command
    bsy: bool,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("StatusRegister has wrong size");
    }
};

/// Typically there are two ATA buses with two drives each.
/// This enumerates the buses.
const BusE = enum(u1) {
    primary,
    secondary,
};

/// Typically there are two ATA buses with two drives each.
/// This enumerates the drives per bus.
const DriveE = enum(u1) {
    primary,
    secondary,
};

const DriveMetadata = struct {
    logical_sector_count: u32,
    /// Logical sector size in bytes
    logical_sector_size: u32 = 512,
};

/// Handle to an ATA bus.
const Bus = struct {
    which: BusE,
    io_base: u16,
    ctrl_base: u16,

    drives: [2]?DriveMetadata = .{ null, null },

    const Self = @This();

    /// Initialize the drive by sending an `IDENTIFY` command and reading
    /// relevant information from its response.
    pub fn init(self: *Self, drive: DriveE) !void {
        const drive_sel = DriveSelRegister{ .drive = drive };
        x86.outb(self.io_base + IORegisters.drive_sel, @bitCast(drive_sel));

        x86.outb(self.io_base + IORegisters.sector_count, 0);
        x86.outb(self.io_base + IORegisters.lba_lo, 0);
        x86.outb(self.io_base + IORegisters.lba_mid1, 0);
        x86.outb(self.io_base + IORegisters.lba_mid2, 0);

        x86.outb(self.io_base + IORegisters.status_cmd, Commands.identify);
        const status_raw = x86.inb(self.io_base + IORegisters.status_cmd);
        if (status_raw == 0) {
            logger.log(.info, "ata", "ATA{}#{}: not present", .{ @intFromEnum(self.which), @intFromEnum(drive) });
            return error.NotPresent;
        }

        var status: StatusRegister = @bitCast(status_raw);
        while (status.bsy) {
            status = self.read_status();
        }

        if (x86.inb(self.io_base + IORegisters.lba_mid1) != 0 or x86.inb(self.io_base + IORegisters.lba_mid2) != 0) {
            logger.log(.info, "ata", "ATA{}#{}: not ATA", .{ @intFromEnum(self.which), @intFromEnum(drive) });
            return error.NotATA;
        }

        while (!status.drq and !status.err) {
            status = self.read_status();
        }

        if (status.err) {
            const err = self.read_error();
            logger.log(.err, "ata", "ATA{}#{}: err = {}", .{ @intFromEnum(self.which), @intFromEnum(drive), err });
        }

        var logical_sector_count: u32 = undefined;
        var logical_sector_size: u32 = 512;
        var logical_sector_size_support = false;
        for (0..256) |i| {
            const data = x86.inw(self.io_base + IORegisters.data);
            if (i == 60) {
                logical_sector_count = data;
            } else if (i == 61) {
                logical_sector_count |= @as(u32, data) << 16;
            } else if (i == 106) {
                logical_sector_size_support = data & (1 << 12) != 0;
            } else if (logical_sector_size_support and i == 117) {
                logical_sector_size |= data;
            } else if (logical_sector_size_support and i == 118) {
                logical_sector_size |= @as(u32, data) << 16;
            }
        }
        if (logical_sector_size_support) {
            // the device reports the sector size in word (16-bit values)
            // so multiply by 2 to get number of bytes
            logical_sector_size *= 2;
        }

        self.drives[@intFromEnum(drive)] = .{
            .logical_sector_count = logical_sector_count,
            .logical_sector_size = logical_sector_size,
        };

        logger.log(.info, "ata", "ATA{}#{}: initialized", .{ @intFromEnum(self.which), @intFromEnum(drive) });
        logger.log(.debug, "ata", "ATA{}#{}: logical sector count = {}, logical sector size = {}, capacity in bytes = {}", .{
            @intFromEnum(self.which),
            @intFromEnum(drive),
            logical_sector_count,
            logical_sector_size,
            logical_sector_count * logical_sector_size,
        });
    }

    /// Read `count` logical sectors starting at `lba` from `drive`
    pub fn read_sectors(self: *Self, drive: DriveE, lba: u32, count: u8, allocator: std.mem.Allocator) ![]u8 {
        const drive_metadata = self.drives[@intFromEnum(drive)] orelse {
            return error.NotInitialized;
        };

        const lba_hi = (lba >> 24) & 0xF;
        const lba_mid2 = (lba >> 16) & 0xFF;
        const lba_mid1 = (lba >> 8) & 0xFF;
        const lba_lo = (lba >> 0) & 0xFF;

        const drive_sel = DriveSelRegister{
            .drive = drive,
            .lba_hi = @intCast(lba_hi),
        };

        x86.outb(self.io_base + IORegisters.drive_sel, @bitCast(drive_sel));
        x86.outb(self.io_base + IORegisters.lba_mid2, @intCast(lba_mid2));
        x86.outb(self.io_base + IORegisters.lba_mid1, @intCast(lba_mid1));
        x86.outb(self.io_base + IORegisters.lba_lo, @intCast(lba_lo));
        x86.outb(self.io_base + IORegisters.sector_count, count);

        x86.outb(self.io_base + IORegisters.status_cmd, Commands.read);

        var status: StatusRegister = self.read_status();
        while (!status.drq) {
            status = self.read_status();
        }

        const num_bytes = drive_metadata.logical_sector_size * count;
        var buf = try allocator.alloc(u8, num_bytes);
        var i: usize = 0;
        while (i < num_bytes) : (i += 2) {
            const word = x86.inw(self.io_base + IORegisters.data);
            buf[i + 0] = @intCast(word & 0xFF);
            buf[i + 1] = @intCast(word >> 8);
        }
        return buf;
    }

    fn read_status(self: *Self) StatusRegister {
        return @bitCast(x86.inb(self.io_base + IORegisters.status_cmd));
    }

    fn read_error(self: *Self) ErrorRegister {
        return @bitCast(x86.inb(self.io_base + IORegisters.err_feat));
    }
};

/// Handle for the first ATA bus
pub var ATA0 = Bus{ .which = .primary, .io_base = 0x1f0, .ctrl_base = 0x3f6 };

/// Handle for the second ATA bus
pub var ATA1 = Bus{ .which = .secondary, .io_base = 0x170, .ctrl_base = 0x376 };
