const std = @import("std");

pub const SEG_KERNEL_CODE: u16 = 1;
pub const SEG_KERNEL_DATA: u16 = 2;
pub const SEG_USER_CODE: u16 = 3;
pub const SEG_USER_DATA: u16 = 4;
pub const SEG_TSS: u16 = 5;

const GDT_TEMPLATE = [5]u64{
    0, // null segment
    (0xA << 52) | (0x9A << 40), // kernel code
    (0xC << 52) | (0x92 << 40), // kernel data
    (0xA << 52) | (0xFA << 40), // user code
    (0xC << 52) | (0xF2 << 40), // user data
};

var GDT_KERNEL = GDT_TEMPLATE;

const GDTP = packed struct {
    size: u16,
    offset: u64,
};

// TODO: This could probably be extern instead of packed
// and then rspX and istX can be arrays.
pub const TSS = packed struct {
    _reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    _reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    _reserved2: u64 = 0,
    _reserved3: u16 = 0,
    iopb: u16 = @sizeOf(TSS),
};

extern fn loadGDT(ptr: *const GDTP, cs: u16, ds: u16) callconv(.SysV) void;

pub fn loadKernelGDT() void {
    const gdtp = GDTP{
        .size = @intCast(@sizeOf(@TypeOf(GDT_KERNEL)) - 1),
        .offset = @intFromPtr(&GDT_KERNEL),
    };
    loadGDT(&gdtp, SEG_KERNEL_CODE << 3, SEG_KERNEL_DATA << 3);
}

pub fn loadGDTWithTSS(gdt: *[7]u64, tss: *const TSS) void {
    const tss_base = @intFromPtr(tss);
    const tss_limit = @sizeOf(TSS);
    const tss_segment = [2]u64{
        (((tss_base >> 24) & 0xFF) << 56) | (0x4 << 52) | (((tss_limit >> 16) & 0xF) << 48) | (0x89 << 40) | ((tss_base & 0xFF_FFFF) << 16) | (tss_limit & 0xFFFF),
        tss_base >> 32,
    };

    gdt.* = GDT_TEMPLATE ++ tss_segment;

    const gdtp = GDTP{
        .size = @intCast(gdt.len * @sizeOf(u64) - 1),
        .offset = @intFromPtr(gdt),
    };
    loadGDT(&gdtp, SEG_KERNEL_CODE << 3, SEG_KERNEL_DATA << 3);
    asm volatile ("ltr %ax"
        :
        : [seg_tss] "{ax}" (SEG_TSS << 3),
    );
}
