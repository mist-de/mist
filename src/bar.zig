const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Context = @import("wl.zig").Context;
const LayerSurface = @import("wl.zig").LayerSurface;
const ShmBuffer = @import("wl.zig").ShmBuffer;
const CursorShape = @import("wl.zig").CursorShape;
const Canvas = @import("render.zig").Canvas;
const render_mod = @import("render.zig");
const Font = render_mod.Font;
const config_mod = @import("config.zig");
const Color = config_mod.Color;
const Appearance = config_mod.Appearance;
const Rect = config_mod.Rect;

// ═══════════════════════════════════════════════════════════
// OutputState — per-output bar lifecycle
// ═══════════════════════════════════════════════════════════

pub const OutputState = struct {
    bar: ?Bar = null,
    output_idx: usize,
    name: [64]u8 = .{0} ** 64,
    configured: bool = false,
};

var outputs: [8]OutputState = undefined;
var output_count: usize = 0;

pub fn initOutput(ctx: *Context, output_idx: usize) !void {
    const name = std.mem.sliceTo(&ctx.outputs[output_idx].name, 0);
    if (output_count < 8) {
        outputs[output_count] = .{ .output_idx = output_idx };
        const name_len = @min(name.len, outputs[output_count].name.len - 1);
        @memcpy(outputs[output_count].name[0..name_len], name[0..name_len]);
        output_count += 1;
    }
    try ensureBar(ctx, output_idx);
}

fn ensureBar(ctx: *Context, output_idx: usize) !void {
    const name = std.mem.sliceTo(&ctx.outputs[output_idx].name, 0);
    for (0..output_count) |i| {
        const out = &outputs[i];
        if (out.output_idx != output_idx) continue;
        if (out.bar != null) return;

        out.bar = try Bar.init(ctx.allocator, ctx, output_idx, name);
        if (out.bar) |*bar| {
            if (bar.layer.layer_surface) |ls| {
                ls.setListener(*Bar, Bar.layerSurfaceListener, bar);
            }
        }
        break;
    }
}

pub fn drawOutputs(ctx: *Context) void {
    for (0..output_count) |i| {
        const out = &outputs[i];
        if (out.bar == null) continue;
        const output_info = &ctx.outputs[out.output_idx];
        const width = output_info.mode_w;
        if (width <= 0) continue;

        const bar = &out.bar.?;
        bar.ensureBuffer(ctx, width) catch continue;
        bar.draw(ctx) catch |err| {
            std.log.warn("draw: {s}", .{@errorName(err)});
        };
    }
}

pub fn deinitOutputs() void {
    for (0..output_count) |i| {
        if (outputs[i].bar) |*b| b.deinit();
    }
    output_count = 0;
}

pub fn markAllDirty(ctx: *Context) void {
    _ = ctx;
    for (0..output_count) |i| {
        if (outputs[i].bar) |*bar| bar.needs_full_redraw = true;
    }
}

// ═══════════════════════════════════════════════════════════
// Bar — widget drawing and layout
// ═══════════════════════════════════════════════════════════

