const std = @import("std");
const Framebuffer = @import("Framebuffer.zig");
const psf = @import("psf.zig");
const panic = @import("panic.zig").panic;

/// width in number of characers
width: u64,
/// height in number of characters
height: u64,
cursor_pos: Position = .{ .x = 0, .y = 0 },

framebuffer: Framebuffer,

font: psf.Font,
fallback_glyph: psf.Font.Glyph,

const Self = @This();

const Position = struct { x: u64, y: u64 };

pub fn new(fb: Framebuffer, font: psf.Font) Self {
    const fallback_glyph = font.glyph('?') orelse {
        panic("Terminal.new: glyph for `?` not available", .{});
    };
    var framebuffer = fb;
    framebuffer.clear(null);
    return .{
        .width = fb.width / font.glyph_width,
        .height = fb.height / font.glyph_height,
        .framebuffer = fb,
        .font = font,
        .fallback_glyph = fallback_glyph,
    };
}

pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(self.writer(), fmt, args) catch |e| {
        panic("Terminal.print: {}", .{e});
    };
}

pub fn puts(self: *Self, s: []const u8) void {
    const start_y = self.cursor_pos.y;

    for (s) |c| {
        self.putcInner(c);
    }

    const end_y = self.cursor_pos.y;

    self.framebuffer.present(.{
        .x = 0,
        .y = start_y * self.font.glyph_height,
        .width = self.framebuffer.width,
        .height = (end_y - start_y) * self.font.glyph_height,
    });
}

pub fn putc(self: *Self, c: u8) void {
    const pos = self.cursor_pos;

    self.putcInner(c);
    self.framebuffer.present(.{
        .x = pos.x * self.font.glyph_width,
        .y = pos.y * self.font.glyph_height,
        .width = self.font.glyph_width,
        .height = self.font.glyph_height,
    });
}

pub fn putcInner(self: *Self, c: u8) void {
    if (c == '\n') {
        self.nextLine();
        return;
    }

    if (c == '\r') {
        self.cursor_pos.x = 0;
        return;
    }

    const glyph = self.font.glyph(c) orelse {
        panic("Terminal.putc: no glyph for character {}", .{c});
    };

    for (glyph, 0..) |row_bits, row_idx| {
        var bit_idx: u8 = 0;
        while (bit_idx <= 7) : (bit_idx += 1) {
            const bit_idx_u3: u3 = @intCast(bit_idx);
            const bit = (row_bits >> (7 - bit_idx_u3)) & 1;
            const color: u8 = if (bit == 0) 0x00 else 0xFF;
            const x = bit_idx + self.cursor_pos.x * self.font.glyph_width;
            const y = row_idx + self.cursor_pos.y * self.font.glyph_height;
            const pixel = self.framebuffer.pixel(x, y);
            pixel.* = .{
                .r = color,
                .g = color,
                .b = color,
            };
        }
    }

    self.cursor_pos.x += 1;
    if (self.cursor_pos.x >= self.width) {
        self.nextLine();
    }
}

fn nextLine(self: *Self) void {
    self.cursor_pos.x = 0;
    if (self.cursor_pos.y == self.height - 1) {
        self.scroll();
    } else {
        self.cursor_pos.y += 1;
    }
}

fn scroll(self: *Self) void {
    self.framebuffer.copyRegion(.{
        .x = 0,
        .y = self.font.glyph_height,
        .width = self.framebuffer.width,
        .height = self.framebuffer.height - self.font.glyph_height,
    }, .{
        .x = 0,
        .y = 0,
        .width = self.framebuffer.width,
        .height = self.framebuffer.height - self.font.glyph_height,
    });
    self.framebuffer.clear(.{
        .x = 0,
        .y = self.framebuffer.height - self.font.glyph_height,
        .width = self.framebuffer.width,
        .height = self.font.glyph_height,
    });
    self.framebuffer.present(null);
}

const Writer = struct {
    terminal: *Self,

    pub const Error = error{};

    pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
        self.terminal.puts(bytes);
    }

    pub fn writeBytesNTimes(self: @This(), bytes: []const u8, n: usize) Error!void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.terminal.puts(bytes);
        }
    }
};

fn writer(self: *Self) Writer {
    return .{ .terminal = self };
}
