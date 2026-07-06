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
    pub const ws_count: i32 = 9;
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
    pub const col_layer1 = Color.rgba(0x1c, 0x1b, 0x1c, 0xFF);
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
    font_size_small: u32 = 12,
    font_size: u32 = 15,
    font_size_large: u32 = 17,
    font_size_material: u32 = 19,
    font_size_sidebar: u32 = 22,
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

/// Returns Nerd Font codepoint for the detected distro from /etc/os-release
pub fn detectDistroIcon() u21 {
    const fd = std.c.open("/etc/os-release", .{}, @as(c_uint, 0));
    if (fd == -1) return 0xF313;
    defer _ = std.c.close(fd);

    var buf: [2048]u8 = undefined;
    const nread = std.c.read(fd, &buf, buf.len);
    if (nread <= 0) return 0xF313;
    const content = buf[0..@as(usize, @intCast(nread))];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &[_]u8{ ' ', '\r' });
        if (!std.mem.startsWith(u8, line, "ID=")) continue;

        // Handle both ID=nixos and ID="nixos"
        var id = line[3..];
        if (id.len > 0 and id[0] == '"') {
            if (id.len < 2) continue;
            id = id[1..(id.len - 1)];
        }

        if (std.mem.eql(u8, id, "nixos")) return 0xF313;
        if (std.mem.eql(u8, id, "arch")) return 0xF303;
        if (std.mem.eql(u8, id, "debian")) return 0xF306;
        if (std.mem.eql(u8, id, "fedora")) return 0xF30A;
        if (std.mem.eql(u8, id, "ubuntu")) return 0xF31B;
        if (std.mem.eql(u8, id, "gentoo")) return 0xF30D;
        if (std.mem.eql(u8, id, "manjaro")) return 0xF312;
        if (std.mem.eql(u8, id, "alpine")) return 0xF300;
        if (std.mem.eql(u8, id, "opensuse") or std.mem.eql(u8, id, "suse")) return 0xF314;
        if (std.mem.eql(u8, id, "kali")) return 0xF311;
        if (std.mem.eql(u8, id, "linuxmint") or std.mem.eql(u8, id, "mint")) return 0xF30E;
        if (std.mem.eql(u8, id, "void")) return 0xF17C;
        if (std.mem.eql(u8, id, "endeavouros")) return 0xF310;

        return 0xF313; // nixos fallback for unknown
    }

    return 0xF313; // nixos fallback
}

// ═══════════════════════════════════════════════════════════
// System resource reading (RAM, CPU, temp from /proc)
// ═══════════════════════════════════════════════════════════

pub const ResourceState = struct {
    memory_used_pct: f32 = 0,
    memory_used_kb: u64 = 0,
    memory_total_kb: u64 = 0,
    memory_avail_kb: u64 = 0,
    swap_used_pct: f32 = 0,
    swap_total_kb: u64 = 0,
    swap_used_kb: u64 = 0,
    cpu_usage: f32 = 0.01,
    cpu_temp: f32 = 0,
    cpu_prev: [10]u64 = .{0} ** 10,
    cpu_initialized: bool = false,
};

pub fn updateResources(state: *ResourceState) void {
    readMemInfo(state);
    readCpuStat(state);
    readTemp(state);
}

