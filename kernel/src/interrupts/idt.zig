const gdt = @import("../gdt.zig");

const PRESENT: u8 = 1 << 7;

const DPL_KERNEL: u8 = 0;
const DPL_USER: u8 = 0x3 << 5;

const GATE_INT: u8 = 0xE;
const GATE_TRAP: u8 = 0xF;

const Entry = extern struct {
    offset_lo: u16 = 0,
    segment: u16 = 0,
    ist: u8 = 0,
    flags: u8 = 0,
    offset_mid: u16 = 0,
    offset_hi: u32 = 0,
    _reserved: u32 = 0,

    fn set(self: *@This(), offset: u64, cs: u16, ist: u8, flags: u8) void {
        self.offset_lo = @intCast(offset & 0xFFFF);
        self.offset_mid = @intCast((offset >> 16) & 0xFFFF);
        self.offset_hi = @intCast(offset >> 32);
        self.segment = cs;
        self.ist = ist;
        self.flags = flags | PRESENT;
    }
};

const IDTP = packed struct {
    size: u16,
    offset: u64,
};

var IDT = [1]Entry{Entry{}} ** 256;

pub fn init() void {
    const trap_table = @extern(*const [256]u64, .{ .name = "trap_table" });

    for (trap_table, 0..) |vector, i| {
        const gate_type =
            if (i < 32)
            GATE_TRAP
        else
            GATE_INT;

        // if (i == SYSCALL_VECTOR) {
        //     IDT[i].set(trap, SEG_KERNEL_CODE << 3, 0, DPL_USER | GATE_TRAP);
        // } else {
        IDT[i].set(vector, gdt.SEG_KERNEL_CODE << 3, 0, DPL_KERNEL | gate_type);
        // }
    }

    const idtp = IDTP{
        .size = @intCast(@sizeOf(@TypeOf(IDT)) - 1),
        .offset = @intFromPtr(&IDT),
    };
    asm volatile ("lidt (%rax)"
        :
        : [idtp] "{rax}" (&idtp),
    );
}

const TrapFrame = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    ds: u16,
    _ds_padding: [6]u8,
    es: u16,
    _es_padding: [6]u8,
    r15: u64,
    trap_nr: u64,
    err_code: u64,
    rip: u64,
    cs: u16,
    _cs_padding: [6]u8,
    rflags: u64,
    rsp: u64,
    ss: u16,
    _ss_padding: [6]u8,
};

export fn handle_trap_inner(tf: *TrapFrame) callconv(.SysV) void {
    @import("../panic.zig").panic("trap #{}", .{tf.trap_nr});
}
