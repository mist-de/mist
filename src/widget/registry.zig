const std = @import("std");
const rdr = @import("../shell/render.zig");
const text = @import("../shell/render/text.zig");
const battery = @import("../battery.zig");
const volume = @import("../volume.zig");
const workspace = @import("../workspace.zig");

pub const Spacer = struct {
    pub fn init() Spacer {
        return .{};
    }
    pub fn deinit(_: *Spacer) void {}
    pub fn measure(_: *Spacer, _: u32, _: u32) u32 {
        return 0;
    }
    pub fn render(_: *Spacer, _: *rdr.Surface, _: i32, _: i32, _: u32, _: u32) void {}
};

pub const Separator = struct {
    width: u32 = 2,
    color: rdr.Color = .{ .r = 0x31, .g = 0x32, .b = 0x44, .a = 0xff },

    pub fn init() Separator {
        return .{};
    }
    pub fn deinit(_: *Separator) void {}
    pub fn measure(self: *Separator, _: u32, _: u32) u32 {
        return self.width + 8;
    }
    pub fn render(self: *Separator, surface: *rdr.Surface, x: i32, y: i32, _: u32, h: u32) void {
        surface.fillRect(x + 4, y + 4, self.width, h - 8, self.color);
    }
};

pub const TagWidget = struct {
    font: *text.Font,
    color_active: rdr.Color = .{ .r = 0x89, .g = 0xb4, .b = 0xfa, .a = 0xff },
    color_inactive: rdr.Color = .{ .r = 0x58, .g = 0x5b, .b = 0x70, .a = 0xff },
    color_urgent: rdr.Color = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8, .a = 0xff },

    pub fn init(font: *text.Font) TagWidget {
        return .{ .font = font };
    }
    pub fn deinit(_: *TagWidget) void {}

    pub fn measure(_: *TagWidget, _: u32, _: u32) u32 {
        return @as(u32, workspace.tag_state.tag_count) * 20 + 12;
    }

    pub fn render(self: *TagWidget, surface: *rdr.Surface, x: i32, y: i32, _: u32, h: u32) void {
        const tag_size: u32 = 6;
        const gap: u32 = 12;
        const n_tags = workspace.tag_state.tag_count;
        const total_w = self.measure(0, 0);
        const start_x = x + @as(i32, @intCast((total_w - (n_tags * (tag_size +| gap) -| gap)) / 2));
        const cy = y + @as(i32, @intCast(h / 2));

        for (0..n_tags) |i| {
            const tx = start_x + @as(i32, @intCast(i * (tag_size + gap)));
            const color = if (workspace.isTagUrgent(@intCast(i))) self.color_urgent else if (workspace.isTagActive(@intCast(i))) self.color_active else self.color_inactive;
            surface.fillRect(tx, cy - @as(i32, @intCast(tag_size / 2)), tag_size, tag_size, color);
        }
    }

    pub fn count(self: *TagWidget) u8 {
        _ = self;
        return workspace.tag_state.tag_count;
    }
};

pub const ActiveWindow = struct {
    font: *text.Font,
    title: []const u8 = "",
    color: rdr.Color = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4, .a = 0xff },

    pub fn init(font: *text.Font) ActiveWindow {
        return .{ .font = font, .title = "" };
    }
    pub fn deinit(_: *ActiveWindow) void {}
    pub fn measure(self: *ActiveWindow, max_w: u32, _: u32) u32 {
        if (self.title.len == 0) return 0;
        const tw = self.font.measureText(self.title);
        return @min(tw + 12, max_w);
    }
    pub fn render(self: *ActiveWindow, surface: *rdr.Surface, x: i32, _: i32, _: u32, h: u32) void {
        if (self.title.len == 0) return;
        const fs = self.font.size;
        const ty: i32 = @intCast((h -| @as(u32, @intFromFloat(fs))) / 2 + @as(u32, @intFromFloat(fs)) - 4);
        self.font.drawText(surface.pixels, surface.stride_pixels, surface.width, surface.height, self.title, x + 6, ty, self.color);
    }
};

