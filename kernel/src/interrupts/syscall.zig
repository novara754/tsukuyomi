const std = @import("std");
const TrapFrame = @import("idt.zig").TrapFrame;
const panic = @import("../panic.zig").panic;
const process = @import("../process.zig");
const vfs = @import("../vfs.zig");
const logger = @import("../logger.zig");

const STDIN_FILENO = 0;
const STDOUT_FILENO = 1;
const STDERR_FILENO = 2;

const O_RDONLY = 0;
const O_WRONLY = 1;
const O_RDWR = 2;

const SYS_READ = 0;
const SYS_WRITE = 1;
const SYS_OPEN = 2;
const SYS_CLOSE = 3;
const SYS_GETDIRENTS = 4;
const SYS_FORK = 57;
const SYS_EXECVE = 59;
const SYS_EXIT = 60;
const SYS_WAIT = 61;

pub fn doSyscall(tf: *TrapFrame) void {
    const proc = process.CPU_STATE.process orelse {
        panic("doSyscall called without process", .{});
    };

    logger.log(.debug, "syscall", "pid={}, nr={}, rdi={x}, rsi={x}, rdx={x}", .{ proc.pid, tf.rax, tf.rdi, tf.rsi, tf.rdx });

    const sp = asm volatile ("mov %rsp, %rax"
        : [ret] "={rax}" (-> u64),
        :
        : "{rax}"
    );
    @import("../logger.zig").log(.debug, "syscall", "pid={}, sp={x}", .{ proc.pid, sp });

    swtch: {
        switch (tf.rax) {
            SYS_READ => {
                const fd = tf.rdi;
                const buf: [*]u8 = @ptrFromInt(tf.rsi);
                const count = tf.rdx;

                if (!isUserPointer(buf)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                const file = proc.files[fd] orelse {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                };

                const dst = buf[0..count];
                tf.rax = vfs.read(file, dst);
            },
            SYS_WRITE => {
                const fd = tf.rdi;
                const buf: [*]const u8 = @ptrFromInt(tf.rsi);
                const count = tf.rdx;

                if (!isUserPointer(buf)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                const file = proc.files[fd] orelse {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                };

                const src = buf[0..count];
                tf.rax = vfs.write(file, src);
            },
            SYS_OPEN => {
                const filename: [*:0]const u8 = @ptrFromInt(tf.rdi);

                if (!isUserPointer(filename)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                const filename_len = std.mem.len(filename);
                const path = filename[0..filename_len];

                if (vfs.open(path)) |file| {
                    tf.rax = process.addOpenFile(proc, file) catch ~@as(u64, 0);
                    break :swtch;
                } else {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }
            },
            SYS_GETDIRENTS => {
                const fd = tf.rdi;
                const buf: [*]vfs.DirEntry = @ptrFromInt(tf.rsi);
                const count = tf.rdx;

                @import("../logger.zig").log(.debug, "syscall", "1", .{});

                if (!isUserPointer(buf)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                @import("../logger.zig").log(.debug, "syscall", "2", .{});
                const file = proc.files[fd] orelse {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                };

                @import("../logger.zig").log(.debug, "syscall", "3", .{});
                const entries_buf = buf[0..count];

                @import("../logger.zig").log(.debug, "syscall", "4", .{});
                tf.rax = vfs.getdirents(file, entries_buf) catch {
                    @import("../logger.zig").log(.debug, "syscall", "ERR", .{});
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                };
            },
            SYS_FORK => {
                tf.rax = process.doFork() catch ~@as(u64, 0);
            },
            SYS_EXECVE => {
                const pathname: [*:0]const u8 = @ptrFromInt(tf.rdi);
                // const _: [*:null]const ?[*:0]const u8 = @ptrFromInt(tf.rsi);
                // const _ = tf.rdx;
                const pathname_len = std.mem.len(pathname);
                const path = pathname[0..pathname_len];
                process.doExec(path) catch |e| {
                    panic("exec: e={}", .{e});
                    tf.rax = ~@as(u64, 0);
                };
            },
            SYS_EXIT => {
                process.doExit(tf.rdi);
            },
            SYS_WAIT => {
                tf.rax = process.wait();
            },
            else => panic("syscall unimplemented: nr={}", .{tf.rax}),
        }
    }

    logger.log(.debug, "syscall", "returning {x}", .{tf.rax});
}

fn isUserPointer(ptr: *const anyopaque) bool {
    return @intFromPtr(ptr) >> 63 == 0;
}