pub const Bar = struct {
    pub fn layerSurfaceListener(ls: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, bar: *Bar) void {
        switch (event) {
            .configure => |cfg| {
                ls.ackConfigure(cfg.serial);
                bar.layer.configured = true;
                bar.layer.width = @intCast(cfg.width);
                bar.layer.height = @intCast(cfg.height);
                bar.needs_full_redraw = true;
            },
            .closed => {},
        }
    }

    output_name: [64]u8,
    layer: LayerSurface = undefined,
    buffer: ?ShmBuffer = null,
    rect: Rect = .zero,
    font: ?Font = null,
    font_icon: ?Font = null,
    font_material: ?Font = null,
    needs_full_redraw: bool = true,

    pub fn init(allocator: std.mem.Allocator, ctx: *Context, output_idx: usize, name: []const u8) !Bar {
        const output = &ctx.outputs[output_idx];
        const cfg = config_mod.get();
        const anchor: zwlr.LayerSurfaceV1.Anchor = if (cfg.bottom)
            .{ .bottom = true, .left = true, .right = true }
        else
            .{ .top = true, .left = true, .right = true };

        var bar = Bar{ .output_name = .{0} ** 64 };
        const name_len = @min(name.len, bar.output_name.len - 1);
        @memcpy(bar.output_name[0..name_len], name[0..name_len]);

        bar.layer = try LayerSurface.create(ctx, output, anchor, cfg.height);
        bar.rect = .{ .x = 0, .y = 0, .width = 0, .height = cfg.height };

        {
            if (config_mod.resolveFontPath(allocator, cfg.font_regular)) |fp| {
                defer allocator.free(fp);
                bar.font = Font.init(allocator, fp, cfg.font_size) catch null;
            } else |_| {}
            if (config_mod.resolveFontPath(allocator, cfg.font_icon)) |fp| {
                defer allocator.free(fp);
                bar.font_icon = Font.init(allocator, fp, cfg.font_size) catch null;
            } else |_| {}
            if (config_mod.resolveFontPath(allocator, cfg.font_material)) |fp| {
                defer allocator.free(fp);
                bar.font_material = Font.init(allocator, fp, cfg.font_size_material) catch null;
            } else |_| {}
        }

        if (bar.font == null) std.log.err("NO REGULAR FONT LOADED", .{});
        if (bar.font_icon == null) std.log.err("NO ICON FONT LOADED", .{});
        if (bar.font_material == null) std.log.err("NO MATERIAL FONT LOADED", .{});

        return bar;
    }

    pub fn deinit(self: *Bar) void {
        if (self.buffer) |*b| b.deinit();
        if (self.font) |*f| f.deinit();
        if (self.font_icon) |*f| f.deinit();
        if (self.font_material) |*f| f.deinit();
        self.layer.destroy();
    }

    pub fn ensureBuffer(self: *Bar, ctx: *Context, width: i32) !void {
        if (self.buffer != null and self.buffer.?.width == width) return;
        if (self.buffer) |*b| b.deinit();
        const shm = ctx.shm orelse return;
        self.buffer = try ShmBuffer.create(shm, width, @intCast(self.rect.height));
        self.rect.width = @intCast(width);
        self.needs_full_redraw = true;
    }

    pub fn draw(self: *Bar, ctx: *Context) !void {
        if (!self.needs_full_redraw) return;
        const buf = self.buffer orelse return;
        var canvas = Canvas{
            .data = buf.data,
            .width = buf.width,
            .height = buf.height,
            .stride = buf.stride,
        };

        const bar_h: i32 = @intCast(self.rect.height);
        const bar_w: i32 = @intCast(self.rect.width);

        canvas.fill(Color.transparent);

        // ═══ M3 Dark Mode Colors (exact from end-4 Appearance.qml) ═══
        const colLayer0 = Color.rgba(0x14, 0x13, 0x13, 0xFF);
        const colLayer1 = Color.rgba(0x1c, 0x1b, 0x1c, 0xFF);
        const colOnLayer0 = Color.rgba(0xe6, 0xe1, 0xe1, 0xFF);
        const colOnLayer1 = Color.rgba(0xcb, 0xc5, 0xca, 0xFF);
        const colOnLayer1Inactive = Color.rgba(0x7d, 0x78, 0x7c, 0xFF);
        const colPrimary = Color.rgba(0xcb, 0xc4, 0xcb, 0xFF);
        const colOnPrimary = Color.rgba(0x32, 0x2f, 0x34, 0xFF);
        const colSecondaryContainer = Color.rgba(0x4d, 0x4b, 0x4d, 0x99); // end-4: transparentize(0.4) = 60% opaque
        const colOnSecondaryContainer = Color.rgba(0xec, 0xe6, 0xe9, 0xFF);
        const colOutline = Color.rgba(0x94, 0x8f, 0x94, 0xFF);
        const colSubtext = colOutline;

        // ═══ Layout Constants (end-4 Appearance.qml) ═══
        const screenRounding: i32 = 23;
        const smallRounding: i32 = 12;
        const fullRounding: i32 = 9999;
        const centerSpacing: i32 = 4;
        const groupPadding: i32 = 5;
        const groupBgY: i32 = 4;
        const groupBgH: i32 = bar_h - 8;
        const centerY: i32 = @divTrunc(bar_h, 2);

        const useShortenedForm: i32 = if (bar_w <= 1000) 2 else if (bar_w <= 1200) 1 else 0;
        const centerSideModuleWidth: i32 = if (useShortenedForm == 2) 190 else if (useShortenedForm == 1) 280 else 360;

        const wsBtnWidth: i32 = 26;
        const wsActiveMargin: i32 = 2;
        const wsCount: usize = 5;
        const wsTotalWidth: i32 = wsBtnWidth * @as(i32, @intCast(wsCount));
        const wsBarGroupPadding: i32 = 4;
        const wsBarGroupW: i32 = wsTotalWidth + wsBarGroupPadding * 2;

        const centerTotal: i32 = centerSideModuleWidth + centerSpacing + wsBarGroupW + centerSpacing + centerSideModuleWidth;
        const centerX: i32 = @divTrunc(bar_w - centerTotal, 2);
        const lcX: i32 = centerX;
        const mcX: i32 = lcX + centerSideModuleWidth + centerSpacing;
        const rcX: i32 = mcX + wsBarGroupW + centerSpacing;

        // ═══ WORKSPACE STATE ═══
        var occupiedBuf: [16]bool = .{false} ** 16;
        var activeWs: usize = 0;
        const wsDisplayCount = @min(wsCount, ctx.workspace_count);
        for (0..wsDisplayCount) |wi| {
            const wsInfo = &ctx.workspaces[wi];
            occupiedBuf[wi] = wsInfo.name_len > 0;
            if (wsInfo.active) activeWs = wi;
        }
        if (wsDisplayCount == 0) {
            occupiedBuf[0] = true;
            occupiedBuf[1] = true;
            occupiedBuf[2] = true;
            activeWs = 0;
        }
        const occupied = occupiedBuf;

        // ═══ ACTIVE WINDOW TEXT (pre-compute for layout) ═══
        const appName: []const u8 = if (ctx.active_toplevel) |at|
            std.mem.sliceTo(&ctx.toplevels[at].app_id, 0)
        else
            "mist";
        const windowTitle: []const u8 = if (ctx.active_toplevel) |at|
            std.mem.sliceTo(&ctx.toplevels[at].title, 0)
        else
            "Mist DE";

        // ═══ 1. BAR BACKGROUND ═══
        // end-4 hug mode: full-width rect with NO radius (radius: 0 in QML)
        canvas.fillRect(0, 0, bar_w, bar_h, colLayer0);

        // ═══ 2. LEFT SECTION: Sidebar button + Active window ═══
        // end-4: LeftSidebarButton is transparent by default, only shows colLayer1Hover on hover
        // Since we can't do hover, draw just the icon without background
        const sidebarBtnW: i32 = 30;
        const sidebarBtnX: i32 = screenRounding;

        // sidebar icon (19.5px, centered in button area)
        if (self.font_icon) |*fIcon| {
            const tbl = @divTrunc(bar_h - fIcon.lineHeight(), 2) + fIcon.baselineOffset();
            render_mod.renderText(&canvas, fIcon, "\u{F313}", sidebarBtnX + @divTrunc(sidebarBtnW - 19, 2), tbl, colOnLayer0);
        } else {
            canvas.fillCircle(sidebarBtnX + @divTrunc(sidebarBtnW, 2), centerY, 10, colOnLayer0);
        }

        // Active window text (10px left margin from button)
        const awX: i32 = sidebarBtnX + sidebarBtnW + 10;
        if (useShortenedForm == 0) {
            if (self.font) |*f| {
                const groupH: i32 = 12 + 15 - 4;
                const groupTop: i32 = @divTrunc(bar_h - groupH, 2);
                const row1Y: i32 = groupTop + 12;
                const row2Y: i32 = row1Y - 4 + 15;
                render_mod.renderText(&canvas, f, appName, awX, row1Y, colSubtext);
                render_mod.renderText(&canvas, f, windowTitle, awX, row2Y, colOnLayer0);
            }
        }

        // ═══ 3. CENTER: 3 BarGroups (with vertical separators) ═══

        // ─── 3a. Left center: Resources + Media ───
        canvas.fillRoundedRectAA(lcX, groupBgY, centerSideModuleWidth, groupBgH, smallRounding, colLayer1);

        var resX: i32 = lcX + groupPadding + 4; // 4px left margin (end-4 Resources RowLayout)
        const resIcons = [_][]const u8{ "memory", "swap_horiz", "planner_review" };
        const half_pi: f32 = @as(f32, std.math.pi) / 2.0;
        const two_pi: f32 = 2.0 * @as(f32, std.math.pi);
        for (resIcons, 0..) |icon, ri| {
            const ringR: i32 = 10;
            const ringCX: i32 = resX + ringR;
            // Track: filled circle at 50% alpha (end-4 transparentize colPrimary, 0.5)
            canvas.fillCircle(ringCX, centerY, ringR, Color.rgba(0xec, 0xe6, 0xe9, 0x80));
            // Progress: filled sector from center, clockwise from top (end-4 ClippedFilledCircularProgress)
            canvas.fillArc(ringCX, centerY, 0, ringR, half_pi, -two_pi * 0.52, colOnSecondaryContainer);

            // Icon centered in 20x20 ring at 16px (end-4 MaterialSymbol normal)
            if (self.font_material) |*fMat| {
                const tbl = @divTrunc(bar_h - fMat.lineHeight(), 2) + fMat.baselineOffset();
                render_mod.renderText(&canvas, fMat, icon, ringCX - 8, tbl, colOnSecondaryContainer);
            }

            // Percentage text at 15px (end-4 StyledText small)
            if (self.font) |*f| {
                const tbl2 = @divTrunc(bar_h - f.lineHeight(), 2) + f.baselineOffset();
                const pctStr = "52";
                render_mod.renderText(&canvas, f, pctStr, ringCX + ringR + 2, tbl2, colOnLayer1);
            }
            // Gap between resources: 6px spacing + ring(20) + icon(16) + text(approx 16)
            resX += 44;
            _ = ri;
        }

        // Optional media widget when module is wide enough (end-4 Media.qml)
        if (centerSideModuleWidth > 200) {
            resX += 6;
            const mediaRingCX: i32 = resX + 10;
            const mediaProgress: f32 = 0.42; // placeholder: 42% progress
            canvas.fillCircle(mediaRingCX, centerY, 10, Color.rgba(0xec, 0xe6, 0xe9, 0x80));
            canvas.fillArc(mediaRingCX, centerY, 0, 10, half_pi, -two_pi * mediaProgress, colOnSecondaryContainer);

            if (self.font_material) |*fMat| {
                const tbl = @divTrunc(bar_h - fMat.lineHeight(), 2) + fMat.baselineOffset();
                render_mod.renderText(&canvas, fMat, "music_note", mediaRingCX - 7, tbl, colOnSecondaryContainer);
            }

            resX += 36;
            const mediaTextW: i32 = lcX + centerSideModuleWidth - resX - groupPadding;
            if (mediaTextW > 10 and self.font != null) {
                const tbl = @divTrunc(bar_h - self.font.?.lineHeight(), 2) + self.font.?.baselineOffset();
                render_mod.renderText(&canvas, &self.font.?, "Song Title", resX, tbl, colOnLayer1);
            }
        }

        // ─── 3b. Middle center: Workspaces (end-4 exact) ───
        canvas.fillRoundedRectAA(mcX, groupBgY, wsBarGroupW, groupBgH, smallRounding, colLayer1);

        const wsY: i32 = centerY - @divTrunc(wsBtnWidth, 2);
        const wsCellX: i32 = mcX + wsBarGroupPadding;

        // 3b-i. Occupied workspace background circles (end-4 connected corners)
        // When adjacent workspaces are occupied, shared corner radius = 0 (merged shape)
        // end-4: active ws with no activated window skips occupied bg entirely
        const hasActiveWindow: bool = ctx.active_toplevel != null;
        for (0..wsCount) |i| {
            if (!occupied[i]) continue;
            // end-4: skip active ws occupied bg when no active windows
            if (i == activeWs and !hasActiveWindow) continue;
            const occX: i32 = wsCellX + @as(i32, @intCast(i)) * wsBtnWidth;

            // Compute corner radii based on adjacent occupancy (end-4 logic)
            // Adjacent ws connects only if its own occupied bg is also visible
            const prevVisible: bool = if (i > 0) (occupied[i - 1] and !(i - 1 == activeWs and !hasActiveWindow)) else false;
            const nextVisible: bool = if (i + 1 < wsCount) (occupied[i + 1] and !(i + 1 == activeWs and !hasActiveWindow)) else false;
            const r: i32 = wsBtnWidth;
            const tl: i32 = if (prevVisible) 0 else r;
            const tr: i32 = if (nextVisible) 0 else r;
            const bl: i32 = if (prevVisible) 0 else r;
            const br: i32 = if (nextVisible) 0 else r;

            canvas.fillRoundedRectCorners(occX, wsY, wsBtnWidth, wsBtnWidth, tl, tr, bl, br, colSecondaryContainer);
        }

        // 3b-ii. Active workspace indicator (z-index: middle)
        const activeW: i32 = wsBtnWidth - wsActiveMargin * 2;
        const activeX: i32 = wsCellX + @as(i32, @intCast(activeWs)) * wsBtnWidth + wsActiveMargin;
        const activeY: i32 = wsY + wsActiveMargin;
        canvas.fillRoundedRectAA(activeX, activeY, activeW, activeW, fullRounding, colPrimary);

        // 3b-iii. Workspace button content (z-index: front)
        // end-4: showNumbers=false by default, show dots (workspaceButtonWidth * 0.18 ≈ 5px)
        for (0..wsCount) |i| {
            const btnX: i32 = wsCellX + @as(i32, @intCast(i)) * wsBtnWidth;
            const isActive: bool = i == activeWs;
            const isOcc: bool = occupied[i];

            const textColor: Color = if (isActive)
                colOnPrimary
            else if (isOcc)
                colOnSecondaryContainer
            else
                colOnLayer1Inactive;

            // Dot: workspaceButtonWidth * 0.18 ≈ 4.68px diameter (end-4 exact), SDF circle
            const dotDiam: i32 = @intFromFloat(@as(f32, @floatFromInt(wsBtnWidth)) * 0.18 + 0.5);
            const dotCX: i32 = btnX + @divTrunc(wsBtnWidth, 2);
            const dotR: i32 = dotDiam / 2;
            canvas.fillCircle(dotCX, centerY, dotR, textColor);
        }

        // ─── 3c. Right center: Clock + Battery ───
        canvas.fillRoundedRectAA(rcX, groupBgY, centerSideModuleWidth, groupBgH, smallRounding, colLayer1);

        if (self.font) |*f| {
            const tbl = @divTrunc(bar_h - f.lineHeight(), 2) + f.baselineOffset();
            const clockStr = "12:34";
            const sepStr = "\u{2022}";
            const dateStr = "Mon 6 Jul";
            const clockW: i32 = render_mod.textWidth(f, clockStr);
            const sepW: i32 = render_mod.textWidth(f, sepStr);
            const dateW: i32 = render_mod.textWidth(f, dateStr);
            const totalClockW: i32 = clockW + 4 + sepW + 4 + dateW;
            var cx: i32 = rcX + @divTrunc(centerSideModuleWidth - totalClockW, 2);
            render_mod.renderText(&canvas, f, clockStr, cx, tbl, colOnLayer1);
            cx += clockW + 4;
            render_mod.renderText(&canvas, f, sepStr, cx, tbl, colOnLayer1);
            cx += sepW + 4;
            render_mod.renderText(&canvas, f, dateStr, cx, tbl, colOnLayer1);
        }

        // Battery indicator (end-4 ClippedProgressBar)
        const batW: i32 = 30;
        const batH: i32 = 18;
        const batX: i32 = rcX + centerSideModuleWidth - batW - 8;
        const batY: i32 = centerY - @divTrunc(batH, 2);
        // Track: colOnSecondaryContainer at 50% alpha (end-4 transparentize(0.5))
        const batTrack = Color.rgba(0xec, 0xe6, 0xe9, 0x80);
        canvas.fillRoundedRectAA(batX, batY, batW, batH, fullRounding, batTrack);
        // Fill: colOnSecondaryContainer
        const batFillW: i32 = @divTrunc((batW - 4) * 80, 100);
        if (batFillW > 0) {
            canvas.fillRoundedRectAA(batX + 2, batY + 2, batFillW, batH - 4, fullRounding, colOnSecondaryContainer);
        }
        // Text centered: numeric only, no "%" (end-4 ClippedProgressBar text)
        if (self.font) |*f| {
            const tbl = batY + @divTrunc(batH - f.lineHeight(), 2) + f.baselineOffset();
            const batStr = "80";
            const batTW: i32 = render_mod.textWidth(f, batStr);
            render_mod.renderText(&canvas, f, batStr, batX + @divTrunc(batW - batTW, 2), tbl, colOnLayer1);
        }

        // ═══ 4. RIGHT SECTION: Indicators (RTL, end-4 BarContent) ═══
        // end-4 order (right-to-left inside RippleButton, visible in RTL):
        //   bt → wifi → notif → xkb → mic_off → volume_off
        //   (rightmost to leftmost)
        // Plus: SysTray (left of indicators), Weather (left of systray)
        // Transparent by default, shows colLayer1Hover on hover (not implemented)
        const indicatorSpacing: i32 = 15;

        // end-4: RippleButton has 10px horizontal padding around indicators
        // bt right edge = content right edge (no margin to button padding)
        var rx: i32 = bar_w - screenRounding - 10;
        if (self.font_material) |*fMat| {
            const tbl = @divTrunc(bar_h - fMat.lineHeight(), 2) + fMat.baselineOffset();

            // RTL draw order: rightmost → leftmost

            // 1. bluetooth (end-4: rightmost, Layout.leftMargin:15 → spacing before bt)
            {
                const item = "bluetooth_connected";
                const iw = render_mod.textWidth(fMat, item);
                rx -= iw;
                render_mod.renderText(&canvas, fMat, item, rx, tbl, colOnLayer0);
            }
            rx -= indicatorSpacing;

            // 2. network_wifi (end-4: always shown)
            {
                const item = "network_wifi";
                const iw = render_mod.textWidth(fMat, item);
                rx -= iw;
                render_mod.renderText(&canvas, fMat, item, rx, tbl, colOnLayer0);
            }
            rx -= indicatorSpacing;

            // 3. notifications (end-4: Revealer, badge dot when unread)
            {
                const item = "notifications";
                const iw = render_mod.textWidth(fMat, item);
                rx -= iw;
                render_mod.renderText(&canvas, fMat, item, rx, tbl, colOnLayer0);
                // badge dot: 8px circle, anchored top-right with (1,3) margins
                const icon_top = tbl - fMat.baselineOffset();
                canvas.fillCircle(rx + iw - 5, icon_top + 7, 4, colOnLayer0);
            }
            rx -= indicatorSpacing;

            // 4. xkb layout abbreviation (end-4: regular StyledText, not MaterialSymbol)
            if (self.font) |*f| {
                const fTbl = @divTrunc(bar_h - f.lineHeight(), 2) + f.baselineOffset();
                const item = "EN";
                const iw = render_mod.textWidth(f, item);
                rx -= iw;
                render_mod.renderText(&canvas, f, item, rx, fTbl, colOnLayer0);
            }
            rx -= indicatorSpacing;

            // 5. mic_off (end-4: Revealer)
            {
                const item = "mic_off";
                const iw = render_mod.textWidth(fMat, item);
                rx -= iw;
                render_mod.renderText(&canvas, fMat, item, rx, tbl, colOnLayer0);
            }
            rx -= indicatorSpacing;

            // 6. volume_off (end-4: leftmost, no margin after — button padding handles it)
            {
                const item = "volume_off";
                const iw = render_mod.textWidth(fMat, item);
                rx -= iw;
                render_mod.renderText(&canvas, fMat, item, rx, tbl, colOnLayer0);
            }
            // NO spacing after last item
        }

        // ═══ 5. COMMIT ═══
        self.layer.surface.attach(buf.buffer, 0, 0);
        self.layer.surface.damageBuffer(0, 0, @intCast(buf.width), @intCast(buf.height));
        self.layer.surface.commit();
        ctx.flush();

        self.needs_full_redraw = false;
    }
};

