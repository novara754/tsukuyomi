const std = @import("std");
const Spinlock = @import("../Spinlock.zig");
const process = @import("../process.zig");
const Terminal = @import("../Terminal.zig");

const RingBuffer = struct {
    data: [512]u8 = undefined,
    available_idx: usize = 0,
    write_idx: usize = 0,
    read_idx: usize = 0,

    const Self = @This();

    fn put(self: *Self, b: u8) void {
        self.data[self.write_idx] = b;

        self.write_idx += 1;
        if (self.write_idx == self.data.len) {
            self.write_idx = 0;
        }

        if (self.write_idx == self.read_idx) {
            self.advanceReadIdx();
        }
    }

    fn pop(self: *Self) ?u8 {
        if (self.isEmpty()) {
            return null;
        }

        const b = self.data[self.read_idx];
        self.advanceReadIdx();
        return b;
    }

    fn back(self: *Self) bool {
        if (self.write_idx == self.available_idx) {
            return false;
        }

        if (self.write_idx == 0) {
            self.write_idx = self.data.len - 1;
        } else {
            self.write_idx -= 1;
        }

        return true;
    }

    fn isEmpty(self: *const Self) bool {
        return self.read_idx == self.available_idx;
    }

    fn commit(self: *Self) void {
        self.available_idx = self.write_idx;
    }

    fn advanceReadIdx(self: *Self) void {
        const was_empty = self.isEmpty();

        self.read_idx += 1;
        if (self.read_idx == self.data.len) {
            self.read_idx = 0;
        }

        if (was_empty) {
            self.available_idx = self.read_idx;
        }
    }
};

var LOCK = Spinlock{};
var BUFFER = RingBuffer{};

pub fn put(b: u8) void {
    LOCK.acquire();
    defer LOCK.release();

    const term = &(Terminal.SINGLETON orelse return);

    if (b == '\n') {
        BUFFER.put('\n');
        BUFFER.commit();

        term.putc('\n');

        process.awaken(@intFromPtr(&BUFFER));
    } else if (b == 8) {
        // 8 = backspace
        if (BUFFER.back()) {
            term.putc(8);
            term.putc(' ');
            term.putc(8);
        }
    } else {
        BUFFER.put(b);
        term.putc(b);
    }
}

pub fn read(dst: []u8) u64 {
    LOCK.acquire();
    defer LOCK.release();

    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        while (BUFFER.isEmpty()) {
            process.sleep(@intFromPtr(&BUFFER), &LOCK);
        }

        dst[i] = BUFFER.pop() orelse unreachable;
    }

    return i;
}

pub fn write(src: []const u8) u64 {
    if (Terminal.SINGLETON) |*term| {
        term.puts(src);
        return src.len;
    } else {
        return ~@as(u64, 0);
    }
}
