const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Context = @import("wl.zig").Context;
const ShmBuffer = @import("wl.zig").ShmBuffer;
const Canvas = @import("render.zig").Canvas;
const render_mod = @import("render.zig");
const Font = render_mod.Font;
const config_mod = @import("config.zig");
const Color = config_mod.Color;
const mpris_mod = @import("mpris.zig");


pub const POPUP_W: i32 = 360;
pub const POPUP_H: i32 = 130;

pub const POPUP_MARGIN_TOP: i32 = 5;

const MARGIN: i32 = 10;
const SPACING: i32 = 12;
const ART_SIZE: i32 = POPUP_H - MARGIN * 2;
const COL_X: i32 = MARGIN + ART_SIZE + SPACING;
const COL_R: i32 = POPUP_W - MARGIN;

const TITLE_Y: i32 = 20;
const ARTIST_Y: i32 = 40;
const TIME_Y: i32 = 62;
const PROGRESS_Y: i32 = 74;
const PROGRESS_H: i32 = 4;
const BTN_Y: i32 = 104;

// Buttons centered horizontally in the content area (end-4: prev+next on slider row, play/pause on time row)
const COL_CENTER = COL_X + (COL_R - COL_X) / 2;
const PREV_CX: i32 = COL_CENTER - 50;
const PLAY_CX: i32 = COL_CENTER;
const NEXT_CX: i32 = COL_CENTER + 50;
const BTN_R: i32 = 16;

/// end-4: StringUtils.friendlyTimeForSeconds → "MM:SS"
fn formatTime(us: i64, buf: []u8) []const u8 {
    if (buf.len < 5) return "00:00";
    const total_secs = if (us >= 0) @as(u64, @intCast(us)) / 1000000 else 0;
    const mins = total_secs / 60;
    const secs = total_secs % 60;
    buf[0] = @as(u8, @intCast(@divTrunc(mins, 10) % 10)) + '0';
    buf[1] = @as(u8, @intCast(mins % 10)) + '0';
    buf[2] = ':';
    buf[3] = @as(u8, @intCast(@divTrunc(secs, 10) % 10)) + '0';
    buf[4] = @as(u8, @intCast(secs % 10)) + '0';
    return buf[0..5];
}

fn popupLayerSurfaceListener(ls: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, popup: *MediaPopup) void {
    switch (event) {
        .configure => |cfg| {
            ls.ackConfigure(cfg.serial);
            if (popup.show_pending) {
                popup.show_pending = false;
                popup.markDirty();
            }
        },
        .closed => {},
    }
}