// ═══════════════════════════════════════════════════════════
// Input dispatch — seat listener, pointer/keyboard, click
// ═══════════════════════════════════════════════════════════

pub fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, ctx: *Context) void {
    switch (event) {
        .name => |name| {
            std.log.info("seat name: {s}", .{name.name});
        },
        .capabilities => |caps| {
            if (ctx.pointer) |p| {
                p.release();
                ctx.pointer = null;
            }
            if (ctx.keyboard) |kb| {
                kb.release();
                ctx.keyboard = null;
            }

            if (caps.capabilities.pointer) {
                const pointer = seat.getPointer() catch @panic("failed to get pointer");
                ctx.pointer = pointer;
                pointer.setListener(*Context, pointerListener, ctx);
            }
            if (caps.capabilities.keyboard) {
                const kb = seat.getKeyboard() catch @panic("failed to get keyboard");
                ctx.keyboard = kb;
                kb.setListener(*Context, keyboardListener, ctx);
            }
        },
    }
}

fn pointerListener(pointer: *wl.Pointer, event: wl.Pointer.Event, ctx: *Context) void {
    _ = pointer;
    switch (event) {
        .enter => |enter| {
            ctx.last_enter_serial = enter.serial;
            ctx.pointer_x = @intFromEnum(enter.surface_x);
            ctx.pointer_y = @intFromEnum(enter.surface_y);
            setCursorShape(ctx, enter.serial, .default);
        },
        .motion => |motion| {
            ctx.pointer_x = @intFromEnum(motion.surface_x);
            ctx.pointer_y = @intFromEnum(motion.surface_y);
        },
        .button => |btn| {
            if (btn.state == .pressed) {
                handleClick(ctx, ctx.pointer_x, ctx.pointer_y);
            }
        },
        .leave => {
            ctx.pointer_x = 0;
            ctx.pointer_y = 0;
        },
        .axis, .frame, .axis_stop, .axis_value120, .axis_discrete, .axis_source => {},
    }
}

