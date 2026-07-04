const std = @import("std");
const geo = @import("../geo.zig");
const rdr = @import("../shell/render.zig");
const text = @import("../shell/render/text.zig");
const Wayland = @import("../wayland.zig");
const wl = Wayland.wl;

const Point = geo.Point;
const Rect = geo.Rect;
const Size = geo.Size;
const Color = rdr.Color;

const Output = @import("../output.zig").Output;
const widgets = @import("../widget/registry.zig");
const Config = @import("../config.zig");
const seat = @import("../seat.zig");
const volume = @import("../volume.zig");
const workspace = @import("../workspace.zig");

const log = std.log.scoped(.RootContainer);

const max_widgets = 16;

const HitEntry = struct {
    section: enum { left, center, right },
    index: usize,
    rect: Rect,
};

pub const RootContainer = @This();

area: Rect = .zero,
last_motion: ?Point = null,
full_redraw: bool = true,
allocator: std.mem.Allocator = std.heap.page_allocator,

wayland_context: *Wayland,
output: ?*Output = null,

font: ?*text.Font = null,

left_widgets: [max_widgets]widgets.WidgetEnum = undefined,
left_count: usize = 0,
center_widgets: [max_widgets]widgets.WidgetEnum = undefined,
center_count: usize = 0,
right_widgets: [max_widgets]widgets.WidgetEnum = undefined,
right_count: usize = 0,

hit_areas: [max_widgets * 3]HitEntry = undefined,
hit_count: usize = 0,

pub fn init(
    allocator: std.mem.Allocator,
    area: Rect,
    _: *wl.Output,
    output_name: []const u8,
    wayland_context: *Wayland,
    font_path: [:0]const u8,
) RootContainer {
    _ = output_name;

    var rc = RootContainer{
        .area = area,
        .allocator = allocator,
        .wayland_context = wayland_context,
    };

    rc.loadFont(font_path) catch {};
    rc.createWidgets();
    return rc;
}

fn loadFont(self: *RootContainer, font_path: [:0]const u8) !void {
    const ptr = try self.allocator.create(text.Font);
    errdefer self.allocator.destroy(ptr);
    ptr.* = try text.Font.init(font_path, 14);
    self.font = ptr;
}

fn createWidgets(self: *RootContainer) void {
    self.createSection(&self.left_widgets, &self.left_count, &Config.default_layout.left, "left");
    self.createSection(&self.center_widgets, &self.center_count, &Config.default_layout.center, "center");
    self.createSection(&self.right_widgets, &self.right_count, &Config.default_layout.right, "right");
}

fn createSection(self: *RootContainer, widgets_buf: *[max_widgets]widgets.WidgetEnum, count: *usize, names: []const []const u8, tag: []const u8) void {
    const font = self.font orelse return;
    for (names) |name| {
        if (count.* >= max_widgets) {
            log.warn("Too many widgets in section '{s}'", .{tag});
            break;
        }
        widgets_buf[count.*] = createWidgetByName(name, font) catch continue;
        count.* += 1;
    }
}

fn createWidgetByName(name: []const u8, font: *text.Font) !widgets.WidgetEnum {
    if (std.mem.eql(u8, name, "tags")) return widgets.WidgetEnum{ .tags = widgets.TagWidget.init(font) };
    if (std.mem.eql(u8, name, "active_window")) return widgets.WidgetEnum{ .active_window = widgets.ActiveWindow.init(font) };
    if (std.mem.eql(u8, name, "clock")) return widgets.WidgetEnum{ .clock = widgets.Clock.init(font) };
    if (std.mem.eql(u8, name, "battery")) return widgets.WidgetEnum{ .battery = widgets.BatteryStub.init(font) };
    if (std.mem.eql(u8, name, "volume")) return widgets.WidgetEnum{ .volume = widgets.VolumeStub.init(font) };
    if (std.mem.eql(u8, name, "spacer")) return widgets.WidgetEnum{ .spacer = widgets.Spacer.init() };
    if (std.mem.eql(u8, name, "separator")) return widgets.WidgetEnum{ .separator = widgets.Separator.init() };
    log.warn("Unknown widget type: '{s}'", .{name});
    return error.UnknownWidget;
}

