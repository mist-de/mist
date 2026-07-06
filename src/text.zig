const std = @import("std");
const c = @import("c.zig").c;
const Color = @import("config.zig").Color;
const Canvas = @import("render.zig").Canvas;

// ═══════════════════════════════════════════════════════════
// Glyph cache entry
// ═══════════════════════════════════════════════════════════

pub const Glyph = struct {
    width: u32,
    height: u32,
    pitch: i32,
    left: i32,
    top: i32,
    advance_x: i32,
    buf: []u8,

    pub fn deinit(g: *Glyph, allocator: std.mem.Allocator) void {
        allocator.free(g.buf);
    }
};

// ═══════════════════════════════════════════════════════════
// Font (FreeType + HarfBuzz)
// ═══════════════════════════════════════════════════════════

pub const Font = struct {
    allocator: std.mem.Allocator,
    ft_lib: c.FT_Library,
    ft_face: c.FT_Face,
    pixel_size: u32,
    hb_font: *c.hb_font_t,
    hb_buf: *c.hb_buffer_t,
    cache: std.AutoHashMapUnmanaged(u32, Glyph),

    pub fn init(allocator: std.mem.Allocator, path: []const u8, pixel_size: u32) !Font {
        var ft_lib: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;

        var ft_face: c.FT_Face = undefined;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        if (c.FT_New_Face(ft_lib, path_z, 0, &ft_face) != 0) {
            _ = c.FT_Done_FreeType(ft_lib);
            return error.FontNotFound;
        }

        if (c.FT_Set_Pixel_Sizes(ft_face, 0, pixel_size) != 0) {
            _ = c.FT_Done_Face(ft_face);
            _ = c.FT_Done_FreeType(ft_lib);
            return error.FontSizeInvalid;
        }

        const hb_font = c.hb_ft_font_create_referenced(ft_face).?;
        const hb_buf = c.hb_buffer_create().?;

        return Font{
            .allocator = allocator,
            .ft_lib = ft_lib,
            .ft_face = ft_face,
            .pixel_size = pixel_size,
            .hb_font = hb_font,
            .hb_buf = hb_buf,
            .cache = .{},
        };
    }

    pub fn deinit(f: *Font) void {
        var iter = f.cache.iterator();
        while (iter.next()) |entry| {
            var g = &entry.value_ptr.*;
            g.deinit(f.allocator);
        }
        f.cache.deinit(f.allocator);
        c.hb_buffer_destroy(f.hb_buf);
        c.hb_font_destroy(f.hb_font);
        _ = c.FT_Done_Face(f.ft_face);
        _ = c.FT_Done_FreeType(f.ft_lib);
    }

    pub fn getGlyph(f: *Font, codepoint: u32) !*const Glyph {
        const gop = try f.cache.getOrPut(f.allocator, codepoint);
        if (gop.found_existing) return gop.value_ptr;

        const glyph_index = c.FT_Get_Char_Index(f.ft_face, codepoint);
        if (glyph_index == 0) return error.GlyphNotFound;

        if (c.FT_Load_Glyph(f.ft_face, glyph_index, c.FT_LOAD_RENDER) != 0) {
            return error.GlyphRenderFailed;
        }

        const slot = f.ft_face.*.glyph;
        const bitmap = slot.*.bitmap;
        const pitch = bitmap.pitch;
        const rows = bitmap.rows;
        const buf_len: usize = @intCast(@abs(pitch) * rows);
        const buf = try f.allocator.alloc(u8, buf_len);
        @memcpy(buf, bitmap.buffer[0..buf_len]);

        gop.value_ptr.* = Glyph{
            .width = @intCast(bitmap.width),
            .height = @intCast(rows),
            .pitch = pitch,
            .left = slot.*.bitmap_left,
            .top = slot.*.bitmap_top,
            .advance_x = @intCast(slot.*.metrics.horiAdvance >> 6),
            .buf = buf,
        };

        return gop.value_ptr;
    }

    pub fn baselineOffset(f: *const Font) i32 {
        const ascender: i32 = @intCast(f.ft_face.*.size.*.metrics.ascender >> 6);
        return ascender;
    }

    pub fn lineHeight(f: *const Font) i32 {
        const ascender: i32 = @intCast(f.ft_face.*.size.*.metrics.ascender >> 6);
        const descender: i32 = @intCast(f.ft_face.*.size.*.metrics.descender >> 6);
        return ascender - descender;
    }
};

// ═══════════════════════════════════════════════════════════
// Text shaping + rendering (HarfBuzz)
// ═══════════════════════════════════════════════════════════

fn utf8ToCodepoints(text: []const u8, buf: []u32) usize {
    var i: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| : (i += 1) {
        if (i >= buf.len) return i;
        buf[i] = cp;
    }
    return i;
}

fn shape(font: *Font, text: []const u8, count: *c_uint) struct { [*c]c.hb_glyph_info_t, [*c]c.hb_glyph_position_t } {
    var buf: [256]u32 = undefined;
    const len = utf8ToCodepoints(text, &buf);
    c.hb_buffer_reset(font.hb_buf);
    if (len > 0) {
        c.hb_buffer_add_utf32(font.hb_buf, &buf, @intCast(len), 0, @intCast(len));
    }
    c.hb_buffer_set_direction(font.hb_buf, c.HB_DIRECTION_LTR);
    c.hb_buffer_set_script(font.hb_buf, c.HB_SCRIPT_LATIN);
    c.hb_buffer_set_language(font.hb_buf, c.hb_language_from_string("en", 2));
    c.hb_shape(font.hb_font, font.hb_buf, null, 0);
    const info = c.hb_buffer_get_glyph_infos(font.hb_buf, count);
    const pos = c.hb_buffer_get_glyph_positions(font.hb_buf, count);
    return .{ info, pos };
}

pub fn renderText(canvas: *Canvas, font: *Font, text: []const u8, x: i32, y: i32, color: Color) void {
    if (color.a == 0 or text.len == 0) return;

    var glyph_count: c_uint = 0;
    const info, const pos = shape(font, text, &glyph_count);
    if (glyph_count == 0) return;

    var pen_x: i32 = x;
    const baseline_y: i32 = y;

    var i: u32 = 0;
    while (i < glyph_count) : (i += 1) {
        const gi = info[i];
        const gp = pos[i];
        const x_offset: i32 = @intCast(gp.x_offset >> 6);
        const y_offset: i32 = @intCast(gp.y_offset >> 6);
        const x_advance: i32 = @intCast(gp.x_advance >> 6);
        const glyph = font.getGlyph(gi.codepoint) catch {
            pen_x += x_advance;
            continue;
        };

        const dst_x = pen_x + x_offset + glyph.left;
        const dst_y = baseline_y + y_offset - glyph.top;

        canvas.blitGray(dst_x, dst_y, @intCast(glyph.width), @intCast(glyph.height), glyph.pitch, glyph.buf, color);

        pen_x += x_advance;
    }
}

pub fn textWidth(font: *Font, text: []const u8) i32 {
    if (text.len == 0) return 0;

    var glyph_count: c_uint = 0;
    const info_discard, const pos = shape(font, text, &glyph_count);
    _ = info_discard;
    if (glyph_count == 0) return 0;

    var total: i32 = 0;
    var i: u32 = 0;
    while (i < glyph_count) : (i += 1) {
        total += @as(i32, @intCast(pos[i].x_advance >> 6));
    }
    return total;
}
