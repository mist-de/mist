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

pub const POPUP_MARGIN_TOP: i32 = 40;
const OSD_W: i32 = 180;

const MARGIN: i32 = 10;
const SPACING: i32 = 12;
const ART_SIZE: i32 = POPUP_H - MARGIN * 2;
const COL_X: i32 = MARGIN + ART_SIZE + SPACING;
const COL_R: i32 = POPUP_W - MARGIN;

const TITLE_Y: i32 = 18;
const ARTIST_Y: i32 = 36;
const TIME_Y: i32 = 72;
const BTN_Y: i32 = 112;

// Buttons centered horizontally in the content area (end-4: prev+next on slider row, play/pause on time row)
const COL_CENTER = COL_X + (COL_R - COL_X) / 2;
const PREV_CX: i32 = COL_CENTER - 50;
const PLAY_CX: i32 = COL_CENTER;
const NEXT_CX: i32 = COL_CENTER + 50;
const BTN_R: i32 = 16;

/// end-4 PlayerControl layout:
/// [art_square] [column: title, artist, spacer, time_row, progress+buttons]
fn formatTime(us: i64, buf: []u8) []const u8 {
    const clamped = if (us >= 0) us else @as(i64, 0);
    const total_secs = @divTrunc(clamped, 1000000);
    const mins = @divTrunc(total_secs, 60);
    const secs = @rem(total_secs, 60);
    return std.fmt.bufPrint(buf, "{d}:{d:02}", .{ mins, secs }) catch "0:00";
}

