const std = @import("std");

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

// Geometry types

pub const Size = u32;

pub const Rect = struct {
    x: i32,
    y: i32,
    width: Size,
    height: Size,
    pub const zero: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
};

// Color

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

// Appearance constants

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

    // M3 color palette
    pub const m3background = Color.rgba(0x14, 0x13, 0x13, 0xFF);
    pub const m3on_background = Color.rgba(0xe6, 0xe1, 0xe1, 0xFF);
    pub const m3surface_container_low = Color.rgba(0x1c, 0x1b, 0x1c, 0xFF);
    pub const m3primary = Color.rgba(0xcb, 0xc4, 0xcb, 0xFF);
    pub const m3on_primary = Color.rgba(0x32, 0x2f, 0x34, 0xFF);
    pub const m3primary_container = Color.rgba(0x2d, 0x2a, 0x2f, 0xFF);
    pub const m3on_primary_container = Color.rgba(0xbc, 0xb6, 0xbc, 0xFF);
    pub const m3on_surface_variant = Color.rgba(0xcb, 0xc5, 0xca, 0xFF);
    pub const m3outline = Color.rgba(0x94, 0x8f, 0x94, 0xFF);
    pub const m3outline_variant = Color.rgba(0x49, 0x46, 0x4a, 0xFF);
    pub const m3secondary_container = Color.rgba(0x4d, 0x4b, 0x4d, 0xFF);
    pub const m3on_secondary_container = Color.rgba(0xec, 0xe6, 0xe9, 0xFF);

    // Semantic layer colors
    pub const col_layer0 = m3background;
    pub const col_layer0_border = Color.rgba(0x3a, 0x39, 0x3d, 0xFF); // mix(outlineVariant, layer0, 0.4)
    pub const col_layer1 = Color.rgba(0x1c, 0x1b, 0x1c, 0xFF);
    pub const col_layer2 = Color.rgba(0x20, 0x1f, 0x20, 0xFF); // surfaceContainer
    pub const col_on_layer0 = m3on_background;
    pub const col_on_layer1 = m3on_surface_variant;
    pub const col_on_layer1_inactive = Color.rgba(0x7d, 0x78, 0x7c, 0xFF);
    pub const col_on_layer2 = Color.rgba(0xe6, 0xe1, 0xe1, 0xFF); // m3onSurface
    pub const col_primary = m3primary;
    pub const col_on_primary = m3on_primary;
    pub const col_primary_container = m3primary_container;
    pub const col_on_primary_container = m3on_primary_container;
    pub const col_secondary_container = m3secondary_container;
    pub const col_secondary_container_alpha = Color.rgba(0x4d, 0x4b, 0x4d, 0x99);
    pub const col_on_secondary_container = m3on_secondary_container;
    pub const col_outline_variant = m3outline_variant;
    pub const col_outline = m3outline;
    pub const col_subtext = m3outline;
    pub const col_error = Color.rgba(0xf2, 0x6a, 0x6a, 0xFF);

    // Sidebar sizing (from end-4 Appearance.sizes)
    pub const sidebar_width: i32 = 460;
    pub const sidebar_margin: i32 = 5; // hyprlandGapsOut
    pub const sidebar_gap: i32 = 2; // visual gap between bar bottom and sidebar content top
    pub const sidebar_elevation: i32 = 10; // elevationMargin (left gap)
    pub const sidebar_padding: i32 = 10; // inner padding
    pub const sidebar_bg_radius: i32 = 19; // screenRounding(23) - hyprlandGapsOut(5) + 1
    pub const sidebar_widget_radius: i32 = 17; // normal rounding
    pub const sidebar_small_radius: i32 = 12; // small rounding (pills, notification items)
    pub const sidebar_full_radius: i32 = 9999; // pill shapes
    pub const sidebar_bottom_height: i32 = 350; // BottomWidgetGroup fixed height
    pub const sidebar_bottom_nav_w: i32 = 50; // navigation rail width
};

// Configuration