pub fn subscribeWidgets(_: *RootContainer) void {}

pub fn setOutput(self: *RootContainer, output: *Output) void {
    self.output = output;
}

pub fn setArea(self: *RootContainer, area: Rect) void {
    self.area = area;
    self.full_redraw = true;
}

pub fn deinit(self: *RootContainer) void {
    for (self.left_widgets[0..self.left_count]) |*w| w.deinit();
    for (self.center_widgets[0..self.center_count]) |*w| w.deinit();
    for (self.right_widgets[0..self.right_count]) |*w| w.deinit();
    if (self.font) |f| {
        f.deinit();
        self.allocator.destroy(f);
    }
}

pub fn needsRedraw(self: *RootContainer) bool {
    return self.full_redraw;
}

pub fn collectDamage(_: *RootContainer, _: *rdr.DamageTracker) void {}

fn syncState(self: *RootContainer) void {
    inline for ([_][]widgets.WidgetEnum{ &self.left_widgets, &self.center_widgets, &self.right_widgets }) |section| {
        for (section) |*w| {
            if (w.* == .active_window) {
                w.active_window.title = self.wayland_context.getFocusedTitle();
            }
        }
    }
}

fn buildHitAreas(self: *RootContainer, clip: Rect) void {
    const padding: i32 = 8;
    const spacing: i32 = 4;
    const width: i32 = @intCast(clip.width);
    const height: u32 = @intCast(clip.height);
    self.hit_count = 0;

    // Left section
    var left_end: i32 = padding;
    for (self.left_widgets[0..self.left_count], 0..) |*w, i| {
        const w_w = w.measure(@intCast(@max(0, width - left_end)), height);
        self.hit_areas[self.hit_count] = .{
            .section = .left, .index = i,
            .rect = .{ .x = left_end, .y = 0, .width = w_w, .height = height },
        };
        self.hit_count += 1;
        left_end += @intCast(w_w + spacing);
    }

    // Right section (compute backwards, store forwards)
    const right_start: i32 = width - padding;
    var right_positions: [max_widgets]i32 = undefined;
    var right_widths: [max_widgets]u32 = undefined;
    for (self.right_widgets[0..self.right_count], 0..) |*w, i| {
        const rp = if (i == 0) right_start else right_positions[i - 1] - @as(i32, @intCast(right_widths[i - 1])) - spacing;
        const w_w = w.measure(@intCast(@max(0, rp - padding)), height);
        right_positions[i] = rp - @as(i32, @intCast(w_w));
        right_widths[i] = w_w;
    }
    for (0..self.right_count) |i| {
        const idx = self.right_count - 1 - i;
        self.hit_areas[self.hit_count] = .{
            .section = .right, .index = idx,
            .rect = .{ .x = right_positions[idx], .y = 0, .width = right_widths[idx], .height = height },
        };
        self.hit_count += 1;
    }

    // Center section
    const center_available = right_start - left_end;
    if (center_available > 0 and self.center_count > 0) {
        var total_center_width: u32 = 0;
        var center_widths: [max_widgets]u32 = undefined;
        for (self.center_widgets[0..self.center_count], 0..) |*w, i| {
            const w_w = w.measure(@intCast(@max(0, center_available - @as(i32, @intCast(total_center_width)))), height);
            center_widths[i] = w_w;
            total_center_width += w_w;
            if (i + 1 < self.center_count) total_center_width += spacing;
        }
        var center_x = left_end + @divTrunc(center_available - @as(i32, @intCast(total_center_width)), 2);
        for (self.center_widgets[0..self.center_count], 0..) |*w, i| {
            _ = w;
            self.hit_areas[self.hit_count] = .{
                .section = .center, .index = i,
                .rect = .{ .x = center_x, .y = 0, .width = center_widths[i], .height = height },
            };
            self.hit_count += 1;
            center_x += @intCast(center_widths[i] + spacing);
        }
    }
}

fn widgetPtr(self: *RootContainer, entry: HitEntry) *widgets.WidgetEnum {
    return switch (entry.section) {
        .left => &self.left_widgets[entry.index],
        .center => &self.center_widgets[entry.index],
        .right => &self.right_widgets[entry.index],
    };
}