fn readMemInfo(state: *ResourceState) void {
    const fd = std.c.open("/proc/meminfo", .{}, @as(c_uint, 0));
    if (fd == -1) return;
    defer _ = std.c.close(fd);

    var buf: [4096]u8 = undefined;
    const nread = std.c.read(fd, &buf, buf.len);
    if (nread <= 0) return;
    const content = buf[0..@as(usize, @intCast(nread))];

    var mem_total: u64 = 0;
    var mem_avail: u64 = 0;
    var swap_total: u64 = 0;
    var swap_free: u64 = 0;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw| {
        const line = std.mem.trim(u8, raw, &[_]u8{ ' ', '\r' });
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            mem_total = parseKbValue(line["MemTotal:".len..]);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            mem_avail = parseKbValue(line["MemAvailable:".len..]);
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            swap_total = parseKbValue(line["SwapTotal:".len..]);
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            swap_free = parseKbValue(line["SwapFree:".len..]);
        }
    }

    state.memory_total_kb = mem_total;
    state.memory_avail_kb = mem_avail;
    state.swap_total_kb = swap_total;
    state.swap_used_kb = swap_total -| swap_free;
    if (mem_total > 0) {
        state.memory_used_kb = mem_total -| mem_avail;
        state.memory_used_pct = @as(f32, @floatFromInt(state.memory_used_kb)) / @as(f32, @floatFromInt(mem_total));
    }
    if (swap_total > 0) {
        state.swap_used_pct = @as(f32, @floatFromInt(state.swap_used_kb)) / @as(f32, @floatFromInt(swap_total));
    }
}

fn parseKbValue(s: []const u8) u64 {
    const trimmed = std.mem.trim(u8, s, " \t");
    var i: usize = 0;
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
    var num: u64 = 0;
    while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') : (i += 1) {
        num = num * 10 + (trimmed[i] - '0');
    }
    return num;
}

fn readCpuStat(state: *ResourceState) void {
    const fd = std.c.open("/proc/stat", .{}, @as(c_uint, 0));
    if (fd == -1) return;
    defer _ = std.c.close(fd);

    var buf: [4096]u8 = undefined;
    const nread = std.c.read(fd, &buf, buf.len);
    if (nread <= 0) return;
    const content = buf[0..@as(usize, @intCast(nread))];

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    const first = line_iter.next() orelse return;
    if (!std.mem.startsWith(u8, first, "cpu ")) return;

    var current: [10]u64 = .{0} ** 10;
    const rest = first["cpu ".len..];
    var field_idx: usize = 0;
    var idx: usize = 0;
    while (field_idx < 10 and idx < rest.len) {
        while (idx < rest.len and (rest[idx] == ' ' or rest[idx] == '\t')) : (idx += 1) {}
        if (idx >= rest.len) break;
        var num: u64 = 0;
        while (idx < rest.len and rest[idx] >= '0' and rest[idx] <= '9') : (idx += 1) {
            num = num * 10 + (rest[idx] - '0');
        }
        current[field_idx] = num;
        field_idx += 1;
    }

    if (!state.cpu_initialized) {
        state.cpu_prev = current;
        state.cpu_initialized = true;
        state.cpu_usage = 0;
        return;
    }

    var prev_total: u64 = 0;
    var curr_total: u64 = 0;
    for (0..10) |j| {
        curr_total +|= current[j];
        prev_total +|= state.cpu_prev[j];
    }
    const prev_idle = state.cpu_prev[3] + state.cpu_prev[4];
    const curr_idle = current[3] + current[4];
    const total_delta = curr_total -| prev_total;
    const idle_delta = curr_idle -| prev_idle;

    if (total_delta > 0) {
        state.cpu_usage = @as(f32, @floatFromInt(total_delta - idle_delta)) / @as(f32, @floatFromInt(total_delta));
    }
    state.cpu_prev = current;
}

fn readTemp(state: *ResourceState) void {
    const fd = std.c.open("/sys/class/thermal/thermal_zone0/temp", .{}, @as(c_uint, 0));
    if (fd == -1) return;
    defer _ = std.c.close(fd);

    var buf: [32]u8 = undefined;
    const nread = std.c.read(fd, &buf, buf.len);
    if (nread <= 0) return;

    const content = std.mem.trim(u8, buf[0..@as(usize, @intCast(nread))], " \n\r\t");
    if (content.len == 0) return;

    var num: u64 = 0;
    for (content) |c| {
        if (c >= '0' and c <= '9') {
            num = num * 10 + (c - '0');
        } else break;
    }
    state.cpu_temp = @as(f32, @floatFromInt(num)) / 1000.0;
}
