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

const GenericAddressStructure = extern struct {
    address_space: u8 align(1),
    bit_width: u8 align(1),
    bit_offset: u8 align(1),
    access_size: u8 align(1),
    address: u64 align(1),
};

/// https://uefi.org/htmlspecs/ACPI_Spec_6_4_html/05_ACPI_Software_Programming_Model/ACPI_Software_Programming_Model.html#fixed-acpi-description-table-fadt
const FADT = extern struct {
    header: SDTHeader align(4),
    firmware_ctrl: u32,
    dsdt: u32,
    reserved: u8,
    preferred_power_management_profile: u8,
    sci_interrupt: u16,
    smi_command_port: u32,
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_control: u8,
    pm1a_event_block: u32,
    pm1b_event_block: u32,
    pm1a_control_block: u32,
    pm1b_control_block: u32,
    pm2_control_block: u32,
    pm_timer_block: u32,
    gpe0_block: u32,
    gpe1_block: u32,
    pm1_event_length: u8,
    pm1_control_length: u8,
    pm2_control_length: u8,
    pm_timer_length: u8,
    gpe0_length: u8,
    gpe1_length: u8,
    gpe1_base: u8,
    cstate_control: u8,
    worst_c2_latency: u16,
    worst_c3_latency: u16,
    flush_size: u16,
    flush_stride: u16,
    duty_offset: u8,
    duty_width: u8,
    day_alarm: u8,
    month_alarm: u8,
    century: u8,
    iapc_boot_arch_flags: u16 align(1),
    reserved2: u8,
    flags: u32,
    reset_register: GenericAddressStructure,
    reset_value: u8,
    arm_boot_arch_flags: u16 align(1),
    fadt_minor_version: u8,
    x_firmware_control: u64 align(1),
    x_dsdt: u64 align(1),
    x_pm1a_event_block: GenericAddressStructure,
    x_pm1b_event_block: GenericAddressStructure,
    x_pm1a_control_block: GenericAddressStructure,
    x_pm1b_control_block: GenericAddressStructure,
    x_pm2_control_block: GenericAddressStructure,
    x_pm_timer_block: GenericAddressStructure,
    x_gpe0_block: GenericAddressStructure,
    x_gpe1_block: GenericAddressStructure,
    sleep_control_register: GenericAddressStructure,
    sleep_status_register: GenericAddressStructure,
    hypervisor_vendor_identity: u64 align(1),
};

const FADTData = struct {
    has_8042: bool,
};

const ACPIData = struct {
    madt: MADTData,
    fadt: FADTData,
};

pub fn init(xsdp_addr: u64) !ACPIData {
    const xsdp: *align(4) const XSDP = @ptrFromInt(xsdp_addr);
    try xsdp.verify();

    const xsdt: *align(4) const XSDT = @alignCast(@ptrCast(mem.p2v(xsdp.xsdt_address)));
    try xsdt.header.verify();

    var madt: ?MADTData = null;
    var fadt: ?FADTData = null;

    var i: usize = 0;
    const numEntries = xsdt.numEntries();
    while (i < numEntries) : (i += 1) {
        const entryAddr = xsdt.getEntry(i) orelse unreachable;
        const header: *const SDTHeader = @alignCast(@ptrCast(mem.p2v(entryAddr)));
        if (std.mem.eql(u8, &header.signature, "APIC")) {
            try header.verify();
            madt = parseMADT(header);
        } else if (std.mem.eql(u8, &header.signature, "FACP")) {
            try header.verify();
            const fadt_struct: *const FADT = @alignCast(@ptrCast(header));
            fadt = .{
                .has_8042 = fadt_struct.iapc_boot_arch_flags & 2 != 0,
            };
        }
    }

    return ACPIData{
        .madt = madt orelse {
            return error.CouldNotFindMADT;
        },
        .fadt = fadt orelse {
            return error.CouldNotFindFADT;
        },
    };
}

test "generic address structure size and field offsets" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(@offsetOf(GenericAddressStructure, "address_space"), 0);
    try expectEqual(@offsetOf(GenericAddressStructure, "bit_width"), 1);
    try expectEqual(@offsetOf(GenericAddressStructure, "bit_offset"), 2);
    try expectEqual(@offsetOf(GenericAddressStructure, "access_size"), 3);
    try expectEqual(@offsetOf(GenericAddressStructure, "address"), 4);

    try expectEqual(@sizeOf(GenericAddressStructure), 12);
}

