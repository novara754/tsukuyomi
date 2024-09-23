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

extern fn loadGDT(ptr: *const GDTP, cs: u16, ds: u16) callconv(.SysV) void;

pub fn loadKernelGDT() void {
    const gdtp = GDTP{
        .size = @intCast(@sizeOf(@TypeOf(GDT_KERNEL)) - 1),
        .offset = @intFromPtr(&GDT_KERNEL),
    };
    loadGDT(&gdtp, SEG_KERNEL_CODE << 3, SEG_KERNEL_DATA << 3);
}