fn findWidgetAtPoint(self: *RootContainer, point: Point) ?HitEntry {
    for (self.hit_areas[0..self.hit_count]) |entry| {
        if (entry.rect.containsPoint(point)) return entry;
    }
    return null;
}

pub fn drawFrame(self: *RootContainer, surface: *rdr.Surface, clip: Rect) void {
    self.syncState();
    self.buildHitAreas(clip);

    const height: u32 = @intCast(clip.height);

    // Left section
    for (self.hit_areas[0..self.hit_count]) |entry| {
        if (entry.section != .left) continue;
        const w = self.widgetPtr(entry);
        w.render(surface, entry.rect.x, 0, entry.rect.width, height);
    }

    // Right section
    for (self.hit_areas[0..self.hit_count]) |entry| {
        if (entry.section != .right) continue;
        const w = self.widgetPtr(entry);
        w.render(surface, entry.rect.x, 0, entry.rect.width, height);
    }

    // Center section
    for (self.hit_areas[0..self.hit_count]) |entry| {
        if (entry.section != .center) continue;
        const w = self.widgetPtr(entry);
        w.render(surface, entry.rect.x, 0, entry.rect.width, height);
    }
}

pub fn getWidgetByName(_: *RootContainer, _: []const u8) ?*Widget {
    return null;
}

pub fn getWidgetWidth(_: *RootContainer, _: []const u8) Size {
    return 0;
}

pub fn setWidgetArea(_: *RootContainer, _: []const u8, _: Rect) void {}

pub fn markAllWidgetsFullRedraw(_: *RootContainer) void {}

pub fn motion(self: *RootContainer, point: Point) void {
    self.last_motion = point;
    _ = self.findWidgetAtPoint(point);
}

pub fn leave(self: *RootContainer) void {
    self.last_motion = null;
}

pub fn click(self: *RootContainer, btn: anytype) void {
    const point = self.last_motion orelse return;
    const entry = self.findWidgetAtPoint(point) orelse return;
    const w = self.widgetPtr(entry);
    _ = btn;
    switch (w.*) {
        .tags => {
            const tag_count = workspace.tag_state.tag_count;
            const tag_size: u32 = 6;
            const gap: u32 = 12;
            const total_w = w.tags.measure(0, 0);
            const start_x = entry.rect.x + @as(i32, @intCast((total_w - (tag_count * (tag_size +| gap) -| gap)) / 2));
            const rel_x = point.x - start_x;
            if (rel_x >= 0) {
                const tag_idx = @as(usize, @intCast(rel_x)) / (tag_size + gap);
                if (tag_idx < tag_count) {
                    log.info("Tag {} clicked, switching workspace", .{tag_idx + 1});
                    workspace.switchToTag(@intCast(tag_idx));
                }
            }
        },
        else => {
            log.debug("Widget clicked: {s}", .{@tagName(w.*)});
        },
    }
}

pub fn scroll(self: *RootContainer, _: anytype, value: i32) void {
    const point = self.last_motion orelse return;
    const entry = self.findWidgetAtPoint(point) orelse return;
    const w = self.widgetPtr(entry);
    switch (w.*) {
        .volume => {
            const delta: i8 = if (value > 0) -5 else 5;
            volume.setVolume(delta);
            if (self.output) |o| {
                o.full_redraw = true;
                o.requestFrame();
            }
        },
        else => {},
    }
}

pub fn getCursorShape(_: *RootContainer) Wayland.CursorShape {
    return .default;
}

pub fn handlePopupMotion(_: *RootContainer, _: Point) void {}
pub fn handlePopupClick(_: *RootContainer, _: Point, _: anytype) void {}
pub fn handlePopupRelease(_: *RootContainer, _: Point, _: anytype) void {}
pub fn getPopupCursorShape(_: *RootContainer, _: Point) Wayland.CursorShape {
    return .default;
}
pub fn handlePopupScroll(_: *RootContainer, _: Point, _: anytype, _: i32) void {}

pub const Widget = struct {};