pub const MediaPopup = struct {
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    buffer: ?ShmBuffer = null,
    font: ?Font = null,
    font_small: ?Font = null,
    font_material: ?Font = null,
    font_fallback: ?Font = null,
    visible: bool = false,
    initialized: bool = false,
    show_pending: bool = false,
    needs_redraw: bool = false,
    needs_full_redraw: bool = true,
    wave_amplitude: f32 = 0, // smooth amplitude transition (0 = flat, PROGRESS_H*0.5 = full wave)
    /// Left margin of the popup in output space (set by show(), used for coordinate conversion)
    popup_left: i32 = 0,
    output_idx: usize = 0,

    pub fn init(self: *MediaPopup, ctx: *Context, output_idx: usize, allocator: std.mem.Allocator) !void {
        if (self.initialized) return;
        self.output_idx = output_idx;

        const shm = ctx.shm orelse return error.NoShm;
        self.buffer = try ShmBuffer.create(shm, POPUP_W, POPUP_H);

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
        // Fallback font for missing glyphs
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

    pub fn show(self: *MediaPopup, ctx: *Context) void {
        if (!self.initialized or self.visible) return;

        const output = &ctx.outputs[self.output_idx];
        const compositor = ctx.compositor orelse return;
        const layer_shell = ctx.layer_shell orelse return;

        // Create fresh surface + layer (like end-4 Loader destroys/recreates PanelWindow)
        const surface = compositor.createSurface() catch return;
        const layer = layer_shell.getLayerSurface(
            surface,
            output.output,
            .overlay,
            "mist-media-controls",
        ) catch return;

        layer.setSize(POPUP_W, POPUP_H);
        layer.setAnchor(.{ .top = true, .left = true });
        layer.setExclusiveZone(0);
        layer.setKeyboardInteractivity(.on_demand);
        layer.setListener(*MediaPopup, popupLayerSurfaceListener, self);

        // Position so art thumbnail center aligns with media widget ring center (media_area_x0 + 18)
        const output_w = if (ctx.output_count > 0) ctx.outputs[0].mode_w else 1366;
        const ring_cx = ctx.media_area_x0 + 18;
        const art_cx_in_popup = MARGIN + ART_SIZE / 2;
        var popup_left = ring_cx - art_cx_in_popup;
        if (popup_left < 0) popup_left = 0;
        if (popup_left + POPUP_W > output_w and output_w > POPUP_W) {
            popup_left = output_w - POPUP_W;
        }
        self.popup_left = popup_left;
        layer.setMargin(POPUP_MARGIN_TOP, 0, 0, popup_left);

        // Must wait for first configure before attaching a buffer (protocol requirement)
        self.surface = surface;
        self.layer_surface = layer;
        self.show_pending = true;

        // First commit (no buffer) — triggers compositor to send configure
        surface.commit();
        ctx.flush();

        // Wait for configure event
        ctx.roundtrip();
        // configure listener fired → show_pending = false

        // Now safe to attach buffer: draw full content
        self.visible = true;
        ctx.popup_surface = surface;
        self.markDirty();
        {
            const saved = self.show_pending;
            self.show_pending = false;
            self.draw(ctx);
            self.show_pending = saved;
        }

        // Attach buffer and commit (surface appears with full content, no flash)
        surface.damageBuffer(0, 0, POPUP_W, POPUP_H);
        surface.commit();
        ctx.flush();
    }

    pub fn hide(self: *MediaPopup, ctx: *Context) void {
        if (!self.visible) return;
        self.visible = false;
        ctx.popup_surface = null;

        // Destroy surface + layer (compositor sends leave events, next show is fresh)
        if (self.layer_surface) |ls| {
            ls.destroy();
        }
        if (self.surface) |s| {
            s.destroy();
        }
        self.layer_surface = null;
        self.surface = null;
        ctx.flush();
    }

    pub fn toggle(self: *MediaPopup, ctx: *Context) void {
        if (self.visible) {
            self.hide(ctx);
        } else {
            self.show(ctx);
        }
    }

    fn drawProgress(canvas: *Canvas, self: *MediaPopup, mpris: *const mpris_mod.MprisPlayer, colLayer0: Color, colPrimary: Color, colSecondaryContainer: Color, colSubtext: Color) void {
        // Clear progress bar area + wave overshoot, then redraw waves
        const PROGRESS_X: i32 = COL_X;
        const PROGRESS_W: i32 = POPUP_W - COL_X - MARGIN;
        const max_amplitude: f32 = @as(f32, @floatFromInt(PROGRESS_H)) * 0.5;
        const overshoot: i32 = @as(i32, @intFromFloat(max_amplitude)) + 1;
        canvas.fillRect(PROGRESS_X, PROGRESS_Y - overshoot, PROGRESS_W, PROGRESS_H + 2 * overshoot, colLayer0);

        const progress: f32 = if (mpris.length > 0)
            @as(f32, @floatFromInt(mpris.position)) / @as(f32, @floatFromInt(mpris.length))
        else
            0;
        const fillW: i32 = if (progress > 0)
            @intFromFloat(@as(f32, @floatFromInt(PROGRESS_W)) * progress)
        else
            0;

        const is_playing = mpris.status == .playing;
        const target_amplitude: f32 = if (is_playing and PROGRESS_W > PROGRESS_H) max_amplitude else 0;
        self.wave_amplitude += (target_amplitude - self.wave_amplitude) * 0.5;
        if (@abs(self.wave_amplitude - target_amplitude) < 0.001) {
            self.wave_amplitude = target_amplitude;
        }
        if (@abs(self.wave_amplitude - target_amplitude) > 0.001 and !is_playing) {
            self.needs_redraw = true;
        }

        const cycles: f32 = 6.0;
        const freq = cycles * std.math.tau / @as(f32, @floatFromInt(PROGRESS_W));
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        const ms = @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
        const phase = @as(f32, @floatFromInt(ms)) / 400.0;

        canvas.fillSineWave(PROGRESS_X, PROGRESS_Y, PROGRESS_W, PROGRESS_H, self.wave_amplitude, freq, phase, colSecondaryContainer);
        if (fillW > 0) {
            canvas.fillSineWave(PROGRESS_X, PROGRESS_Y, fillW, PROGRESS_H, self.wave_amplitude, freq, phase, colPrimary);
        }

        // Clear time text area above baseline (text renders above baseline, not below)
        var posBuf: [16]u8 = undefined;
        var lenBuf: [16]u8 = undefined;
        const posStr = formatTime(mpris.position, &posBuf);
        const lenStr = formatTime(mpris.length, &lenBuf);
        var timeFullBuf: [64]u8 = undefined;
        const timeStr = std.fmt.bufPrint(&timeFullBuf, "{s} / {s}", .{ posStr, lenStr }) catch "";
        if (self.font_small) |*f| {
            const lh = f.lineHeight();
            canvas.fillRect(COL_X, TIME_Y - lh, POPUP_W - COL_X - MARGIN, lh, colLayer0);
            if (timeStr.len > 0) {
                render_mod.renderText(canvas, f, timeStr, COL_X, TIME_Y, colSubtext);
            }
        }
    }

    fn drawFull(canvas: *Canvas, self: *MediaPopup, mpris: *const mpris_mod.MprisPlayer, colLayer0: Color, colOnLayer0: Color, colOnLayer1: Color, colSubtext: Color, colPrimary: Color, colOnPrimary: Color, colSecondaryContainer: Color) void {
        canvas.fill(Color.rgba(0xec, 0xe6, 0xe9, 0xFF));
        canvas.fillRoundedRectAA(0, 0, POPUP_W, POPUP_H, 12, colLayer0);

        const artR: i32 = 12;
        if (mpris.art_has) {
            canvas.blitRoundedClipped(&mpris.art_rgb, ART_SIZE, ART_SIZE, MARGIN, MARGIN, ART_SIZE, ART_SIZE, artR);
        } else {
            canvas.fillRoundedRectAA(MARGIN, MARGIN, ART_SIZE, ART_SIZE, artR, colSecondaryContainer);
            if (self.font_material) |*fMat| {
                const tbl = MARGIN + @divTrunc(ART_SIZE - fMat.lineHeight(), 2) + fMat.baselineOffset();
                const iw = render_mod.textWidth(fMat, "music_note");
                render_mod.renderText(canvas, fMat, "music_note", MARGIN + @divTrunc(ART_SIZE - iw, 2), tbl, colOnLayer1);
            }
        }

        const title_str: []const u8 = if (mpris.has_player and mpris.title.len > 0) mpris.title else "No media";
        if (self.font) |*f| {
            const maxW: i32 = POPUP_W - COL_X - MARGIN;
            var buf2: [256]u8 = undefined;
            const display = if (maxW > 0 and render_mod.textWidth(f, title_str) > maxW) blk: {
                var lo: usize = 0;
                var hi: usize = title_str.len;
                while (lo < hi) {
                    const mid = (lo + hi + 1) / 2;
                    if (render_mod.textWidth(f, title_str[0..mid]) <= maxW - 12) lo = mid else hi = mid - 1;
                }
                if (lo == 0) break :blk "";
                @memcpy(buf2[0..lo], title_str[0..lo]);
                buf2[lo] = '.'; buf2[lo + 1] = '.'; buf2[lo + 2] = '.';
                break :blk buf2[0 .. lo + 3];
            } else title_str;
            if (maxW > 0) {
                render_mod.renderText(canvas, f, display, COL_X, TITLE_Y, colOnLayer0);
            }
        }

        if (mpris.has_player and mpris.artist.len > 0) {
            if (self.font_small) |*f| {
                const maxW: i32 = POPUP_W - COL_X - MARGIN;
                var buf2: [256]u8 = undefined;
                const display = if (maxW > 0 and render_mod.textWidth(f, mpris.artist) > maxW) blk: {
                    var lo: usize = 0;
                    var hi: usize = mpris.artist.len;
                    while (lo < hi) {
                        const mid = (lo + hi + 1) / 2;
                        if (render_mod.textWidth(f, mpris.artist[0..mid]) <= maxW - 12) lo = mid else hi = mid - 1;
                    }
                    if (lo == 0) break :blk "";
                    @memcpy(buf2[0..lo], mpris.artist[0..lo]);
                    buf2[lo] = '.'; buf2[lo + 1] = '.'; buf2[lo + 2] = '.';
                    break :blk buf2[0 .. lo + 3];
                } else mpris.artist;
                if (maxW > 0) {
                    render_mod.renderText(canvas, f, display, COL_X, ARTIST_Y, colSubtext);
                }
            }
        }

        canvas.fillCircle(PREV_CX, BTN_Y, @floatFromInt(BTN_R), colSecondaryContainer);
        if (self.font_material) |*fMat| {
            const tbl = BTN_Y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
            const iw = render_mod.textWidth(fMat, "skip_previous");
            render_mod.renderText(canvas, fMat, "skip_previous", PREV_CX - @divTrunc(iw, 2), tbl, colOnLayer1);
        }

        canvas.fillCircle(PLAY_CX, BTN_Y, @floatFromInt(BTN_R), colPrimary);
        if (self.font_material) |*fMat| {
            const tbl = BTN_Y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
            const icon = if (mpris.has_player and mpris.status == .playing) "pause" else "play_arrow";
            const iw = render_mod.textWidth(fMat, icon);
            render_mod.renderText(canvas, fMat, icon, PLAY_CX - @divTrunc(iw, 2), tbl, colOnPrimary);
        }

        canvas.fillCircle(NEXT_CX, BTN_Y, @floatFromInt(BTN_R), colSecondaryContainer);
        if (self.font_material) |*fMat| {
            const tbl = BTN_Y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
            const iw = render_mod.textWidth(fMat, "skip_next");
            render_mod.renderText(canvas, fMat, "skip_next", NEXT_CX - @divTrunc(iw, 2), tbl, colOnLayer1);
        }
    }

    pub fn draw(self: *MediaPopup, ctx: *Context) void {
        if (!self.visible or self.show_pending or !self.needs_redraw) return;
        const buf = self.buffer orelse return;
        const mpris = ctx.mpris orelse return;

        var canvas = Canvas{
            .data = buf.data,
            .width = buf.width,
            .height = buf.height,
            .stride = buf.stride,
        };

        const colLayer0 = Color.rgba(0x1c, 0x1b, 0x1c, 0xFF);
        const colOnLayer0 = Color.rgba(0xe6, 0xe1, 0xe1, 0xFF);
        const colOnLayer1 = Color.rgba(0xcb, 0xc5, 0xca, 0xFF);
        const colSubtext = Color.rgba(0x94, 0x8f, 0x94, 0xFF);
        const colPrimary = Color.rgba(0xcb, 0xc4, 0xcb, 0xFF);
        const colOnPrimary = Color.rgba(0x32, 0x2f, 0x34, 0xFF);
        const colSecondaryContainer = Color.rgba(0x4d, 0x4b, 0x4d, 0x99);

        if (self.needs_full_redraw) {
            self.needs_full_redraw = false;
            drawFull(&canvas, self, mpris, colLayer0, colOnLayer0, colOnLayer1, colSubtext, colPrimary, colOnPrimary, colSecondaryContainer);
        }

        drawProgress(&canvas, self, mpris, colLayer0, colPrimary, colSecondaryContainer, colSubtext);
        self.needs_redraw = false;
    }

    pub fn markDirty(self: *MediaPopup) void {
        self.needs_redraw = true;
        self.needs_full_redraw = true;
    }

    pub fn markProgressDirty(self: *MediaPopup) void {
        self.needs_redraw = true;
    }

    pub fn commit(self: *MediaPopup, ctx: *Context) void {
        if (!self.visible or self.show_pending) return;
        const buf = self.buffer orelse return;

        if (self.surface) |s| {
            s.attach(buf.buffer, 0, 0);
            s.damageBuffer(0, 0, buf.width, buf.height);
            s.commit();
        }
        ctx.flush();
    }

    pub fn handleClick(self: *MediaPopup, x: i32, y: i32, button: u32, mpris: *mpris_mod.MprisPlayer) void {
        if (!self.visible) return;
        if (button != 0x110) return;

        const rSq = BTN_R * BTN_R;
        if ((x - PREV_CX) * (x - PREV_CX) + (y - BTN_Y) * (y - BTN_Y) <= rSq) {
            mpris.previous();
        } else if ((x - PLAY_CX) * (x - PLAY_CX) + (y - BTN_Y) * (y - BTN_Y) <= rSq) {
            mpris.playPause();
        } else if ((x - NEXT_CX) * (x - NEXT_CX) + (y - BTN_Y) * (y - BTN_Y) <= rSq) {
            mpris.next();
        }
    }

    pub fn deinit(self: *MediaPopup) void {
        if (self.font) |*f| f.deinit();
        if (self.font_small) |*f| f.deinit();
        if (self.font_material) |*f| f.deinit();
        if (self.font_fallback) |*f| f.deinit();
        if (self.buffer) |*b| b.deinit();
        if (self.layer_surface) |ls| ls.destroy();
        if (self.surface) |s| s.destroy();
        self.* = undefined;
    }
};