fn popupLayerSurfaceListener(ls: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, popup: *MediaPopup) void {
    switch (event) {
        .configure => |cfg| {
            ls.ackConfigure(cfg.serial);
            popup.layer_configured = true;
            if (popup.show_pending) {
                popup.show_pending = false;
                popup.needs_redraw = true;
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
    visible: bool = false,
    initialized: bool = false,
    layer_configured: bool = false,
    show_pending: bool = false,
    needs_redraw: bool = true,

    pub fn init(self: *MediaPopup, ctx: *Context, output_idx: usize, allocator: std.mem.Allocator) !void {
        if (self.initialized) return;
        const output = &ctx.outputs[output_idx];
        const compositor = ctx.compositor orelse return error.NoCompositor;
        const layer_shell = ctx.layer_shell orelse return error.NoLayerShell;

        const surface = try compositor.createSurface();
        const layer = try layer_shell.getLayerSurface(
            surface,
            output.output,
            .overlay,
            "mist-media-controls",
        );

        layer.setSize(POPUP_W, POPUP_H);
        layer.setAnchor(.{ .top = true, .left = true });
        layer.setMargin(-1000, 0, 0, 0);
        layer.setExclusiveZone(0);
        layer.setKeyboardInteractivity(.none);
        layer.setListener(*MediaPopup, popupLayerSurfaceListener, self);
        surface.commit();

        self.surface = surface;
        self.layer_surface = layer;

        ctx.roundtrip();

        if (!self.layer_configured) return error.PopupNotConfigured;

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

        self.initialized = true;
    }

    pub fn show(self: *MediaPopup, ctx: *Context) void {
        if (!self.initialized or self.visible) return;
        self.visible = true;
        ctx.popup_surface = self.surface;

        // end-4: left = screen.width/2 - osdWidth/2 - widgetWidth, top = barHeight
        // popup right edge aligns with left edge of OSD area (battery, network)
        const output_w = if (ctx.output_count > 0) ctx.outputs[0].mode_w else 1366;
        var popup_left = @divTrunc(output_w, 2) - @divTrunc(OSD_W, 2) - POPUP_W;
        if (popup_left < 0) popup_left = 0;
        if (popup_left + POPUP_W > output_w and output_w > POPUP_W) {
            popup_left = output_w - POPUP_W;
        }

        if (self.layer_surface) |ls| {
            ls.setMargin(POPUP_MARGIN_TOP, 0, 0, popup_left);
            ls.setSize(POPUP_W, POPUP_H);
        }

        // Commit state change without buffer — wait for configure before attaching buffer
        self.show_pending = true;
        if (self.surface) |s| s.commit();
        ctx.flush();
    }

    pub fn hide(self: *MediaPopup, ctx: *Context) void {
        if (!self.visible) return;
        self.visible = false;
        ctx.popup_surface = null;

        // Unmap by attaching NULL
        if (self.surface) |s| {
            s.attach(null, 0, 0);
            s.commit();
        }
        ctx.flush();
    }

    pub fn toggle(self: *MediaPopup, ctx: *Context) void {
        if (self.visible) {
            self.hide(ctx);
        } else {
            self.show(ctx);
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

        canvas.fill(Color.transparent);

        const colLayer0 = Color.rgba(0x1c, 0x1b, 0x1c, 0xFF);
        const colOnLayer0 = Color.rgba(0xe6, 0xe1, 0xe1, 0xFF);
        const colOnLayer1 = Color.rgba(0xcb, 0xc5, 0xca, 0xFF);
        const colSubtext = Color.rgba(0x94, 0x8f, 0x94, 0xFF);
        const colPrimary = Color.rgba(0xcb, 0xc4, 0xcb, 0xFF);
        const colOnPrimary = Color.rgba(0x32, 0x2f, 0x34, 0xFF);
        const colSecondaryContainer = Color.rgba(0x4d, 0x4b, 0x4d, 0x99);

        canvas.fillRoundedRectAA(0, 0, POPUP_W, POPUP_H, 12, colLayer0);

        // Art placeholder (colored square, end-4 uses album art here)
        const artR: i32 = 6;
        canvas.fillRoundedRectAA(MARGIN, MARGIN, ART_SIZE, ART_SIZE, artR, colSecondaryContainer);
        if (self.font_material) |*fMat| {
            const tbl = MARGIN + @divTrunc(ART_SIZE - fMat.lineHeight(), 2) + fMat.baselineOffset();
            const iw = render_mod.textWidth(fMat, "music_note");
            render_mod.renderText(&canvas, fMat, "music_note", MARGIN + @divTrunc(ART_SIZE - iw, 2), tbl, colOnLayer1);
        }

        // Title
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
                render_mod.renderText(&canvas, f, display, COL_X, TITLE_Y, colOnLayer0);
            }
        }

        // Artist
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
                    render_mod.renderText(&canvas, f, display, COL_X, ARTIST_Y, colSubtext);
                }
            }
        }

        // Time display (mm:ss / mm:ss) — always show even if length=0
        var posBuf: [16]u8 = undefined;
        var lenBuf: [16]u8 = undefined;
        const posStr = formatTime(mpris.position, &posBuf);
        const lenStr = formatTime(mpris.length, &lenBuf);
        var timeFullBuf: [64]u8 = undefined;
        const timeStr = if (mpris.has_player)
            std.fmt.bufPrint(&timeFullBuf, "{s} / {s}", .{ posStr, lenStr }) catch ""
        else "";
        if (self.font_small) |*f| {
            if (timeStr.len > 0) {
                render_mod.renderText(&canvas, f, timeStr, COL_X, TIME_Y, colSubtext);
            }
        }

        // Progress bar
        const PROGRESS_X: i32 = COL_X;
        const PROGRESS_W: i32 = POPUP_W - COL_X - MARGIN;
        const PROGRESS_Y: i32 = TIME_Y + 18;
        const PROGRESS_H: i32 = 4;
        const progress: f32 = if (mpris.has_player and mpris.length > 0)
            @as(f32, @floatFromInt(mpris.position)) / @as(f32, @floatFromInt(mpris.length))
        else
            0;
        canvas.fillRoundedRectAA(PROGRESS_X, PROGRESS_Y, PROGRESS_W, PROGRESS_H, @divTrunc(PROGRESS_H, 2), colSecondaryContainer);
        if (progress > 0) {
            const fillW: i32 = @intFromFloat(@as(f32, @floatFromInt(PROGRESS_W)) * progress);
            canvas.fillRoundedRectAA(PROGRESS_X, PROGRESS_Y, fillW, PROGRESS_H, @divTrunc(PROGRESS_H, 2), colPrimary);
        }

        // Buttons: prev, play/pause, next

        canvas.fillCircle(PREV_CX, BTN_Y, @floatFromInt(BTN_R), colSecondaryContainer);
        if (self.font_material) |*fMat| {
            const tbl = BTN_Y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
            const iw = render_mod.textWidth(fMat, "skip_previous");
            render_mod.renderText(&canvas, fMat, "skip_previous", PREV_CX - @divTrunc(iw, 2), tbl, colOnLayer1);
        }

        canvas.fillCircle(PLAY_CX, BTN_Y, @floatFromInt(BTN_R), colPrimary);
        if (self.font_material) |*fMat| {
            const tbl = BTN_Y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
            const icon = if (mpris.has_player and mpris.status == .playing) "pause" else "play_arrow";
            const iw = render_mod.textWidth(fMat, icon);
            render_mod.renderText(&canvas, fMat, icon, PLAY_CX - @divTrunc(iw, 2), tbl, colOnPrimary);
        }

        canvas.fillCircle(NEXT_CX, BTN_Y, @floatFromInt(BTN_R), colSecondaryContainer);
        if (self.font_material) |*fMat| {
            const tbl = BTN_Y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
            const iw = render_mod.textWidth(fMat, "skip_next");
            render_mod.renderText(&canvas, fMat, "skip_next", NEXT_CX - @divTrunc(iw, 2), tbl, colOnLayer1);
        }

        self.needs_redraw = false;
    }

    pub fn markDirty(self: *MediaPopup) void {
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
        if (self.buffer) |*b| b.deinit();
        if (self.layer_surface) |ls| ls.destroy();
        if (self.surface) |s| s.destroy();
        self.* = undefined;
    }
};
