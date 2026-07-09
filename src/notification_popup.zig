const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Context = @import("wl.zig").Context;
const Notification = @import("notifications.zig").Notification;
const ShmBuffer = @import("wl.zig").ShmBuffer;
const Canvas = @import("render.zig").Canvas;
const render_mod = @import("render.zig");
const Font = render_mod.Font;
const config_mod = @import("config.zig");
const Color = config_mod.Color;
const Appearance = config_mod.Appearance;

fn popupLayerSurfaceListener(ls: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, panel: *NotificationPanel) void {
    switch (event) {
        .configure => |ev| {
            panel.pending_width = @as(i32, @intCast(ev.width));
            panel.pending_height = @as(i32, @intCast(ev.height));
            panel.configured = true;
            ls.ackConfigure(ev.serial);
        },
        .closed => {
            panel.hide();
        },
    }
}

fn ellipsizeText(font: *Font, text: []const u8, max_w: i32, buf: []u8) []const u8 {
    if (render_mod.textWidth(font, text) <= max_w) return text;
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (render_mod.textWidth(font, text[0..mid]) <= max_w - 6) lo = mid else hi = mid - 1;
    }
    if (lo == 0) return "";
    @memcpy(buf[0..lo], text[0..lo]);
    buf[lo] = '.'; buf[lo + 1] = '.'; buf[lo + 2] = '.';
    return buf[0 .. lo + 3];
}

pub const PANEL_W: i32 = 380;
pub const PANEL_H_MAX: i32 = 400;
pub const POPUP_TIMEOUT_MS: i64 = 7000;
const PANEL_MARGIN_RIGHT: i32 = 14;
const PANEL_MARGIN_BOTTOM: i32 = 6;

const CARD_R: i32 = 16;
const INNER_PAD: i32 = 12;
const ICON_SZ: i32 = 42;
const CLOSE_SZ: i32 = 18;
const GAP: i32 = 4;
const GAP_CARDS: i32 = 8;
const PANEL_PAD: i32 = 12;
const CARD_H: i32 = 66;

// M3 dark palette
const col_surface_container = Color.rgba(0x1C, 0x1B, 0x1F, 0xFF);
const col_on_surface = Color.rgba(0xE6, 0xE1, 0xE5, 0xFF);
const col_on_surface_variant = Color.rgba(0xCA, 0xC4, 0xD0, 0xFF);
const col_secondary_container = Color.rgba(0x4A, 0x44, 0x58, 0xFF);
const col_on_secondary_container = Color.rgba(0xE8, 0xDE, 0xF8, 0xFF);
const col_primary = Color.rgba(0xD0, 0xBC, 0xFF, 0xFF);
const col_error = Color.rgba(0xF2, 0xB8, 0xB5, 0xFF);
const col_on_error = Color.rgba(0x60, 0x14, 0x10, 0xFF);
const col_surface_container_highest = Color.rgba(0x49, 0x45, 0x4F, 0xFF);