test "fadt size and field offsets" {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(@offsetOf(FADT, "header"), 0);
    try expectEqual(@offsetOf(FADT, "firmware_ctrl"), 36);
    try expectEqual(@offsetOf(FADT, "dsdt"), 40);
    try expectEqual(@offsetOf(FADT, "reserved"), 44);
    try expectEqual(@offsetOf(FADT, "preferred_power_management_profile"), 45);
    try expectEqual(@offsetOf(FADT, "sci_interrupt"), 46);
    try expectEqual(@offsetOf(FADT, "smi_command_port"), 48);
    try expectEqual(@offsetOf(FADT, "acpi_enable"), 52);
    try expectEqual(@offsetOf(FADT, "acpi_disable"), 53);
    try expectEqual(@offsetOf(FADT, "s4bios_req"), 54);
    try expectEqual(@offsetOf(FADT, "pstate_control"), 55);
    try expectEqual(@offsetOf(FADT, "pm1a_event_block"), 56);
    try expectEqual(@offsetOf(FADT, "pm1b_event_block"), 60);
    try expectEqual(@offsetOf(FADT, "pm1a_control_block"), 64);
    try expectEqual(@offsetOf(FADT, "pm1b_control_block"), 68);
    try expectEqual(@offsetOf(FADT, "pm2_control_block"), 72);
    try expectEqual(@offsetOf(FADT, "pm_timer_block"), 76);
    try expectEqual(@offsetOf(FADT, "gpe0_block"), 80);
    try expectEqual(@offsetOf(FADT, "gpe1_block"), 84);
    try expectEqual(@offsetOf(FADT, "pm1_event_length"), 88);
    try expectEqual(@offsetOf(FADT, "pm1_control_length"), 89);
    try expectEqual(@offsetOf(FADT, "pm2_control_length"), 90);
    try expectEqual(@offsetOf(FADT, "pm_timer_length"), 91);
    try expectEqual(@offsetOf(FADT, "gpe0_length"), 92);
    try expectEqual(@offsetOf(FADT, "gpe1_length"), 93);
    try expectEqual(@offsetOf(FADT, "gpe1_base"), 94);
    try expectEqual(@offsetOf(FADT, "cstate_control"), 95);
    try expectEqual(@offsetOf(FADT, "worst_c2_latency"), 96);
    try expectEqual(@offsetOf(FADT, "worst_c3_latency"), 98);
    try expectEqual(@offsetOf(FADT, "flush_size"), 100);
    try expectEqual(@offsetOf(FADT, "flush_stride"), 102);
    try expectEqual(@offsetOf(FADT, "duty_offset"), 104);
    try expectEqual(@offsetOf(FADT, "duty_width"), 105);
    try expectEqual(@offsetOf(FADT, "day_alarm"), 106);
    try expectEqual(@offsetOf(FADT, "month_alarm"), 107);
    try expectEqual(@offsetOf(FADT, "century"), 108);
    try expectEqual(@offsetOf(FADT, "iapc_boot_arch_flags"), 109);
    try expectEqual(@offsetOf(FADT, "reserved2"), 111);
    try expectEqual(@offsetOf(FADT, "flags"), 112);
    try expectEqual(@offsetOf(FADT, "reset_register"), 116);
    try expectEqual(@offsetOf(FADT, "reset_value"), 128);
    try expectEqual(@offsetOf(FADT, "arm_boot_arch_flags"), 129);
    try expectEqual(@offsetOf(FADT, "fadt_minor_version"), 131);
    try expectEqual(@offsetOf(FADT, "x_firmware_control"), 132);
    try expectEqual(@offsetOf(FADT, "x_dsdt"), 140);
    try expectEqual(@offsetOf(FADT, "x_pm1a_event_block"), 148);
    try expectEqual(@offsetOf(FADT, "x_pm1b_event_block"), 160);
    try expectEqual(@offsetOf(FADT, "x_pm1a_control_block"), 172);
    try expectEqual(@offsetOf(FADT, "x_pm1b_control_block"), 184);
    try expectEqual(@offsetOf(FADT, "x_pm2_control_block"), 196);
    try expectEqual(@offsetOf(FADT, "x_pm_timer_block"), 208);
    try expectEqual(@offsetOf(FADT, "x_gpe0_block"), 220);
    try expectEqual(@offsetOf(FADT, "x_gpe1_block"), 232);
    try expectEqual(@offsetOf(FADT, "sleep_control_register"), 244);
    try expectEqual(@offsetOf(FADT, "sleep_status_register"), 256);
    try expectEqual(@offsetOf(FADT, "hypervisor_vendor_identity"), 268);

    try expectEqual(@sizeOf(FADT), 276);
}
