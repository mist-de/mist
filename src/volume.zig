const std = @import("std");

const log = std.log.scoped(.volume);

pub const State = struct {
    percentage: f64 = -1,
    muted: bool = false,
    available: bool = false,
};

pub var state: State = .{};

const c = struct {
    extern "c" fn system(cmd: [*:0]const u8) c_int;
    extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn pclose(stream: *anyopaque) c_int;
    extern "c" fn fgets(buf: [*]u8, n: c_int, stream: *anyopaque) ?[*]u8;
};

pub fn init() void {
    refresh();
}

pub fn refresh() void {
    var cmd_buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "wpctl get-volume @DEFAULT_AUDIO_SINK@", .{}) catch return;
    const fp = c.popen(cmd, "r") orelse return;

    var line_buf: [128]u8 = undefined;
    const got = c.fgets(&line_buf, @intCast(line_buf.len), fp);
    _ = c.pclose(fp);

    const out = got orelse return;
    const null_idx = std.mem.indexOfScalar(u8, out[0..line_buf.len], 0) orelse return;
    const raw = out[0..null_idx];
    if (raw.len < 10) return;

    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return;
    const rest = raw[colon + 1 ..];
    const trimmed = std.mem.trim(u8, rest, " \t\n\r");
    const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const pct_str = trimmed[0..space];
    const pct = std.fmt.parseFloat(f64, pct_str) catch return;

    state.percentage = pct * 100;
    state.muted = std.mem.indexOf(u8, trimmed, "MUTED") != null;
    state.available = true;
}

pub fn setVolume(delta: i8) void {
    var buf: [256]u8 = undefined;
    const sign = if (delta >= 0) "+" else "";
    const cmd = std.fmt.bufPrintZ(&buf, "wpctl set-volume @DEFAULT_AUDIO_SINK@ {s}{d}%", .{ sign, @abs(delta) }) catch return;
    _ = c.system(cmd);
    refresh();
}

pub fn toggleMute() void {
    _ = c.system("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle");
    refresh();
}

pub fn deinit() void {}
