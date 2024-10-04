//! PC SCreen Font Ver. 1

/// Magic number to identify PSF V1 font data.
const PSF_VERSION1_MAGIC: u16 = 0x0436;

/// Represents a PSF V1 font.
pub const Font = struct {
    /// Total number of glyphs available in the font
    glyphs_count: u64,
    /// Width of each glyph in pixels
    glyph_width: u8,
    /// Height of each glyph in pixels
    glyph_height: u8,
    /// Whether or not the font has a unicode table.
    /// This will be used to map unicode endpoints to their corresponding glyph.
    /// Not supported.
    has_unicode_table: bool,
    /// Glyph data.
    data: []const u8,

    pub const Self = @This();

    pub const Glyph = []const u8;

    /// Try to parse PSF V1 font.
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

        if (has_unicode_table) {
            return error.UnicodeTable;
        }

        return .{
            .glyphs_count = glyphs_count,
            .glyph_width = 8,
            .glyph_height = glyph_height,
            .has_unicode_table = has_unicode_table,
            .data = data[4..],
        };
    }

    /// Get the glyph for the given character.
    /// Assumes a direct mapping for ASCII to glyph.
    pub fn glyph(self: *const Self, n: u64) ?Glyph {
        if (n > self.glyphs_count) {
            return null;
        }

        const len = self.glyph_height;
        const i = n * len;
        return self.data[i..(i + len)];
    }
};
