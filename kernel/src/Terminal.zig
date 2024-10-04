//! Text-mode terminal using framebuffer.

const std = @import("std");
const Framebuffer = @import("Framebuffer.zig");
const psf = @import("psf.zig");
const panic = @import("panic.zig").panic;

/// Width in number of characers
width: u64,
/// Height in number of characters
height: u64,
/// Current cursor position
cursor_pos: Position = .{ .x = 0, .y = 0 },

/// Framebuffer to draw text to
framebuffer: Framebuffer,

/// Font to use for text output
font: psf.Font,
/// When attempting to draw a character that doesn't exist in `font`
/// this glyph will be drawn instead
fallback_glyph: psf.Font.Glyph,

const Self = @This();

/// Position struct for the cursor position
const Position = struct { x: u64, y: u64 };

/// Construct a terminal for the given framebuffer and the given font.
/// Uses the glyph for `?` as the fallback glyph.
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

/// Output formatted text to the terminal.
pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
    std.fmt.format(Writer{ .terminal = self }, fmt, args) catch |e| {
        panic("Terminal.print: {}", .{e});
    };
}

/// Write a string to the terminal at the current cursor position.
///
/// A line break ('\n') or carriage return ('\r') does not get rendered, move the cursor to the next
/// line or start of line respectively.
pub fn puts(self: *Self, s: []const u8) void {
    // Record the current line position...
    const start_y = self.cursor_pos.y;

    for (s) |c| {
        self.putcInner(c);
    }

    // ...and record the new line position...
    const end_y = self.cursor_pos.y;

    // ..., then tell the framebuffer to present the part draw buffer
    // in that range.
    // This is more efficient than presenting the whole buffer every time
    // if only a small part of the screen was changed.
    self.framebuffer.present(.{
        .x = 0,
        .y = start_y * self.font.glyph_height,
        .width = self.framebuffer.width,
        .height = (end_y - start_y) * self.font.glyph_height,
    });
}

/// Write a single character to the terminal at the current cursor position.
///
/// A line break ('\n') or carriage return ('\r') does not get rendered, move the cursor to the next
/// line or start of line respectively.
pub fn putc(self: *Self, c: u8) void {
    // Record the position the cursor is at before writing the character...
    const pos = self.cursor_pos;

    self.putcInner(c);

    // ...and then present the portion of the buffer where the character was drawn.
    // This is *way* more efficient than redrawing the whole screen.
    self.framebuffer.present(.{
        .x = pos.x * self.font.glyph_width,
        .y = pos.y * self.font.glyph_height,
        .width = self.font.glyph_width,
        .height = self.font.glyph_height,
    });
}

/// This function is called by `putc` and `puts` and does the heavy lifting of
/// fetching the appropriate glyph for the given character and drawing it to the current
/// cursor position.
///
/// A line break ('\n') or carriage return ('\r') does not get rendered, move the cursor to the next
/// line or start of line respectively.
///
/// Characters for which there is no glyph in the `font` will be drawn using `fallback_glyph`
/// instead.
fn putcInner(self: *Self, c: u8) void {
    if (c == '\n') {
        self.nextLine();
        return;
    }

    if (c == '\r') {
        self.cursor_pos.x = 0;
        return;
    }

    const glyph = self.font.glyph(c) orelse self.fallback_glyph;

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

/// Helper function to move the cursor to the next line.
/// If the cursor is already on the last line it scrolls the output up by one line
/// to make space.
fn nextLine(self: *Self) void {
    self.cursor_pos.x = 0;
    if (self.cursor_pos.y == self.height - 1) {
        self.scroll();
    } else {
        self.cursor_pos.y += 1;
    }
}

/// Scrolls the output up by one line by copying the frame data for line 1 to n
/// up, so it ends up overwriting line 0 to (n-1).
/// Then the last line is cleared, otherwise the last line would appear twice after the copy.
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

/// Writer struct for the `Terminal.print` function.
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
