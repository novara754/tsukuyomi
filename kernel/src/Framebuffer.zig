const limine = @import("limine.zig");
const panic = @import("panic.zig").panic;

/// width in pixels
width: u64,

/// height in pixels
height: u64,

/// number of bytes per row
pitch: u64,

/// bytes per pixel
bpp: u64,

/// frame data
buffer: [*]Pixel,

const Self = @This();

const Pixel = extern struct { b: u8, g: u8, r: u8, a: u8 };

pub fn fromLimine(limine_fb: *const limine.Framebuffer) Self {
    if (limine_fb.memory_model != .bgr) {
        panic("Framebuffer.fromLimine: incorrect memory model {}", .{limine_fb.memory_model});
    }
    return .{
        .width = limine_fb.width,
        .height = limine_fb.height,
        .pitch = limine_fb.pitch,
        .bpp = limine_fb.bpp / 8,
        .buffer = @ptrCast(limine_fb.address),
    };
}

pub fn pixel(self: *Self, x: u64, y: u64) *Pixel {
    if (x > self.width or y > self.height) {
        panic("Framebuffer.pixel: out of range", .{});
    }

    return &self.buffer[y * self.width + x];
}
