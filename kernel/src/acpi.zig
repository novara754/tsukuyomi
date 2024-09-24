const std = @import("std");
const mem = @import("mem.zig");

const ACPI_REV2: u8 = 2;

const XSDP = extern struct {
    _signature: [8]u8 align(4),
    _checksum: u8,
    _oem_id: [6]u8,
    revision: u8,
    _rsdt_address: u32,

    length: u32,
    xsdt_address: u64,
    _extended_checksum: u8,
    _reserved: [3]u8,

    fn verify(self: *align(1) const @This()) !void {
        if (self.revision != ACPI_REV2) {
            return error.IncorrectRevision;
        }

        const raw: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (raw, 0..self.length) |b, _| {
            sum +%= b;
        }

        if (sum != 0) {
            return error.IncorrectChecksum;
        }
    }
};

const SDTHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    _checksum: u8,
    _oem_id: [6]u8,
    _oem_table_id: [8]u8,
    _oem_revision: u32,
    _creator_id: u32,
    _creator_revision: u32,

    fn verify(self: *align(1) const @This()) !void {
        // if (self.revision != ACPI_REV2) {
        //     return error.IncorrectRevision;
        // }

        const raw: [*]const u8 = @ptrCast(self);
        var sum: u8 = 0;
        for (raw, 0..self.length) |b, _| {
            sum +%= b;
        }
        if (sum != 0) {
            return error.IncorrectChecksum;
        }
    }
};

const XSDT = extern struct {
    header: SDTHeader align(4),
    pointers: [0]u64 align(4),

    const Self = @This();

    fn numEntries(self: *const Self) usize {
        return (self.header.length - @sizeOf(SDTHeader)) / @sizeOf(u64);
    }

    fn getEntry(self: *const Self, i: usize) ?u64 {
        if (i > self.numEntries()) {
            return null;
        }
        const entries: [*]align(1) const u64 = @ptrCast(&self.pointers);
        return entries[i];
    }
};

const MADT = extern struct {
    _header: SDTHeader align(4),
    lapic_address: u32 align(1),
    _flags: u32 align(1),
    first_header: MADTEntryHeader align(1),
};

const MADTEntryHeader = packed struct {
    ty: MADTEntryType,
    length: u8,
};

const MADTEntryIOAPIC = packed struct {
    _header: MADTEntryHeader,
    ioapic_id: u8,
    _reserved: u8,
    ioapic_address: u32,
    _global_system_interrupt_base: u32,
};

const MADTEntryType = enum(u8) {
    ioapic = 1,
};

const MADTData = struct {
    lapic_base: [*]u32,
    ioapic_base: [*]u32,
    ioapic_id: u8,
};

fn parseMADT(madt_header: *const SDTHeader) MADTData {
    // TODO: There has to be a nicer way to do all this...

    const madt: *const MADT = @ptrCast(madt_header);
    var header: *align(1) const MADTEntryHeader = &madt.first_header;
    while (header.*.ty != MADTEntryType.ioapic) {
        var u8_ptr: [*]const u8 = @ptrCast(header);
        header = @alignCast(@ptrCast(&u8_ptr[header.length]));
    }

    const ioapic_entry: *align(1) const MADTEntryIOAPIC = @alignCast(@ptrCast(header));
    return MADTData{
        .lapic_base = @alignCast(@ptrCast(mem.p2v(madt.lapic_address))),
        .ioapic_base = @alignCast(@ptrCast(mem.p2v(ioapic_entry.ioapic_address))),
        .ioapic_id = ioapic_entry.ioapic_id,
    };
}

const ACPIData = struct {
    madt: MADTData,
};

pub fn init(xsdp_addr: u64) !ACPIData {
    const xsdp: *align(4) const XSDP = @ptrFromInt(xsdp_addr);
    try xsdp.verify();

    const xsdt: *align(4) const XSDT = @alignCast(@ptrCast(mem.p2v(xsdp.xsdt_address)));
    try xsdt.header.verify();

    const madt: ?MADTData = blk: {
        var i: usize = 0;
        const numEntries = xsdt.numEntries();
        while (i < numEntries) : (i += 1) {
            const entryAddr = xsdt.getEntry(i) orelse unreachable;
            const header: *const SDTHeader = @alignCast(@ptrCast(mem.p2v(entryAddr)));
            if (std.mem.eql(u8, &header.signature, "APIC")) {
                try header.verify();
                break :blk parseMADT(header);
            }
        }
        break :blk null;
    };

    return ACPIData{
        .madt = madt orelse {
            return error.CouldNotFindMADT;
        },
    };
}
