const std = @import("std");
const mem = @import("mem.zig");

fn requestId(comptime first: u64, comptime second: u64) [4]u64 {
    return [4]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, first, second };
}

// pub export var BASE_REVISION linksection(".requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2 };
export var BASE_REVISION_INNER linksection(".requests") = [3]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2 };
pub const BASE_REVISION: *const volatile [3]u64 = &BASE_REVISION_INNER;

const HHDMResponse = extern struct {
    revision: u64,
    offset: u64,
};

const HHDMRequest = extern struct {
    id: [4]u64 = requestId(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: ?*HHDMResponse = null,
};

export var HHDM_INNER linksection(".requests") = HHDMRequest{};
pub const HHDM: *const volatile HHDMRequest = &HHDM_INNER;

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
    id: [4]u64 = requestId(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
    revision: u64 = 0,
    response: ?*MemoryMapResponse = null,
};

export var MEMORY_MAP_INNER linksection(".requests") = MemoryMapRequest{};
pub const MEMORY_MAP: *const volatile MemoryMapRequest = &MEMORY_MAP_INNER;

const RSDPResponse = extern struct {
    revision: u64,
    rsdp_addr: u64,
};

const RSDPRequest = extern struct {
    id: [4]u64 = requestId(0xc5e77b6b397e7b43, 0x27637845accdcf3c),
    revision: u64 = 0,
    response: ?*RSDPResponse = null,
};

pub export var RSDP_INNER linksection(".requests") = RSDPRequest{};
pub const RSDP: *const volatile RSDPRequest = &RSDP_INNER;

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

    pub fn pathSlice(self: *const @This()) []const u8 {
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
    id: [4]u64 = requestId(0x3e7e279702be32af, 0xca1c4f3bd1280cee),
    revision: u64 = 0,
    response: ?*ModuleResponse = null,
};

pub export var MODULES_INNER linksection(".requests") = ModuleRequest{};
pub const MODULES: *const volatile ModuleRequest = &MODULES_INNER;

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    /// bits per pixel
    bpp: u16,
    memory_model: MemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: *anyopaque,

    // response revision 1
    mode_count: u64,
    modes: [*]const *VideoMode,

    const MemoryModel = enum(u8) {
        bgr = 1,
    };

    const VideoMode = extern struct {
        pitch: u64,
        width: u64,
        height: u64,
        bpp: u16,
        memory_model: u8,
        red_mask_size: u8,
        red_mask_shift: u8,
        green_mask_size: u8,
        green_mask_shift: u8,
        blue_mask_size: u8,
        blue_mask_shift: u8,
    };
};

const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]const *Framebuffer,
};

const FramebufferRequest = extern struct {
    id: [4]u64 = requestId(0x9d5827dcd881dd75, 0xa3148604f6fab11b),
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};

pub export var FRAMEBUFFER_INNER linksection(".requests") = FramebufferRequest{ .revision = 1 };
pub const FRAMEBUFFER: *const volatile FramebufferRequest = &FRAMEBUFFER_INNER;
