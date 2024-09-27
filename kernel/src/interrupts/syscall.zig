const TrapFrame = @import("idt.zig").TrapFrame;
const panic = @import("../panic.zig").panic;

const SYS_EXIT = 60;
const SYS_WRITE = 1;

pub const STDOUT_FILENO: i32 = 1;

pub fn do_syscall(tf: *TrapFrame) void {
    switch (tf.rax) {
        SYS_WRITE => {
            const fd = tf.rdi;
            const buf: [*]u8 = @ptrFromInt(tf.rsi);
            const count = tf.rdx;

            if (fd != STDOUT_FILENO) {
                tf.rax = ~@as(u64, 0);
                return;
            }

            if (!isUserPointer(buf)) {
                tf.rax = ~@as(u64, 0);
                return;
            }

            const data = buf[0..count];
            @import("../uart.zig").print("{s}", .{data});

            tf.rax = count;
        },
        SYS_EXIT => {
            panic("sys_exit not implemented", .{});
        },
        else => panic("syscall unimplemented: nr={}", .{tf.rax}),
    }
}

fn isUserPointer(ptr: *const anyopaque) bool {
    return @intFromPtr(ptr) >> 63 == 0;
}
