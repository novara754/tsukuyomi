const std = @import("std");
const mem = @import("mem.zig");

fn request_id(comptime first: u64, comptime second: u64) [4]u64 {
    return [4]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, first, second };
}

pub export var BASE_REVISION linksection(".requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2 };

// fn Request(id: [2]u64, comptime RequestData: type, comptime ResponseData: type) type {
//     const CommonResponseFields = @typeInfo(struct {
//         revision: u64,
//     }).@"struct".fields;

//     const Response = @Type(.{
//         .@"struct" = .{
//             .layout = .@"packed",
//             .backing_integer = u64,
//             .fields = @typeInfo(ResponseData).@"struct".fields ++ CommonResponseFields,
//             .decls = &.{},
//             .is_tuple = false,
//         },
//     });

//     const CommonFields = @typeInfo(struct {
//         id: [4]u64 = request_id(id),
//         revision: u64 = 0,
//         response: ?*Response = null,
//     }).@"struct".fields;

//     return @Type(.{
//         .@"struct" = .{
//             .layout = .@"packed",
//             .backing_integer = u64,
//             .fields = @typeInfo(RequestData).@"struct".fields ++ CommonFields,
//             .decls = &.{},
//             .is_tuple = false,
//         },
//     });
// }

const HHDMResponse = extern struct {
    revision: u64,
    offset: u64,
};

const HHDMRequest = extern struct {
    id: [4]u64 = request_id(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: ?*HHDMResponse = null,
};

pub export var HHDM linksection(".requests") = HHDMRequest{};

pub const MemoryMapEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};

const MemoryMapEntry = struct {
    base: u64,
    length: u64,
    ty: MemoryMapEntryType,
};

pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*const MemoryMapEntry,
};

const MemoryMapRequest = extern struct {
    id: [4]u64 = request_id(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
    revision: u64 = 0,
    response: ?*MemoryMapResponse = null,
};

pub export var MEMORY_MAP linksection(".requests") = MemoryMapRequest{};

const RSDPResponse = extern struct {
    revision: u64,
    rsdp_addr: u64,
};

const RSDPRequest = extern struct {
    id: [4]u64 = request_id(0xc5e77b6b397e7b43, 0x27637845accdcf3c),
    revision: u64 = 0,
    response: ?*RSDPResponse = null,
};

pub export var RSDP linksection(".requests") = RSDPRequest{};

const UUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

pub const File = extern struct {
    revision: u64,
    address: [*]align(mem.PAGE_SIZE) u8,
    size: u64,
    path: [*:0]u8,
    cmdline: [*:0]u8,
    media_type: u32,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: UUID,
    gpt_part_uuid: UUID,
    part_uuid: UUID,

    pub fn path_slice(self: *const @This()) []const u8 {
        const len = std.mem.len(self.path);
        return self.path[0..len];
    }
};

const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: [*]*const File,
};

const ModuleRequest = extern struct {
    id: [4]u64 = request_id(0x3e7e279702be32af, 0xca1c4f3bd1280cee),
    revision: u64 = 0,
    response: ?*ModuleResponse = null,
};

pub export var MODULES linksection(".requests") = ModuleRequest{};