pub const Config = struct {
    height: u32 = 40,
    bottom: bool = false,
    font_regular: []const u8 = "Inter_18pt-Regular.ttf",
    font_icon: []const u8 = "NotoSansNerdFont-Regular.ttf",
    font_material: []const u8 = "MaterialSymbolsRounded.ttf",
    font_fallback: []const u8 = "NotoSansBengali-Regular.ttf",
    font_size_small: u32 = 12,
    font_size: u32 = 15,
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

fn findSystemFont(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const dirs = [_][]const u8{
        "/usr/share/fonts",
        "/usr/local/share/fonts",
    };
    for (dirs) |dir| {
        const path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        if (fileExists(path)) return path;
        allocator.free(path);
    }
    if (std.c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        if (std.fs.path.join(allocator, &.{ home, ".local", "share", "fonts", name })) |p| {
            if (fileExists(p)) return p;
            allocator.free(p);
        } else |_| {}
        if (std.fs.path.join(allocator, &.{ home, ".fonts", name })) |p| {
            if (fileExists(p)) return p;
            allocator.free(p);
        } else |_| {}
    }
    return null;
}

const cc_cfg = @import("cbasic.zig").c;

fn findFontByFamily(allocator: std.mem.Allocator, family: []const u8) ?[]u8 {
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "fc-match '{s}' --format='%{{file}}' 2>/dev/null", .{family}) catch return null;
    cmd_buf[cmd.len] = 0;
    const cmd_z: [*:0]const u8 = @ptrCast(&cmd_buf);
    const f = cc_cfg.popen(cmd_z, "r") orelse return null;
    defer _ = cc_cfg.pclose(f);
    var line: [512]u8 = undefined;
    if (cc_cfg.fgets(&line, @intCast(line.len), f)) |result| {
        const path = std.mem.trim(u8, std.mem.span(result), " \n\r\t");
        if (path.len > 0 and fileExists(path)) {
            return allocator.dupe(u8, path) catch null;
        }
    }
    return null;
}

pub fn resolveFontPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const cwd_path = try std.fs.path.join(allocator, &.{ "fonts", name });
    if (fileExists(cwd_path)) return cwd_path;
    allocator.free(cwd_path);

    const zig_out = try std.fs.path.join(allocator, &.{ "zig-out", "fonts", name });
    if (fileExists(zig_out)) return zig_out;
    allocator.free(zig_out);

    if (findSystemFont(allocator, name)) |p| return p;

    return error.FontNotFound;
}

pub fn resolveFallbackFont(allocator: std.mem.Allocator) ?[]u8 {
    const cfg = get();
    if (resolveFontPath(allocator, cfg.font_fallback)) |p| return p else |_| {}
    for (&[_][]const u8{ "NotoSansBengali.ttf", "NotoSansBengali-Regular.ttf", "Mukti-Book.ttf" }) |alt| {
        if (resolveFontPath(allocator, alt)) |p| return p else |_| {}
    }
    // fontconfig fallback by family
    for (&[_][]const u8{ "Noto Sans Bengali", "Noto Sans Bengali Regular", "Mukti" }) |fam| {
        if (findFontByFamily(allocator, fam)) |p| return p;
    }
    return null;
}

    // Distro icon from /etc/os-release
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

        // Handle ID=nixos or ID="nixos"
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

// System resources: RAM, CPU, temp, battery

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
    audio_volume: f32 = 0.75,
    audio_muted: bool = false,
    mic_volume: f32 = 0.75,
    mic_muted: bool = false,
    last_vol_change_ms: i64 = 0,
    last_mic_change_ms: i64 = 0,
    battery_pct: i8 = -1,
    battery_charging: bool = false,
};

pub fn updateResources(state: *ResourceState) void {
    readMemInfo(state);
    readCpuStat(state);
    readTemp(state);
    readBattery(state);
    // Audio tracked locally, NOT re-read (preserves user changes)
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

fn readFileFirstLine(path: []const u8, buf: []u8) ?[]u8 {
    // open() requires null-terminated string
    var path_buf: [256:0]u8 = undefined;
    if (path.len >= path_buf.len) return null;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = std.c.open(&path_buf, .{}, @as(c_uint, 0));
    if (fd == -1) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    // Trim trailing newline/whitespace
    var end: usize = @intCast(n);
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r' or buf[end - 1] == ' ')) {
        end -= 1;
    }
    return buf[0..end];
}