pub const NotificationPanel = struct {
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    buffer: ?ShmBuffer = null,
    font: ?Font = null,
    font_small: ?Font = null,
    font_material: ?Font = null,
    font_fallback: ?Font = null,
    configured: bool = false,
    initialized: bool = false,
    needs_redraw: bool = false,
    has_content: bool = false,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    output_idx: usize = 0,

    pub fn init(self: *NotificationPanel, ctx: *Context, output_idx: usize, allocator: std.mem.Allocator) !void {
        if (self.initialized) return;
        self.output_idx = output_idx;

        const shm = ctx.shm orelse return error.NoShm;
        self.buffer = try ShmBuffer.create(shm, @intCast(PANEL_W), @intCast(PANEL_H_MAX));

        const cfg = config_mod.get();
        if (config_mod.resolveFontPath(allocator, cfg.font_regular)) |fp| {
            defer allocator.free(fp);
            self.font = Font.init(allocator, fp, cfg.font_size) catch null;
        } else |_| {}
        if (config_mod.resolveFontPath(allocator, cfg.font_regular)) |fp| {
            defer allocator.free(fp);
            self.font_small = Font.init(allocator, fp, cfg.font_size_small) catch null;
        } else |_| {}
        if (config_mod.resolveFontPath(allocator, cfg.font_material)) |fp| {
            defer allocator.free(fp);
            self.font_material = Font.init(allocator, fp, cfg.font_size_material) catch null;
        } else |_| {}
        if (self.font) |*f| {
            if (config_mod.resolveFallbackFont(allocator)) |fb_path| {
                defer allocator.free(fb_path);
                if (Font.init(allocator, fb_path, cfg.font_size)) |fb| {
                    self.font_fallback = fb;
                    f.fallback = &self.font_fallback.?;
                } else |_| {}
            }
        }
        if (self.font_small) |*f| {
            if (self.font_fallback) |*fb| {
                f.fallback = fb;
            }
        }

        self.initialized = true;
    }

    pub fn deinit(self: *NotificationPanel) void {
        self.destroySurface();
    }

    fn destroySurface(self: *NotificationPanel) void {
        if (self.layer_surface) |ls| ls.destroy();
        if (self.surface) |s| s.destroy();
        self.layer_surface = null;
        self.surface = null;
        self.configured = false;
    }

    pub fn show(self: *NotificationPanel, ctx: *Context) void {
        if (!self.initialized) return;
        if (self.has_content) return;

        // Create layer surface anchored bottom-right (like end-4 StyledPopup)
        const compositor = ctx.compositor orelse return;
        const layer_shell = ctx.layer_shell orelse return;
        const output = &ctx.outputs[self.output_idx];
        const wl_output = output.output;

        // Destroy old surface if any
        self.destroySurface();

        const surface = compositor.createSurface() catch return;
        const layer = layer_shell.getLayerSurface(
            surface,
            wl_output,
            .overlay,
            "mist-notification-panel",
        ) catch {
            surface.destroy();
            return;
        };

        const content_h = self.calcContentHeight(ctx);
        layer.setSize(@intCast(PANEL_W), @intCast(content_h));
        layer.setAnchor(.{ .bottom = true, .right = true });
        layer.setExclusiveZone(0);
        layer.setKeyboardInteractivity(.none);
        layer.setListener(*NotificationPanel, popupLayerSurfaceListener, self);

        // Position: right edge with small margin, above screen bottom with small gap
        layer.setMargin(0, PANEL_MARGIN_RIGHT, PANEL_MARGIN_BOTTOM, 0);

        self.surface = surface;
        self.layer_surface = layer;
        self.has_content = true;
        self.needs_redraw = true;

        // First commit (no buffer) triggers configure
        surface.commit();
        ctx.flush();
        ctx.roundtrip();
        // Now safe to attach buffer
        self.drawAll(ctx);
    }

    pub fn hide(self: *NotificationPanel) void {
        if (!self.has_content) return;
        self.has_content = false;
        self.destroySurface();
    }

    pub fn markDirty(self: *NotificationPanel) void {
        self.needs_redraw = true;
    }

    pub fn drawAll(self: *NotificationPanel, ctx: *Context) void {
        if (!self.initialized or !self.has_content) return;
        const s = self.surface orelse return;
        const buf = self.buffer orelse return;

        self.draw(ctx);

        s.attach(buf.buffer, 0, 0);
        s.damageBuffer(0, 0, @intCast(PANEL_W), @intCast(PANEL_H_MAX));
        s.commit();
    }

    fn calcContentHeight(_: *NotificationPanel, ctx: *Context) i32 {
        const n = ctx.notifications.popup_len;
        if (n == 0) return 0;
        return @min(
            PANEL_PAD * 2 + @as(i32, @intCast(n)) * CARD_H + @as(i32, @intCast(@max(0, n - 1))) * GAP_CARDS,
            @as(i32, @intCast(PANEL_H_MAX)),
        );
    }

    fn draw(self: *NotificationPanel, ctx: *Context) void {
        const buf = self.buffer orelse return;
        const f = &(self.font orelse return);
        const fSml = &(self.font_small orelse return);
        const n = ctx.notifications.popup_len;
        if (n == 0) {
            var canvas = Canvas{ .data = buf.data, .width = @intCast(buf.width), .height = @intCast(buf.height), .stride = buf.stride };
            canvas.fill(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
            return;
        }

        var canvas = Canvas{ .data = buf.data, .width = @intCast(buf.width), .height = @intCast(buf.height), .stride = buf.stride };
        canvas.fill(.{ .r = 0, .g = 0, .b = 0, .a = 0 });

        // Collect visible popups (newest first)
        var popup_ids: [16]usize = undefined;
        var popup_count: usize = 0;
        var i: usize = ctx.notifications.list_len;
        while (i > 0) {
            i -= 1;
            if (ctx.notifications.list[i].popup) {
                if (popup_count < 16) {
                    popup_ids[popup_count] = i;
                    popup_count += 1;
                }
            }
        }

        const card_w: i32 = PANEL_W - PANEL_PAD * 2;

        // Draw top-down: newest card at top, older cards below
        var card_y: i32 = PANEL_PAD;
        while (popup_count > 0) {
            popup_count -= 1;
            const ni = popup_ids[popup_count];
            const notif = &ctx.notifications.list[ni];

            const card_x = PANEL_PAD;

            // Flat card — no shadow, no border (matches Caelestia)
            canvas.fillRoundedRectAA(card_x, card_y, card_w, CARD_H, CARD_R, col_surface_container);

            // Icon circle — left side, centered vertically
            const icon_x = card_x + INNER_PAD;
            const icon_cy = card_y + INNER_PAD + @divTrunc(ICON_SZ, 2);
            const is_critical = notif.urgency >= 2;
            const is_low = notif.urgency == 0;
            const icon_bg = if (is_critical) col_error else if (is_low) col_surface_container_highest else col_secondary_container;
            canvas.fillCircle(icon_x + @divTrunc(ICON_SZ, 2), icon_cy, @as(f32, @floatFromInt(@divTrunc(ICON_SZ, 2))), icon_bg);

            // Material icon centered inside circle (60% of circle = 25px)
            if (self.font_material) |*fMat| {
                const glyph = "notifications";
                const gw = render_mod.textWidth(fMat, glyph);
                const gm = render_mod.measureGlyph(fMat, glyph);
                const text_baseline = icon_cy + gm.top - @divTrunc(gm.height, 2);
                const icon_fg = if (is_critical) col_on_error else if (is_low) col_on_surface else col_on_secondary_container;
                render_mod.renderText(&canvas, fMat, glyph, icon_x + @divTrunc(ICON_SZ - gw, 2), text_baseline, icon_fg);
            }

            // Progress ring — 2px stroke around icon circle
            {
                const elapsed = if (notif.timestamp_ms > 0 and ctx.now_ms > notif.timestamp_ms) ctx.now_ms - notif.timestamp_ms else 0;
                const remain = if (elapsed > 0) @max(0.0, 1.0 - @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(POPUP_TIMEOUT_MS))) else 1.0;
                if (remain > 0.01) {
                    const ring_r = @as(i32, @intCast(ICON_SZ / 2)) + 2;
                    canvas.fillArc(
                        icon_x + @divTrunc(ICON_SZ, 2),
                        icon_cy,
                        ring_r - 1,
                        ring_r,
                        -@as(f32, std.math.pi) / 2.0,
                        remain * std.math.tau,
                        col_primary,
                    );
                }
            }

            // Close button — top-right of card
            const close_x = card_x + card_w - INNER_PAD - CLOSE_SZ;
            const close_r = @divTrunc(CLOSE_SZ, 2);
            const close_cx = close_x + close_r;
            const close_cy = card_y + INNER_PAD + close_r;
            canvas.fillCircle(close_cx, close_cy, @as(f32, @floatFromInt(close_r)), col_surface_container_highest);
            if (self.font_material) |*fMat| {
                const glyph = "close";
                const gw = render_mod.textWidth(fMat, glyph);
                const gm = render_mod.measureGlyph(fMat, glyph);
                const text_baseline = close_cy + gm.top - @divTrunc(gm.height, 2);
                render_mod.renderText(&canvas, fMat, glyph, close_cx - @divTrunc(gw, 2), text_baseline, col_on_surface_variant);
            }

            // Text area — right of icon
            const text_x = icon_x + ICON_SZ + 12;
            const text_max_w = close_x - text_x - GAP;
            const app_name = notif.app_name[0..notif.app_name_len];
            const summary = notif.summary[0..notif.summary_len];
            const body = notif.body[0..notif.body_len];

            // Time string (relative)
            var time_buf: [16]u8 = undefined;
            const time_str = blk: {
                if (notif.timestamp_ms > 0 and ctx.now_ms > notif.timestamp_ms) {
                    const diff_s: i64 = @divTrunc(ctx.now_ms - notif.timestamp_ms, 1000);
                    if (diff_s < 60) {
                        const buf2 = std.fmt.bufPrint(&time_buf, "{d}", .{diff_s}) catch break :blk "";
                        break :blk buf2;
                    } else if (diff_s < 3600) {
                        const mins = @divTrunc(diff_s, 60);
                        const buf2 = std.fmt.bufPrint(&time_buf, "{d}m", .{mins}) catch break :blk "";
                        break :blk buf2;
                    }
                }
                break :blk "";
            };

            // Summary (app name) — top line, muted color
            var text_y: i32 = card_y + INNER_PAD;
            if (app_name.len > 0) {
                var ellipsis_buf: [64]u8 = undefined;
                var display = ellipsizeText(fSml, app_name, text_max_w, &ellipsis_buf);
                if (time_str.len > 0) {
                    const time_w = render_mod.textWidth(fSml, time_str);
                    const sep_w = render_mod.textWidth(fSml, " • ");
                    const avail = text_max_w - render_mod.textWidth(fSml, display);
                    if (avail > time_w + sep_w + 4) {
                        var combined_buf: [128]u8 = undefined;
                        @memcpy(combined_buf[0..display.len], display);
                        @memcpy(combined_buf[display.len .. display.len + 3], " • ");
                        @memcpy(combined_buf[display.len + 3 .. display.len + 3 + time_str.len], time_str);
                        display = combined_buf[0 .. display.len + 3 + time_str.len];
                    }
                }
                render_mod.renderText(&canvas, fSml, display, text_x, text_y + fSml.baselineOffset(), col_on_surface_variant);
                text_y += fSml.lineHeight() + GAP;
            }

            // Body — below summary
            if (body.len > 0) {
                var ellipsis_buf: [512]u8 = undefined;
                const display = ellipsizeText(fSml, body, text_max_w, &ellipsis_buf);
                render_mod.renderText(&canvas, fSml, display, text_x, text_y + fSml.baselineOffset(), col_on_surface_variant);
            } else if (summary.len > 0) {
                var ellipsis_buf: [256]u8 = undefined;
                const display = ellipsizeText(f, summary, text_max_w, &ellipsis_buf);
                render_mod.renderText(&canvas, f, display, text_x, text_y + f.baselineOffset(), col_on_surface);
            }

            card_y += CARD_H + GAP_CARDS;
        }
    }

    pub fn handleClick(_: *NotificationPanel, ctx: *Context, x: i32, y: i32) void {
        const n = ctx.notifications.popup_len;
        if (n == 0) return;

        const card_w: i32 = PANEL_W - PANEL_PAD * 2;
        const card_x = PANEL_PAD;

        // Cards drawn top-down starting at PANEL_PAD
        var card_top: i32 = PANEL_PAD;
        for (0..n) |pi| {
            const card_bottom = card_top + CARD_H;
            if (y >= card_top and y < card_bottom) {
                const close_x = card_x + card_w - INNER_PAD - CLOSE_SZ;
                const close_r = @divTrunc(CLOSE_SZ, 2);
                const close_cx = close_x + close_r;
                const close_cy = card_top + INNER_PAD + close_r;
                const hit_r = close_r + 4;
                if (x >= close_cx - hit_r and x < close_cx + hit_r and
                    y >= close_cy - hit_r and y < close_cy + hit_r)
                {
                    var popup_ids: [16]usize = undefined;
                    var popup_count: usize = 0;
                    var ii: usize = ctx.notifications.list_len;
                    while (ii > 0) {
                        ii -= 1;
                        if (ctx.notifications.list[ii].popup) {
                            if (popup_count < 16) {
                                popup_ids[popup_count] = ii;
                                popup_count += 1;
                            }
                        }
                    }
                    if (pi < popup_count) {
                        const notif_idx = popup_ids[popup_count - 1 - pi];
                        const id = ctx.notifications.list[notif_idx].id;
                        ctx.notifications.dismiss(id);
                    }
                    return;
                }
                break;
            }
            card_top = card_bottom + GAP_CARDS;
        }
    }
};
