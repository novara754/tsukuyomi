const std = @import("std");
const lib = @import("lib.zig");

const PROMPT = "$ ";

fn getc(tty: c_int) ?u8 {
    var c: [1]u8 = undefined;
    if (lib.read(tty, &c, c.len) == 1) {
        return c[0];
    } else {
        return null;
    }
}

fn gets(tty: c_int, line: []u8) usize {
    var i: usize = 0;
    while (getc(tty)) |c| {
        if (i == line.len) {
            break;
        }

        if (c == '\n') {
            break;
        }

        line[i] = c;
        i += 1;
    }
    line[i] = 0;
    return i;
}

export fn _start() noreturn {
    const tty = lib.open("/dev/tty", lib.O_RDWR);
    // open tty twice more for fd 1 and 2 for child processes
    _ = lib.open("/dev/tty", lib.O_RDWR);
    _ = lib.open("/dev/tty", lib.O_RDWR);
    if (tty < 0) {
        @panic("failed to open /dev/tty\n");
    }
    while (true) {
        _ = lib.write(tty, PROMPT, 2);

        var line: [128:0]u8 = undefined;
        const line_len = gets(tty, &line);
        if (line_len == 0) {
            continue;
        }

        if (std.mem.startsWith(u8, line[0..line_len], "cd ")) {
            const path = line[3..];
            if (lib.setcwd(path) < 0) {
                _ = lib.write(lib.STDOUT_FILENO, "cd failed\n", 10);
            }
            continue;
        }

        const pid = lib.fork();
        if (pid < 0) {
            @panic("fork failed");
        } else if (pid == 0) {
            // child
            const argv = [2:null]?[*:0]const u8{ &line, null };
            const envp = [1:null]?[*:0]const u8{null};
            lib._exit(lib.execve(&line, &argv, &envp));
        } else {
            // parent
            _ = lib.wait();
        }
    }
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = lib.write(lib.STDOUT_FILENO, msg.ptr, msg.len);
    lib._exit(200);
}