fn keyboardListener(kb: *wl.Keyboard, event: wl.Keyboard.Event, ctx: *Context) void {
    _ = kb;
    _ = ctx;
    switch (event) {
        .key => {},
        .enter, .leave, .keymap, .modifiers, .repeat_info => {},
    }
}

fn handleClick(ctx: *Context, x: i32, y: i32) void {
    const bar_h: i32 = 40;
    const bar_w: i32 = ctx.outputs[0].mode_w;
    const screenRounding: i32 = 23;
    const centerSpacing: i32 = 4;
    const centerModW: i32 = if (bar_w > 1200) 360 else if (bar_w > 1000) 280 else 190;
    const wsBtnWidth: i32 = 26;
    const wsBarGroupPadding: i32 = 4;
    const wsCount: i32 = 5;
    const wsTotalWidth: i32 = wsBtnWidth * wsCount;
    const wsBarGroupW: i32 = wsTotalWidth + wsBarGroupPadding * 2;

    const centerY: i32 = @divTrunc(bar_h, 2);
    const centerTotal: i32 = centerModW + centerSpacing + wsBarGroupW + centerSpacing + centerModW;
    const centerX: i32 = @divTrunc(bar_w - centerTotal, 2);
    const mcX: i32 = centerX + centerModW + centerSpacing;
    const wsCellX: i32 = mcX + wsBarGroupPadding;
    const wsY: i32 = centerY - @divTrunc(wsBtnWidth, 2);

    // Workspace click detection (fixed 26px buttons)
    for (0..@as(usize, @intCast(wsCount))) |i| {
        const btnX: i32 = wsCellX + @as(i32, @intCast(i)) * wsBtnWidth;
        if (y >= wsY and y < wsY + wsBtnWidth and x >= btnX and x < btnX + wsBtnWidth) {
            std.log.info("workspace {d} clicked", .{i});
            if (ctx.active_workspace) |aw| ctx.workspaces[aw].handle.deactivate();
            if (i < ctx.workspace_count) {
                ctx.workspaces[i].handle.activate();
                ctx.active_workspace = i;
            }
            ctx.roundtrip();
            markAllDirty(ctx);
            return;
        }
    }

    const sidebarBtnX: i32 = screenRounding;
    if (x >= sidebarBtnX and x < sidebarBtnX + 30 and y >= 0 and y < bar_h) {
        std.log.info("sidebar button clicked", .{});
        return;
    }

    // Right section indicators (RTL, 6 items, end-4)
    const indicatorItemCount: i32 = 6;
    _ = indicatorItemCount;
    // Rough indicator area: from screenRounding from right edge, ~200px wide
    const indicatorAreaX: i32 = bar_w - screenRounding - 200;
    if (x >= indicatorAreaX and x < bar_w - screenRounding and y >= 0 and y < bar_h) {
        std.log.info("right indicator area clicked", .{});
        return;
    }

    if (ctx.active_toplevel) |at| {
        const awX: i32 = sidebarBtnX + 20 + 10;
        const awRight: i32 = @divTrunc(bar_w, 2) - 80;
        if (x >= awX and x < awRight and y >= 0 and y < bar_h) {
            std.log.info("activating toplevel: {s}", .{std.mem.sliceTo(&ctx.toplevels[at].title, 0)});
            if (ctx.seat) |seat| {
                ctx.toplevels[at].handle.activate(seat);
            }
            ctx.roundtrip();
            return;
        }
    }
}

fn setCursorShape(ctx: *Context, serial: u32, shape: CursorShape) void {
    if (ctx.cursor_shape_manager == null) return;
    if (ctx.last_cursor_shape == shape) return;
    ctx.last_cursor_shape = shape;
    if (ctx.pointer) |ptr| {
        const dev = ctx.cursor_shape_manager.?.getPointer(ptr) catch |err| {
            std.log.warn("cursor shape: {s}", .{@errorName(err)});
            return;
        };
        defer dev.destroy();
        dev.setShape(serial, shape);
    }
}
