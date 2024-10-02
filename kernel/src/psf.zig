const PSF_VERSION1_MAGIC: u16 = 0x0436;

pub const Font = struct {
    /// total number of glyphs available in the font
    glyphs_count: u64,
    /// width of each glyph in pixels
    glyph_width: u8,
    /// height of each glyph in pixels
    glyph_height: u8,
    has_unicode_table: bool,
    data: []const u8,

    pub const Self = @This();

    pub const Glyph = []const u8;

    pub fn fromBytes(data: []const u8) !Self {
        if (data.len < 4) {
            return error.MissingHeader;
        }

        const magic = (@as(u16, data[1]) << 8) | @as(u16, data[0]);
        if (magic != PSF_VERSION1_MAGIC) {
            return error.InvalidMagic;
        }

        const mode = data[2];
        const glyphs_count: u64 = if (mode & 0b1 == 0) 256 else 512;
        const has_unicode_table = mode & 0b110 != 0;
        const glyph_height = data[3];

        return .{
            .glyphs_count = glyphs_count,
            .glyph_width = 8,
            .glyph_height = glyph_height,
            .has_unicode_table = has_unicode_table,
            .data = data[4..],
        };
    }

    pub fn glyph(self: *const Self, n: u64) ?Glyph {
        if (n > self.glyphs_count) {
            return null;
        }

        const len = self.glyph_height;
        const i = n * len;
        return self.data[i..(i + len)];
    }
};
