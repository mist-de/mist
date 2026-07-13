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

const SLIDER_W: i32 = 30;
const SLIDER_H: i32 = 150;
const PAD_LARGE: i32 = 16;
const HANDLE_R: i32 = @divTrunc(SLIDER_W, 2); // 15
const SLIDER_X: i32 = 22;
const PANEL_W: i32 = 60;
const PANEL_H: i32 = 2 * PAD_LARGE + SLIDER_H; // 182
const BLOB_R: i32 = 28;
const OSD_TIMEOUT_MS: i64 = 2000;

const col_blob = Color.rgba(0x19, 0x11, 0x14, 0xFF);
const col_track = Color.rgba(0x26, 0x1D, 0x20, 0xFF);
const col_fill = Color.rgba(0xE2, 0xBD, 0xC7, 0xFF);
const col_handle = Color.rgba(0xEF, 0xDF, 0xE2, 0xFF);
const col_icon = Color.rgba(0x37, 0x2E, 0x30, 0xFF);
const col_label = Color.rgba(0xD5, 0xC2, 0xC6, 0xFF);

fn layerSurfaceListener(ls: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, osd: *Osd) void {
    _ = osd;
    switch (event) {
        .configure => |ev| {
            _ = ev.width;
            _ = ev.height;
            ls.ackConfigure(ev.serial);
        },
        .closed => {},
    }
}

fn bufferReleaseListener(_: *wl.Buffer, event: wl.Buffer.Event, osd: *Osd) void {
    switch (event) {
        .release => osd.buf_busy = false,
    }
}

