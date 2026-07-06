const std = @import("std");

// ═══════════════════════════════════════════════════════════
// Geometry types
// ═══════════════════════════════════════════════════════════

pub const Point = struct {
    x: i32,
    y: i32,
    pub const zero: Point = .{ .x = 0, .y = 0 };
};

pub const Size = u32;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: Size,
    height: Size,
    pub const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
};

// ═══════════════════════════════════════════════════════════
// Color
// ═══════════════════════════════════════════════════════════

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn toPixel(self: Color) u32 {
        if (self.a == 0) return 0;
        if (self.a == 255) {
            return 0xFF000000 |
                @as(u32, @intCast(self.r)) << 16 |
                @as(u32, @intCast(self.g)) << 8 |
                @as(u32, @intCast(self.b));
        }
        const a = @as(u32, self.a);
        return (a << 24) |
            (@as(u32, self.r) * a / 255 << 16) |
            (@as(u32, self.g) * a / 255 << 8) |
            (@as(u32, self.b) * a / 255);
    }

    pub fn fromPixel(pixel: u32) Color {
        return .{
            .r = @intCast((pixel >> 16) & 0xFF),
            .g = @intCast((pixel >> 8) & 0xFF),
            .b = @intCast(pixel & 0xFF),
            .a = @intCast((pixel >> 24) & 0xFF),
        };
    }
};

// ═══════════════════════════════════════════════════════════
// Appearance constants (from end-4 Appearance.qml)
// ═══════════════════════════════════════════════════════════

pub const Appearance = struct {
    pub const bar_height: i32 = 40;
    pub const screen_rounding: i32 = 23;
    pub const group_radius: i32 = 12;
    pub const group_margin: i32 = 4;
    pub const center_spacing: i32 = 4;

    pub const ws_btn_size: i32 = 26;
    pub const ws_count: i32 = 5;
    pub const ws_active_margin: i32 = 2;
    pub const ws_bargroup_padding: i32 = 4;

    pub const sidebar_btn_size: i32 = 30;
    pub const sidebar_icon_r: i32 = 10;

    pub const resource_ring_outer: i32 = 10;
    pub const resource_ring_inner: i32 = 8;
    pub const resource_spacing: i32 = 6;

    pub const bat_w: i32 = 30;
    pub const bat_h: i32 = 18;

    pub const rsb_icon_size: i32 = 19;
    pub const rsb_spacing: i32 = 15;
    pub const rsb_icons_count: i32 = 6;

    pub const tray_item_size: i32 = 20;
    pub const tray_overflow_size: i32 = 24;
    pub const tray_col_spacing: i32 = 15;

    pub const font_small: i32 = 12;
    pub const font_normal: i32 = 15;
    pub const font_large: i32 = 17;
    pub const font_larger: i32 = 19;

    // M3 color palette (exact from end-4 Appearance.qml)
    pub const m3background = Color.rgba(0x14, 0x13, 0x13, 0xFF);
    pub const m3on_background = Color.rgba(0xe6, 0xe1, 0xe1, 0xFF);
    pub const m3surface_container_low = Color.rgba(0x1c, 0x1b, 0x1c, 0xFF);
    pub const m3primary = Color.rgba(0xcb, 0xc4, 0xcb, 0xFF);
    pub const m3on_primary = Color.rgba(0x32, 0x2f, 0x34, 0xFF);
    pub const m3on_surface_variant = Color.rgba(0xcb, 0xc5, 0xca, 0xFF);
    pub const m3outline = Color.rgba(0x94, 0x8f, 0x94, 0xFF);
    pub const m3outline_variant = Color.rgba(0x49, 0x46, 0x4a, 0xFF);
    pub const m3secondary_container = Color.rgba(0x4d, 0x4b, 0x4d, 0xFF);
    pub const m3on_secondary_container = Color.rgba(0xec, 0xe6, 0xe9, 0xFF);

    // Semantic layer colors
    pub const col_layer1 = Color.rgba(0x1c, 0x1b, 0x1c, 0xE0);
    pub const col_on_layer0 = m3on_background;
    pub const col_on_layer1 = m3on_surface_variant;
    pub const col_on_layer1_inactive = Color.rgba(0x7d, 0x78, 0x7c, 0xFF);
    pub const col_primary = m3primary;
    pub const col_on_primary = m3on_primary;
    pub const col_secondary_container_alpha = Color.rgba(0x4d, 0x4b, 0x4d, 0x99);
    pub const col_on_secondary_container = m3on_secondary_container;
    pub const col_outline_variant = m3outline_variant;
    pub const col_outline = m3outline;
    pub const col_subtext = m3outline;
};

// ═══════════════════════════════════════════════════════════
// Utility
// ═══════════════════════════════════════════════════════════

pub fn BoundedArray(comptime T: type, comptime max_size: usize) type {
    return struct {
        const Self = @This();
        data: [max_size]T = undefined,
        len: usize = 0,

        pub fn append(self: *Self, item: T) !void {
            if (self.len >= max_size) return error.OutOfMemory;
            self.data[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *Self) []T {
            return self.data[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.data[0..self.len];
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
        }
    };
}

// ═══════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════

pub const Config = struct {
    height: u32 = 40,
    bottom: bool = false,
    font_regular: []const u8 = "Inter_18pt-Regular.ttf",
    font_bold: []const u8 = "Inter_18pt-Bold.ttf",
    font_icon: []const u8 = "NotoSansNerdFont-Regular.ttf",
    font_material: []const u8 = "MaterialSymbolsRounded.ttf",
    font_size: u32 = 15,
    font_size_large: u32 = 17,
};

var global_config: Config = .{};

pub fn get() *const Config {
    return &global_config;
}

fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    return std.c.access(path_z, std.c.F_OK) == 0;
}

pub fn resolveFontPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const cwd_path = try std.fs.path.join(allocator, &.{ "fonts", name });
    if (fileExists(cwd_path)) return cwd_path;
    allocator.free(cwd_path);

    const zig_out = try std.fs.path.join(allocator, &.{ "zig-out", "fonts", name });
    if (fileExists(zig_out)) return zig_out;
    allocator.free(zig_out);

    if (std.c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        const home_path = try std.fs.path.join(allocator, &.{ home, ".fonts", name });
        if (fileExists(home_path)) return home_path;
        allocator.free(home_path);
    }

    return std.fs.path.join(allocator, &.{ "fonts", name });
}

pub fn reload(allocator: std.mem.Allocator) void {
    _ = allocator;
}