pub const Clock = struct {
    font: *text.Font,
    color: rdr.Color = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4, .a = 0xff },
    buf: [32]u8 = undefined,
    last_time: []const u8 = "",

    pub fn init(font: *text.Font) Clock {
        return .{ .font = font };
    }
    pub fn deinit(_: *Clock) void {}
    pub fn measure(self: *Clock, _: u32, _: u32) u32 {
        return self.font.measureText(self.getTime()) + 16;
    }
    pub fn render(self: *Clock, surface: *rdr.Surface, x: i32, _: i32, _: u32, h: u32) void {
        const time = self.getTime();
        const fs = self.font.size;
        const ty: i32 = @intCast((h -| @as(u32, @intFromFloat(fs))) / 2 + @as(u32, @intFromFloat(fs)) - 4);
        self.font.drawText(surface.pixels, surface.stride_pixels, surface.width, surface.height, time, x + 8, ty, self.color);
    }

    fn getTime(self: *Clock) []const u8 {
        const now = unixTime();
        if (now <= 0) return "??:??";

        const tm = extern struct { sec: i32, min: i32, hour: i32, mday: i32, mon: i32, year: i32, wday: i32, yday: i32, isdst: i32 };
        const lr = struct { extern "c" fn localtime_r(timep: *const i64, result: *tm) ?*tm; };
        var result: tm = undefined;
        var t = now;
        if (lr.localtime_r(&t, &result) == null) return "??:??";

        self.last_time = std.fmt.bufPrint(
            &self.buf,
            "{d:0>2}:{d:0>2}",
            .{ @as(u8, @intCast(result.hour)), @as(u8, @intCast(result.min)) },
        ) catch return "??:??";
        return self.last_time;
    }
};

pub const BatteryStub = struct {
    font: *text.Font,
    color: rdr.Color = .{ .r = 0xa6, .g = 0xe3, .b = 0xa1, .a = 0xff },
    last_percent: u8 = 255,

    pub fn init(font: *text.Font) BatteryStub {
        return .{ .font = font };
    }
    pub fn deinit(_: *BatteryStub) void {}
    pub fn measure(self: *BatteryStub, _: u32, _: u32) u32 {
        return self.font.measureText("100%") + 12;
    }
    pub fn render(self: *BatteryStub, surface: *rdr.Surface, x: i32, _: i32, _: u32, h: u32) void {
        var buf: [8]u8 = undefined;
        const pct = if (battery.state.available) @as(u8, @intCast(@min(@as(u32, @intFromFloat(battery.state.percentage)), 100))) else 255;
        const prefix = if (battery.state.charging) "C" else "B";
        const text_str = if (pct <= 100)
            std.fmt.bufPrint(&buf, "{s}{d}%", .{ prefix, pct }) catch "BAT"
        else
            "BAT";
        const fs = self.font.size;
        const ty: i32 = @intCast((h -| @as(u32, @intFromFloat(fs))) / 2 + @as(u32, @intFromFloat(fs)) - 4);
        self.font.drawText(surface.pixels, surface.stride_pixels, surface.width, surface.height, text_str, x + 6, ty, self.color);
    }
};

pub const VolumeStub = struct {
    font: *text.Font,
    color: rdr.Color = .{ .r = 0x89, .g = 0xeb, .b = 0xeb, .a = 0xff },

    pub fn init(font: *text.Font) VolumeStub {
        return .{ .font = font };
    }
    pub fn deinit(_: *VolumeStub) void {}
    pub fn measure(self: *VolumeStub, _: u32, _: u32) u32 {
        return self.font.measureText("V100%") + 12;
    }
    pub fn render(self: *VolumeStub, surface: *rdr.Surface, x: i32, _: i32, _: u32, h: u32) void {
        var buf: [8]u8 = undefined;
        const pct = if (volume.state.available) @as(u8, @intCast(@min(@as(u32, @intFromFloat(volume.state.percentage)), 100))) else 0;
        const icon = if (volume.state.muted) "M" else "V";
        const text_str = std.fmt.bufPrint(&buf, "{s}{d}%", .{ icon, pct }) catch "VOL";
        const fs = self.font.size;
        const ty: i32 = @intCast((h -| @as(u32, @intFromFloat(fs))) / 2 + @as(u32, @intFromFloat(fs)) - 4);
        self.font.drawText(surface.pixels, surface.stride_pixels, surface.width, surface.height, text_str, x + 6, ty, self.color);
    }
};

fn unixTime() i64 {
    const ts = extern struct { sec: i64, nsec: i64 };
    const c = struct { extern "c" fn clock_gettime(clock_id: c_int, tp: *ts) c_int; };
    var t: ts = undefined;
    return if (c.clock_gettime(0, &t) == 0) t.sec else 0;
}

pub const WidgetEnum = union(enum) {
    spacer: Spacer,
    separator: Separator,
    tags: TagWidget,
    active_window: ActiveWindow,
    clock: Clock,
    battery: BatteryStub,
    volume: VolumeStub,

    pub fn measure(self: *WidgetEnum, max_w: u32, bar_h: u32) u32 {
        return switch (self.*) {
            inline else => |*widget| widget.measure(max_w, bar_h),
        };
    }

    pub fn render(self: *WidgetEnum, surface: *rdr.Surface, x: i32, y: i32, w: u32, h: u32) void {
        switch (self.*) {
            inline else => |*widget| widget.render(surface, x, y, w, h),
        }
    }

    pub fn deinit(self: *WidgetEnum) void {
        switch (self.*) {
            inline else => |*widget| widget.deinit(),
        }
    }
};
