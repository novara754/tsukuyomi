const std = @import("std");
const limine = @import("limine.zig");
const panic = @import("panic.zig").panic;
const heap = @import("heap.zig");

/// width in pixels
width: u64,

/// height in pixels
height: u64,

/// number of bytes per row
pitch: u64,

/// bytes per pixel
bpp: u64,

/// frame data
present_buffer: []volatile Pixel,

draw_buffer: []Pixel,

const Self = @This();

pub const Pixel = extern struct { b: u8 = 0, g: u8 = 0, r: u8 = 0, a: u8 = 255 };

pub const Rect = struct {
    x: u64,
    y: u64,
    height: u64,
    width: u64,
};

pub fn fromLimine(limine_fb: *const limine.Framebuffer) Self {
    if (limine_fb.memory_model != .bgr) {
        panic("Framebuffer.fromLimine: incorrect memory model {}", .{limine_fb.memory_model});
    }

    const pixels_count = limine_fb.width * limine_fb.height;
    const present_buffer: [*]Pixel = @ptrCast(limine_fb.address);
    const draw_buffer: []Pixel = heap.allocator().alloc(Pixel, pixels_count) catch |e| {
        panic("Framebuffer.fromLimine: failed to allocate draw buffer: {}", .{e});
    };

    return .{
        .width = limine_fb.width,
        .height = limine_fb.height,
        .pitch = limine_fb.pitch,
        .bpp = limine_fb.bpp / 8,
        .present_buffer = present_buffer[0..pixels_count],
        .draw_buffer = draw_buffer,
    };
}

pub fn pixel(self: *Self, x: u64, y: u64) *Pixel {
    if (x > self.width or y > self.height) {
        panic("Framebuffer.pixel: out of range", .{});
    }

    return &self.draw_buffer[y * self.width + x];
}

pub fn clear(self: *Self, region: ?Rect) void {
    if (region) |r| {
        for (0..r.height) |dy| {
            for (0..r.width) |dx| {
                self.pixel(r.x + dx, r.y + dy).* = .{};
            }
        }
    } else {
        for (self.draw_buffer) |*p| {
            p.* = .{};
        }
    }
}

pub fn present(self: *Self, region: ?Rect) void {
    if (region) |r| {
        for (r.y..(r.y + r.height)) |y| {
            const start = y * self.width + r.x;
            const end = y * self.width + r.x + r.width;
            for (self.present_buffer[start..end], self.draw_buffer[start..end]) |*d, s| {
                d.* = s;
            }
        }
    } else {
        for (self.present_buffer, self.draw_buffer) |*d, s| {
            d.* = s;
        }
    }
}

pub fn copyRegion(self: *Self, src: Rect, dst: Rect) void {
    if ((src.x + src.width) > self.width or (src.y + src.height) > self.height or src.width > self.width or src.height > self.height) {
        panic("Framebuffer.copyRegion: src rect out of bounds", .{});
    }

    if ((dst.x + dst.width) > self.width or (dst.y + dst.height) > self.height or dst.width > self.width or dst.height > self.height) {
        panic("Framebuffer.copyRegion: dst rect out of bounds", .{});
    }

    if (src.width != dst.width or src.height != dst.height) {
        panic("Framebuffer.copyRegion: dimensions mismatch", .{});
    }

    if (src.width == self.width) {
        const dst_start = dst.y * self.width;
        const dst_end = (dst.y + dst.height) * self.width;
        const src_start = src.y * self.width;
        const src_end = (src.y + src.height) * self.width;
        if (dst_start < src_start) {
            std.mem.copyForwards(Pixel, self.draw_buffer[dst_start..dst_end], self.draw_buffer[src_start..src_end]);
        } else {
            std.mem.copyBackwards(Pixel, self.draw_buffer[dst_start..dst_end], self.draw_buffer[src_start..src_end]);
        }
    } else {
        panic("Framebuffer.copyRegion: not implemented if src.width != self.width", .{});
    }
}