pub const Osd = struct {
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    buffer: ?ShmBuffer = null,
    buf_busy: bool = false,

    font: ?Font = null,
    font_material: ?Font = null,
    font_fallback: ?Font = null,

    initialized: bool = false,
    visible: bool = false,
    needs_redraw: bool = false,

    output_idx: usize = 0,
    output_h: i32 = 0,

    volume: f32 = 0.75,
    muted: bool = false,
    last_change_ms: i64 = 0,

    pub fn init(self: *Osd, ctx: *Context, output_idx: usize, allocator: std.mem.Allocator) !void {
        self.output_idx = output_idx;
        if (output_idx < ctx.output_count)
            self.output_h = ctx.outputs[output_idx].mode_h;

        const cfg = config_mod.get();
        if (config_mod.resolveFontPath(allocator, cfg.font_regular)) |fp| {
            defer allocator.free(fp);
            self.font = Font.init(allocator, fp, cfg.font_size) catch null;
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

        const compositor = ctx.compositor orelse return error.NoCompositor;
        const layer_shell = ctx.layer_shell orelse return error.NoLayerShell;
        const output_wl = ctx.outputs[output_idx].output;

        const surface = try compositor.createSurface();
        errdefer surface.destroy();

        const layer = try layer_shell.getLayerSurface(surface, output_wl, .overlay, "mist-osd");
        errdefer layer.destroy();

        layer.setAnchor(.{ .top = true, .right = true });
        layer.setSize(@as(u32, @intCast(PANEL_W)), @as(u32, @intCast(PANEL_H)));
        layer.setExclusiveZone(0);
        layer.setKeyboardInteractivity(.none);
        layer.setListener(*Osd, layerSurfaceListener, self);

        const top_margin = self.verticalMargin();
        layer.setMargin(top_margin, 0, 0, -(PANEL_W + 5));

        self.surface = surface;
        self.layer_surface = layer;

        surface.commit();
        ctx.flush();
        ctx.roundtrip();

        const shm = ctx.shm orelse return error.NoShm;
        const shm_buf = try ShmBuffer.create(shm, PANEL_W, PANEL_H);
        if (shm_buf.buffer) |wb| wb.setListener(*Osd, bufferReleaseListener, self);
        self.buffer = shm_buf;

        self.initialized = true;
    }

    fn verticalMargin(self: *Osd) i32 {
        if (self.output_h > PANEL_H)
            return @divTrunc(self.output_h - PANEL_H, 2);
        return 0;
    }

    pub fn show(self: *Osd, ctx: *Context) void {
        if (!self.initialized) return;
        if (self.visible) {
            self.needs_redraw = true;
            return;
        }

        const ls = self.layer_surface orelse return;
        const s = self.surface orelse return;

        const top_margin = self.verticalMargin();
        ls.setMargin(top_margin, 0, 0, 0);
        s.commit();
        ctx.flush();

        self.visible = true;
        self.needs_redraw = true;
        self.last_change_ms = ctx.now_ms;
    }

    pub fn hide(self: *Osd, ctx: *Context) void {
        if (!self.visible) return;
        const ls = self.layer_surface orelse return;
        const s = self.surface orelse return;

        self.visible = false;

        ls.setMargin(self.verticalMargin(), 0, 0, -(PANEL_W + 5));
        s.commit();
        ctx.flush();
    }

    pub fn draw(self: *Osd, _: *Context) void {
        if (!self.visible or !self.needs_redraw) return;
        if (self.buf_busy) return;
        const buf = self.buffer orelse return;
        var canvas = Canvas{
            .data = buf.data,
            .width = @intCast(buf.width),
            .height = @intCast(buf.height),
            .stride = buf.stride,
        };
        canvas.fill(Color.transparent);

        // Background blob (PanelBg matching m3surface, radius extraLarge=28)
        canvas.fillRoundedRectAA(0, 0, PANEL_W, PANEL_H, BLOB_R, col_blob);

        const sx = SLIDER_X;
        const sy = PAD_LARGE;

        canvas.fillRoundedRectAA(sx, sy, SLIDER_W, SLIDER_H, HANDLE_R, col_track);

        const usable_h: f32 = @floatFromInt(SLIDER_H - SLIDER_W);
        const handle_y_f = @as(f32, @floatFromInt(sy)) + (1.0 - self.volume) * usable_h;
        const handle_y: i32 = @intFromFloat(handle_y_f);

        const fill_h = (sy + SLIDER_H) - handle_y;
        if (fill_h > 0) {
            canvas.fillRoundedRectCorners(sx, handle_y, SLIDER_W, fill_h, 0, 0, HANDLE_R, HANDLE_R, col_fill);
        }

        const cx = sx + HANDLE_R;
        const cy = handle_y + HANDLE_R;
        canvas.fillCircle(cx, cy, @floatFromInt(HANDLE_R), col_handle);

        if (self.font_material) |*fMat| {
            const icon = if (self.muted) "volume_off" else "volume_up";
            const iw = render_mod.textWidth(fMat, icon);
            const ih = render_mod.measureGlyph(fMat, icon);
            const ix = cx - @divTrunc(iw, 2);
            const iy = cy + @divTrunc(ih.height, 2) - ih.top;
            render_mod.renderText(&canvas, fMat, icon, ix, iy, col_icon);
        }

        if (self.font) |*f| {
            var pct_buf: [8]u8 = undefined;
            const pct = std.fmt.bufPrint(&pct_buf, "{d:.0}%", .{self.volume * 100}) catch return;
            const tw = render_mod.textWidth(f, pct);
            const tx = sx + @divTrunc(SLIDER_W - tw, 2);
            var label_y = cy + HANDLE_R + 4;
            const line_h = f.lineHeight();
            const bottom = sy + SLIDER_H;
            if (label_y + line_h > bottom)
                label_y = cy - HANDLE_R - line_h - 4;
            if (label_y < sy + 2)
                label_y = sy + 2;
            render_mod.renderText(&canvas, f, pct, tx, label_y + f.baselineOffset(), col_label);
        }

        self.needs_redraw = false;
    }

    pub fn commit(self: *Osd, _: *Context) void {
        if (!self.visible) return;
        if (self.buf_busy) return;
        const s = self.surface orelse return;
        const buf = self.buffer orelse return;

        s.attach(buf.buffer, 0, 0);
        s.damageBuffer(0, 0, PANEL_W, PANEL_H);
        s.commit();
        self.buf_busy = true;
    }

    pub fn setVolume(self: *Osd, ctx: *Context, vol: f32, muted: bool) void {
        self.volume = @min(1.0, @max(0.0, vol));
        self.muted = muted;
        self.last_change_ms = ctx.now_ms;
        self.needs_redraw = true;
        self.show(ctx);
    }

    pub fn tick(self: *Osd, ctx: *Context) void {
        if (!self.visible) return;
        if (ctx.now_ms - self.last_change_ms >= OSD_TIMEOUT_MS)
            self.hide(ctx);
    }
};
