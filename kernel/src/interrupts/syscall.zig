const TrapFrame = @import("idt.zig").TrapFrame;
const panic = @import("../panic.zig").panic;

pub fn do_syscall(tf: *TrapFrame) void {
    panic("syscall: nr={}", .{tf.rax});
}
