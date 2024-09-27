const std = @import("std");

const SYS_EXIT = 60;
const SYS_WRITE = 1;

pub const STDOUT_FILENO: i32 = 1;

fn syscall1(nr: u64, rdi: u64) u64 {
    return asm volatile ("int $0x40"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [rdi] "{rdi}" (rdi),
    );
}

fn syscall3(nr: u64, rdi: u64, rsi: u64, rdx: u64) u64 {
    return asm volatile ("int $0x40"
        : [ret] "={rax}" (-> u64),
        : [nr] "{rax}" (nr),
          [rdi] "{rdi}" (rdi),
          [rsi] "{rsi}" (rsi),
          [rdx] "{rdx}" (rdx),
    );
}

fn write(fd: c_int, buf: [*]const u8, count: usize) isize {
    return @intCast(syscall3(SYS_WRITE, @intCast(fd), @intFromPtr(buf), @intCast(count)));
}

fn _exit(status: c_int) noreturn {
    _ = syscall1(SYS_EXIT, @intCast(status));
    unreachable;
}

export fn _start() noreturn {
    const message = "HELLO WORLD!\n";

    while (true) {
        _ = write(STDOUT_FILENO, message, message.len);
        for (0..1_000_000) |i| {
            std.mem.doNotOptimizeAway(i);
        }
    }

    // _exit(@intCast(write(STDOUT_FILENO, message, message.len)));
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _exit(200);
}