fn readBattery(state: *ResourceState) void {
    const bat_names = [_][]const u8{ "BAT0", "BAT1", "BAT2", "BAT3" };
    var buf: [64]u8 = undefined;

    for (bat_names) |bat| {
        var cap_path: [128]u8 = undefined;
        const cap_path_s = std.fmt.bufPrint(cap_path[0..], "/sys/class/power_supply/{s}/capacity", .{bat}) catch return;
        const cap_str = readFileFirstLine(cap_path_s, buf[0..]) orelse continue;
        const pct = std.fmt.parseInt(i8, cap_str, 10) catch continue;
        state.battery_pct = @min(100, @max(0, pct));

        // Charging status
        var stat_path: [128]u8 = undefined;
        const stat_path_s = std.fmt.bufPrint(stat_path[0..], "/sys/class/power_supply/{s}/status", .{bat}) catch return;
        const status_str = readFileFirstLine(stat_path_s, buf[0..]) orelse "";
        state.battery_charging = std.mem.eql(u8, status_str, "Charging") or std.mem.eql(u8, status_str, "Full");

        return; // found a battery
    }
    // No battery found (desktop)
    state.battery_pct = -1;
    state.battery_charging = false;
}

pub fn readAudioState(state: *ResourceState) void {
    const c2 = @import("cbasic.zig").c;
    // Sink volume/mute
    const sink_fp = c2.popen("wpctl get-volume @DEFAULT_SINK@ 2>/dev/null", "r");
    if (sink_fp) |fp| {
        defer _ = c2.pclose(fp);
        var buf: [128]u8 = undefined;
        if (c2.fgets(&buf, @intCast(buf.len), fp)) |line| {
            const s = std.mem.sliceTo(line[0..buf.len], 0);
            if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
                const val_str = std.mem.trim(u8, s[colon + 1 ..], " \t");
                state.audio_volume = std.fmt.parseFloat(f32, val_str) catch 0.75;
                state.audio_muted = std.mem.indexOf(u8, s, "MUTED") != null;
            }
        }
    }
    // Source (mic) volume/mute
    const src_fp = c2.popen("wpctl get-volume @DEFAULT_SOURCE@ 2>/dev/null", "r");
    if (src_fp) |fp| {
        defer _ = c2.pclose(fp);
        var buf: [128]u8 = undefined;
        if (c2.fgets(&buf, @intCast(buf.len), fp)) |line| {
            const s = std.mem.sliceTo(line[0..buf.len], 0);
            if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
                const val_str = std.mem.trim(u8, s[colon + 1 ..], " \t");
                state.mic_volume = std.fmt.parseFloat(f32, val_str) catch 0.75;
            }
            state.mic_muted = std.mem.indexOf(u8, s, "MUTED") != null;
        }
    }
}

pub fn toggleAudioMute(state: *ResourceState) void {
    const c = @import("cbasic.zig").c;
    _ = c.system("wpctl set-mute @DEFAULT_SINK@ toggle");
    state.audio_muted = !state.audio_muted;
    state.last_vol_change_ms = nowMs();
}

pub fn toggleMicMute(state: *ResourceState) void {
    const c = @import("cbasic.zig").c;
    _ = c.system("wpctl set-mute @DEFAULT_SOURCE@ toggle");
    state.mic_muted = !state.mic_muted;
    state.last_mic_change_ms = nowMs();
}

pub fn setVolume(state: *ResourceState, vol: f32) void {
    const c = @import("cbasic.zig").c;
    const clamped = @min(2.0, @max(0.0, vol));
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(cmd_buf[0..], "wpctl set-volume @DEFAULT_SINK@ {d:.2}", .{clamped}) catch return;
    cmd_buf[cmd.len] = 0;
    _ = c.system(&cmd_buf);
    state.audio_volume = clamped;
    state.last_vol_change_ms = nowMs();
}

pub fn setMicVolume(state: *ResourceState, vol: f32) void {
    const c = @import("cbasic.zig").c;
    const clamped = @min(2.0, @max(0.0, vol));
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(cmd_buf[0..], "wpctl set-volume @DEFAULT_SOURCE@ {d:.2}", .{clamped}) catch return;
    cmd_buf[cmd.len] = 0;
    _ = c.system(&cmd_buf);
    state.mic_volume = clamped;
    state.last_mic_change_ms = nowMs();
}
