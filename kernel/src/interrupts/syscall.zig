const std = @import("std");
const TrapFrame = @import("idt.zig").TrapFrame;
const panic = @import("../panic.zig").panic;
const process = @import("../process.zig");
const vfs = @import("../vfs.zig");
const logger = @import("../logger.zig");
const path = @import("../vfs/path.zig");

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
const SYS_SETCWD = 56;
const SYS_FORK = 57;
const SYS_EXECVE = 59;
const SYS_EXIT = 60;
const SYS_WAIT = 61;

pub fn doSyscall(tf: *TrapFrame) void {
    const proc = process.CPU_STATE.process orelse {
        panic("doSyscall called without process", .{});
    };

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

                if (proc.files[fd]) |*file| {
                    const dst = buf[0..count];
                    tf.rax = vfs.read(file, dst);
                } else {
                    tf.rax = ~@as(u64, 0);
                }
            },
            SYS_WRITE => {
                const fd = tf.rdi;
                const buf: [*]const u8 = @ptrFromInt(tf.rsi);
                const count = tf.rdx;

                if (!isUserPointer(buf)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                if (proc.files[fd]) |*file| {
                    const src = buf[0..count];
                    tf.rax = vfs.write(file, src);
                } else {
                    tf.rax = ~@as(u64, 0);
                }
            },
            SYS_OPEN => {
                const filename_ptr: [*:0]const u8 = @ptrFromInt(tf.rdi);

                if (!isUserPointer(filename_ptr)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                const filename_len = std.mem.len(filename_ptr);
                if (filename_len >= 255) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                const filename = filename_ptr[0..filename_len];

                // var path_arr: [MAX_PATH_LEN:0]u8 = undefined;
                // var path_slice: []const u8 = undefined;
                // if (filename[0] == '/') {
                //     path_slice = filename;
                // } else if (std.mem.eql(u8, filename, ".")) {
                //     const cwd_len = std.mem.indexOfScalar(u8, &proc.cwd, 0).?;
                //     path_slice = proc.cwd[0..cwd_len];
                // } else {
                //     const cwd_len = std.mem.indexOfScalar(u8, &proc.cwd, 0).?;
                //     path_slice = std.fmt.bufPrintZ(&path_arr, "{s}/{s}", .{ proc.cwd[0..cwd_len], filename }) catch {
                //         tf.rax = ~@as(u64, 0);
                //         break :swtch;
                //     };
                // }

                var path_buf: [path.MAX_PATH_LEN]u8 = undefined;
                var path_slice: []const u8 = undefined;
                if (path.isAbsolute(filename)) {
                    path_slice = filename;
                } else {
                    path_slice = path.resolve(&path_buf, proc.getCWD(), filename) catch {
                        tf.rax = ~@as(u64, 0);
                        break :swtch;
                    };
                }

                logger.log(.debug, "syscall", "open path_slice={s}", .{path_slice});

                if (vfs.open(path_slice)) |file| {
                    tf.rax = process.addOpenFile(proc, file) catch ~@as(u64, 0);
                } else {
                    tf.rax = ~@as(u64, 0);
                }
            },
            SYS_GETDIRENTS => {
                const fd = tf.rdi;
                const buf: [*]vfs.DirEntry = @ptrFromInt(tf.rsi);
                const count = tf.rdx;

                if (!isUserPointer(buf)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                if (proc.files[fd]) |*file| {
                    const entries_buf = buf[0..count];

                    tf.rax = vfs.getdirents(file, entries_buf) catch {
                        tf.rax = ~@as(u64, 0);
                        break :swtch;
                    };
                } else {
                    tf.rax = ~@as(u64, 0);
                }
            },
            SYS_SETCWD => {
                const filename_ptr: [*:0]const u8 = @ptrFromInt(tf.rdi);
                if (!isUserPointer(filename_ptr)) {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }

                const filename_len = std.mem.len(filename_ptr);
                const filename = filename_ptr[0..filename_len];

                var path_buf: [path.MAX_PATH_LEN]u8 = undefined;
                var path_slice: []const u8 = undefined;
                if (path.isAbsolute(filename)) {
                    path_slice = filename;
                } else {
                    path_slice = path.resolve(&path_buf, proc.getCWD(), filename) catch {
                        tf.rax = ~@as(u64, 0);
                        break :swtch;
                    };
                }

                if (vfs.open(path_slice)) |_| {
                    _ = std.fmt.bufPrintZ(&proc.cwd, "{s}", .{path_slice}) catch {
                        tf.rax = ~@as(u64, 0);
                        break :swtch;
                    };
                } else {
                    tf.rax = ~@as(u64, 0);
                    break :swtch;
                }
            },
            SYS_FORK => {
                tf.rax = process.doFork() catch ~@as(u64, 0);
            },
            SYS_EXECVE => {
                const filename_ptr: [*:0]const u8 = @ptrFromInt(tf.rdi);
                // const _: [*:null]const ?[*:0]const u8 = @ptrFromInt(tf.rsi);
                // const _ = tf.rdx;
                const filename_len = std.mem.len(filename_ptr);
                const filename = filename_ptr[0..filename_len];
                process.doExec(filename) catch |e| {
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
}

fn isUserPointer(ptr: *const anyopaque) bool {
    return @intFromPtr(ptr) >> 63 == 0;
}
