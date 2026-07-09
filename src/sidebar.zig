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
const Appearance = config_mod.Appearance;
const notif_mod = @import("notifications.zig");

pub const TodoTask = struct {
    content: [256]u8 = undefined,
    content_len: usize = 0,
    done: bool = false,
};

pub const SIDEBAR_W: i32 = Appearance.sidebar_width;

pub const Sidebar = struct {
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    buffer: ?ShmBuffer = null,
    font: ?Font = null,
    font_small: ?Font = null,
    font_material: ?Font = null,
    font_fallback: ?Font = null,
    visible: bool = false,
    needs_redraw: bool = false,
    needs_full_redraw: bool = true,
    scroll_offset: i32 = 0,
    height: i32 = 0,
    output_idx: usize = 0,
    initialized: bool = false,

    // Animation state
    anim_x: i32 = 0,
    anim_target_x: i32 = 0,
    anim_start_x: i32 = 0,
    anim_start_ms: i64 = 0,
    anim_duration_ms: i64 = 0,
    animating: bool = false,
    anim_pending_frame: bool = false,
    anim_frame_callback: ?*wl.Callback = null,
    pending_height: i32 = 0,
    screen_h: i32 = 0,

    // BottomWidgetGroup state
    bottom_collapsed: bool = false,
    selected_tab: u2 = 0, // 0=calendar, 1=todo, 2=timer
    surface_created: bool = false,

    // Calendar navigation state
    cal_month_offset: i32 = 0, // months offset from current (0=this month, -1=last month, etc.)

    // Todo state
    todo_items: [128]TodoTask = undefined,
    todo_count: usize = 0,
    todo_showing_done: bool = false,
    todo_scroll: i32 = 0,
    todo_show_add: bool = false,
    todo_input_buf: [256]u8 = undefined,
    todo_input_len: usize = 0,
    todo_input_active: bool = false,

    pub fn init(self: *Sidebar, _: *Context, output_idx: usize, allocator: std.mem.Allocator) !void {
        if (self.initialized) return;
        self.output_idx = output_idx;

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

    fn nowMs() i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
    }

    fn layerSurfaceListener(ls: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, sidebar: *Sidebar) void {
        switch (event) {
            .configure => |ev| {
                ls.ackConfigure(ev.serial);
                sidebar.pending_height = @as(i32, @intCast(ev.height));
            },
            .closed => {},
        }
    }

    fn frameCallbackListener(_: *wl.Callback, _: wl.Callback.Event, sidebar: *Sidebar) void {
        sidebar.anim_pending_frame = false;
    }

    fn ensureSurface(self: *Sidebar, ctx: *Context) bool {
        if (self.surface_created) return true;

        const compositor = ctx.compositor orelse return false;
        const layer_shell = ctx.layer_shell orelse return false;
        const output_wl = ctx.outputs[self.output_idx].output;

        const wl_surface = compositor.createSurface() catch return false;

        const ls = layer_shell.getLayerSurface(wl_surface, output_wl, .top, "mist-sidebar") catch {
            wl_surface.destroy();
            return false;
        };

        self.surface = wl_surface;
        self.layer_surface = ls;
        self.surface_created = true;

        const output = &ctx.outputs[self.output_idx];
        self.screen_h = if (output.mode_h > 0) output.mode_h else 768;
        self.height = if (self.pending_height > 0) self.pending_height else self.screen_h;

        ls.setAnchor(.{ .top = true, .right = true, .bottom = true });
        ls.setSize(@as(u32, @intCast(SIDEBAR_W)), 0);
        ls.setKeyboardInteractivity(.exclusive);
        ls.setExclusiveZone(0);
        ls.setListener(*Sidebar, layerSurfaceListener, self);

        // Surface is placed off-screen via negative right margin.
        // anim_x tracks the margin distance from the edge:
        //   0 = fully visible (margin_right = 0)
        //   SIDEBAR_W = fully hidden (margin_right = -SIDEBAR_W)
        self.anim_x = SIDEBAR_W;
        self.anim_target_x = SIDEBAR_W;
        ls.setMargin(0, -SIDEBAR_W, 0, 0);

        // First commit (no buffer) triggers configure event
        wl_surface.commit();
        ctx.flush();
        ctx.roundtrip();
        // Now layer surface is configured — update height from configure event
        if (self.pending_height > 0) {
            self.height = self.pending_height;
        } else {
            self.height = self.screen_h;
        }

        // Create buffer (deinit old one if re-creating after destroy)
        const shm = ctx.shm orelse return false;
        if (self.buffer) |*old| old.deinit();
        self.buffer = ShmBuffer.create(shm, SIDEBAR_W, self.height) catch return false;

        return true;
    }

    fn destroySurfaces(self: *Sidebar) void {
        if (self.anim_frame_callback) |cb| {
            cb.destroy();
            self.anim_frame_callback = null;
        }
        self.anim_pending_frame = false;
        if (self.layer_surface) |ls| {
            ls.destroy();
            self.layer_surface = null;
        }
        if (self.surface) |s| {
            s.destroy();
            self.surface = null;
        }
        if (self.buffer) |*b| b.deinit();
        self.buffer = null;
        self.surface_created = false;
    }

    fn setEmptyInputRegion(self: *Sidebar, ctx: *Context) void {
        if (self.surface) |s| {
            if (ctx.compositor) |comp| {
                const region = comp.createRegion() catch return;
                s.setInputRegion(region);
                region.destroy();
            }
        }
    }

    fn setFullInputRegion(self: *Sidebar, ctx: *Context) void {
        if (self.surface) |s| {
            if (ctx.compositor) |comp| {
                const region = comp.createRegion() catch return;
                region.add(0, 0, SIDEBAR_W, self.height);
                s.setInputRegion(region);
                region.destroy();
            }
        }
    }

    pub fn show(self: *Sidebar, ctx: *Context) void {
        if (!self.initialized or self.visible) return;
        if (!self.ensureSurface(ctx)) return;

        self.visible = true;
        ctx.notifications.timeoutAllPopups();

        // Cancel any stale frame callback
        if (self.anim_frame_callback) |cb| {
            cb.destroy();
            self.anim_frame_callback = null;
        }
        self.anim_pending_frame = false;

        // Only redraw if buffer hasn't been rendered yet
        self.scroll_offset = 0;
        if (self.buffer != null and !self.needs_full_redraw and !self.needs_redraw) {
            // Buffer has valid content — skip expensive MSAA draw
        } else {
            self.needs_full_redraw = true;
            self.draw(ctx);
        }

        // Start slide-in: margin -SIDEBAR_W → 0 (200ms ease-out cubic)
        self.anim_x = SIDEBAR_W;
        self.anim_start_x = SIDEBAR_W;
        self.anim_target_x = 0;
        self.anim_start_ms = nowMs();
        self.anim_duration_ms = 200;
        self.animating = true;

        // First frame: margin off-screen (hidden), attach buffer, commit
        const ls = self.layer_surface orelse return;
        const buf = self.buffer orelse return;
        const s = self.surface orelse return;
        ls.setKeyboardInteractivity(.exclusive);
        ls.setMargin(0, -SIDEBAR_W, 0, 0);
        s.attach(buf.buffer, 0, 0);
        s.damageBuffer(0, 0, buf.width, buf.height);
        s.commit();

        self.setFullInputRegion(ctx);
        s.commit();
    }

    pub fn hide(self: *Sidebar, ctx: *Context) void {
        if (!self.visible) return;

        // Cancel any stale frame callback
        if (self.anim_frame_callback) |cb| {
            cb.destroy();
            self.anim_frame_callback = null;
        }
        self.anim_pending_frame = false;

        // Start slide-out from current margin → -SIDEBAR_W (200ms ease-out cubic)
        const current_x = if (self.animating) self.anim_x else 0;
        self.anim_x = current_x;
        self.anim_start_x = current_x;
        self.anim_target_x = SIDEBAR_W;
        self.anim_start_ms = nowMs();
        self.anim_duration_ms = 200;
        self.animating = true;

        self.setEmptyInputRegion(ctx);
        if (self.surface) |s| s.commit();
    }

    pub fn animate(self: *Sidebar, ctx: *Context) void {
        if (!self.animating) return;
        // Wait for compositor to finish rendering the previous frame
        if (self.anim_pending_frame) return;

        const buf = self.buffer orelse return;
        const s = self.surface orelse return;
        const ls = self.layer_surface orelse return;

        const elapsed = nowMs() - self.anim_start_ms;
        const t = if (self.anim_duration_ms <= 0) 1.0 else
            @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.anim_duration_ms)));

        // ease-out cubic: 1 - (1-t)^3
        const inv = 1.0 - t;
        const eased = 1.0 - inv * inv * inv;

        const start_f: f32 = @floatFromInt(self.anim_start_x);
        const target_f: f32 = @floatFromInt(self.anim_target_x);
        const new_x: i32 = @intFromFloat(start_f + (target_f - start_f) * eased);

        // Only commit if margin actually changed
        if (new_x != self.anim_x) {
            self.anim_x = new_x;

            // Clean up old callback
            if (self.anim_frame_callback) |cb| {
                cb.destroy();
                self.anim_frame_callback = null;
            }

            // Slide via layer shell margin (negative right = off-screen right)
            ls.setMargin(0, -new_x, 0, 0);
            s.damageBuffer(0, 0, buf.width, buf.height);
            if (s.frame()) |cb| {
                cb.setListener(*Sidebar, frameCallbackListener, self);
                self.anim_frame_callback = cb;
                self.anim_pending_frame = true;
            } else |_| {
                self.anim_pending_frame = false;
            }
            s.commit();
        }

        if (t >= 1.0) {
            self.animating = false;
            self.anim_pending_frame = false;
            self.anim_x = self.anim_target_x;

            // Clean up last callback
            if (self.anim_frame_callback) |cb| {
                cb.destroy();
                self.anim_frame_callback = null;
            }

            if (self.anim_target_x == SIDEBAR_W) {
                // Slide-out complete — keep surfaces alive to avoid re-allocation
                self.visible = false;
            } else {
                // Slide-in complete — ensure margin is 0 (visible)
                ls.setMargin(0, 0, 0, 0);
                s.damageBuffer(0, 0, buf.width, buf.height);
                s.commit();
                self.setFullInputRegion(ctx);
            }
        }
    }

    pub fn toggle(self: *Sidebar, ctx: *Context) void {
        if (self.visible) self.hide(ctx) else self.show(ctx);
    }

    pub fn markDirty(self: *Sidebar) void {
        self.needs_redraw = true;
    }

    pub fn draw(self: *Sidebar, ctx: *Context) void {
        if (!self.visible) return;
        const buf = self.buffer orelse return;
        if (!self.needs_full_redraw and !self.needs_redraw) return;
        self.needs_redraw = false;
        self.needs_full_redraw = false;

        var canvas = Canvas{
            .data = buf.data,
            .width = buf.width,
            .height = buf.height,
            .stride = buf.stride,
        };

        canvas.fill(Color.transparent);

        // end-4 M3 dark theme colors
        const colBg = Appearance.col_layer0;
        const colBgBorder = Appearance.col_layer0_border;
        const colLayer1 = Appearance.col_layer1;
        const colLayer2 = Appearance.col_layer2;
        const colOnLayer0 = Appearance.col_on_layer0;
        const colOnLayer1 = Appearance.col_on_layer1;
        const colOnLayer1Inactive = Appearance.col_on_layer1_inactive;
        const colOnLayer2 = Appearance.col_on_layer2;
        const colOutline = Appearance.col_outline;
        const colPrimary = Appearance.col_primary;
        const colOnPrimary = Appearance.col_on_primary;
        const colSecContainer = Appearance.col_secondary_container;
        const colOnSecContainer = Appearance.col_on_secondary_container;
        const colError = Appearance.col_error;
        const colPrimaryContainer = Appearance.col_primary_container;
        const colOnPrimaryContainer = Appearance.col_on_primary_container;
        const colOutlineVariant = Appearance.col_outline_variant;

        const M = Appearance.sidebar_margin;

        // Background rectangle (with border and radius)
        const E = Appearance.sidebar_elevation;
        const P = Appearance.sidebar_padding;
        const bg_x = E;
        const bg_y = M;
        const bg_w = SIDEBAR_W - M - E;
        const bg_h = self.height - 2 * M;
        const bg_r = Appearance.sidebar_bg_radius;

        // Border (1px outline)
        canvas.fillRoundedRectMSAA(bg_x, bg_y, bg_w, bg_h, bg_r, colBgBorder);
        // Fill inside border
        canvas.fillRoundedRectMSAA(bg_x + 1, bg_y + 1, bg_w - 2, bg_h - 2, bg_r - 1, colBg);

        // Layout: ColumnLayout inside background, 10px padding, 10px spacing
        const inner_x = bg_x + P;
        const inner_y = bg_y + P;
        const inner_w = bg_w - P * 2;
        var cur_y: i32 = inner_y;

        // Section 1: SystemButtonRow
        const sys_row_h: i32 = 40;
        const pill_h = sys_row_h;
        const pill_r = @divTrunc(pill_h, 2);
        canvas.fillRoundedRectMSAA(inner_x, cur_y, inner_w, pill_h, pill_r, colLayer1);

        if (self.font_material) |*fMat| {
            const icon_y = cur_y + @divTrunc(pill_h - fMat.lineHeight(), 2) + fMat.baselineOffset();
            const cp = config_mod.detectDistroIcon();
            var icon_utf8: [4]u8 = undefined;
            const icon_utf8_len = std.unicode.utf8Encode(cp, &icon_utf8) catch 3;
            const icon = icon_utf8[0..icon_utf8_len];
            render_mod.renderText(&canvas, fMat, icon, inner_x + 12, icon_y, colOnLayer0);

            if (self.font) |*f| {
                const text_y = cur_y + @divTrunc(pill_h - f.lineHeight(), 2) + f.baselineOffset();
                render_mod.renderText(&canvas, f, "Up 3h 42m", inner_x + 40, text_y, colOnLayer0);
            }
        }

        // Right action buttons (edit, restart, settings, power) — end-4 order
        const btn_size: i32 = 30;
        const btn_pad: i32 = 4;
        var btn_x = inner_x + inner_w - btn_pad - btn_size;
        const btn_y = cur_y + @divTrunc(sys_row_h - btn_size, 2);

        // power_settings_new
        canvas.fillCircle(btn_x + @divTrunc(btn_size, 2), btn_y + @divTrunc(btn_size, 2), @divTrunc(btn_size, 2), colLayer2);
        if (self.font_material) |*fMat| {
            const icon_y = btn_y + @divTrunc(btn_size - fMat.lineHeight(), 2) + fMat.baselineOffset();
            render_mod.renderText(&canvas, fMat, "power_settings_new", btn_x + 4, icon_y, colOnLayer1);
        }
        btn_x -= btn_size + btn_pad;

        // settings
        canvas.fillCircle(btn_x + @divTrunc(btn_size, 2), btn_y + @divTrunc(btn_size, 2), @divTrunc(btn_size, 2), colLayer2);
        if (self.font_material) |*fMat| {
            const icon_y = btn_y + @divTrunc(btn_size - fMat.lineHeight(), 2) + fMat.baselineOffset();
            render_mod.renderText(&canvas, fMat, "settings", btn_x + 4, icon_y, colOnLayer1);
        }
        btn_x -= btn_size + btn_pad;

        // restart_alt
        canvas.fillCircle(btn_x + @divTrunc(btn_size, 2), btn_y + @divTrunc(btn_size, 2), @divTrunc(btn_size, 2), colLayer2);
        if (self.font_material) |*fMat| {
            const icon_y = btn_y + @divTrunc(btn_size - fMat.lineHeight(), 2) + fMat.baselineOffset();
            render_mod.renderText(&canvas, fMat, "restart_alt", btn_x + 4, icon_y, colOnLayer1);
        }
        btn_x -= btn_size + btn_pad;

        // edit
        canvas.fillCircle(btn_x + @divTrunc(btn_size, 2), btn_y + @divTrunc(btn_size, 2), @divTrunc(btn_size, 2), colLayer2);
        if (self.font_material) |*fMat| {
            const icon_y = btn_y + @divTrunc(btn_size - fMat.lineHeight(), 2) + fMat.baselineOffset();
            render_mod.renderText(&canvas, fMat, "edit", btn_x + 4, icon_y, colOnLayer1);
        }

        cur_y += sys_row_h + 10;

        // Section 2: QuickSliders (volume + mic in ONE container)
        // end-4: single colLayer1 rect with verticalPadding=4, horizontalPadding=12
        // Each slider fills width, stacked vertically
        const sliders_v_pad: i32 = 4;
        const sliders_h_pad: i32 = 12;
        const single_slider_h: i32 = 30; // track height
        const sliders_total_h = sliders_v_pad + single_slider_h + 4 + single_slider_h + sliders_v_pad; // 2 sliders with 4px gap
        canvas.fillRoundedRectMSAA(inner_x, cur_y, inner_w, sliders_total_h, Appearance.sidebar_widget_radius, colLayer1);

        const slider_icon_pad: i32 = sliders_h_pad;
        const slider_track_h: i32 = single_slider_h;
        const slider_track_x = inner_x + sliders_h_pad + 28; // icon + gap
        const slider_track_w = inner_w - sliders_h_pad * 2 - 28;

        // Volume slider
        {
            const sy = cur_y + sliders_v_pad;
            if (self.font_material) |*fMat| {
                const icon_y = sy + @divTrunc(slider_track_h - fMat.lineHeight(), 2) + fMat.baselineOffset();
                render_mod.renderText(&canvas, fMat, "volume_up", inner_x + slider_icon_pad, icon_y, colOnLayer1);
            }
            canvas.fillRoundedRectMSAA(slider_track_x, sy + @divTrunc(slider_track_h - 6, 2), slider_track_w, 6, 3, colSecContainer);
            const vol_pct: f32 = ctx.resources.audio_volume;
            const fill_w: i32 = @intFromFloat(@as(f32, @floatFromInt(slider_track_w)) * vol_pct);
            if (fill_w > 0) {
                canvas.fillRoundedRectMSAA(slider_track_x, sy + @divTrunc(slider_track_h - 6, 2), fill_w, 6, 3, colOnSecContainer);
                canvas.fillCircle(slider_track_x + fill_w, sy + @divTrunc(slider_track_h, 2), 8.0, colPrimary);
            }
        }

        // Mic slider
        {
            const sy = cur_y + sliders_v_pad + single_slider_h + 4;
            if (self.font_material) |*fMat| {
                const icon_y = sy + @divTrunc(slider_track_h - fMat.lineHeight(), 2) + fMat.baselineOffset();
                const mic_icon = if (ctx.resources.mic_muted or ctx.resources.mic_volume < 0.01) "mic_off" else "mic";
                render_mod.renderText(&canvas, fMat, mic_icon, inner_x + slider_icon_pad, icon_y, colOnLayer1);
            }
            canvas.fillRoundedRectMSAA(slider_track_x, sy + @divTrunc(slider_track_h - 6, 2), slider_track_w, 6, 3, colSecContainer);
            const mic_pct: f32 = ctx.resources.mic_volume;
            const mic_fill_w: i32 = @intFromFloat(@as(f32, @floatFromInt(slider_track_w)) * mic_pct);
            if (mic_fill_w > 0) {
                canvas.fillRoundedRectMSAA(slider_track_x, sy + @divTrunc(slider_track_h - 6, 2), mic_fill_w, 6, 3, colOnSecContainer);
                canvas.fillCircle(slider_track_x + mic_fill_w, sy + @divTrunc(slider_track_h, 2), 8.0, colPrimary);
            }
        }

        cur_y += sliders_total_h + 10;

        // Section 3: QuickToggles (classic style: transparent bg, ButtonGroup with colLayer1)
        // end-4: spacing 5, padding 5, radius 19
        const toggle_h: i32 = 50;
        canvas.fillRoundedRectMSAA(inner_x, cur_y, inner_w, toggle_h, Appearance.sidebar_widget_radius, colLayer1);

        const toggle_btn_size: i32 = 36;
        const toggle_spacing: i32 = 5;
        const toggle_icons = [_][]const u8{ "network_wifi", "bluetooth_connected", "dark_mode", "sports_esports", "block", "graphic_eq", "vpn_lock" };
        const toggle_count: i32 = @intCast(toggle_icons.len);
        const total_toggles_w = toggle_count * toggle_btn_size + (toggle_count - 1) * toggle_spacing;
        var toggle_x = inner_x + @divTrunc(inner_w - total_toggles_w, 2);

        for (toggle_icons) |icon| {
            const btn_cx = toggle_x + @divTrunc(toggle_btn_size, 2);
            const btn_cy = cur_y + @divTrunc(toggle_h, 2);
            canvas.fillCircle(btn_cx, btn_cy, @divTrunc(toggle_btn_size, 2), colLayer2);
            if (self.font_material) |*fMat| {
                const icon_y = btn_cy - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                const icon_w = render_mod.textWidth(fMat, icon);
                render_mod.renderText(&canvas, fMat, icon, btn_cx - @divTrunc(icon_w, 2), icon_y, colOnLayer1);
            }
            toggle_x += toggle_btn_size + toggle_spacing;
        }

        cur_y += toggle_h + 10;

        // Section 4: CenterWidgetGroup (notifications)
        const bottom_h: i32 = if (self.bottom_collapsed) 50 else 350;
        const bottom_y = self.height - M - P - bottom_h;
        const notif_h = @max(0, bottom_y - cur_y);
        const notif_y = cur_y;

        if (notif_h > 0) {
            canvas.fillRoundedRectMSAA(inner_x, notif_y, inner_w, notif_h, Appearance.sidebar_widget_radius, colLayer1);

            const notif = ctx.notifications;
            const notif_count = notif.list_len;
            const notif_inner_pad: i32 = 5;
            const notif_content_y = notif_y + notif_inner_pad;
            const notif_content_h = notif_h - notif_inner_pad * 2;

            if (notif_count == 0) {
                // Improved empty state: centered bell icon with proper contrast
                const empty_icon_y = notif_content_y + @divTrunc(notif_content_h - 80, 2);
                const empty_icon_size: i32 = 60;
                if (self.font_material) |*fMat| {
                    const icon_w = render_mod.textWidth(fMat, "notifications_active");
                    // Use colOnLayer1 (lighter) for better contrast
                    render_mod.renderText(&canvas, fMat, "notifications_active", inner_x + @divTrunc(inner_w - icon_w, 2), empty_icon_y + @divTrunc(empty_icon_size - fMat.lineHeight(), 2) + fMat.baselineOffset(), colOnLayer1);
                }
                if (self.font) |*f| {
                    const text = "Nothing yet";
                    const text_w = render_mod.textWidth(f, text);
                    render_mod.renderText(&canvas, f, text, inner_x + @divTrunc(inner_w - text_w, 2), empty_icon_y + empty_icon_size + 15 + f.baselineOffset(), colOnLayer1Inactive);
                }
            } else {
                const card_h: i32 = 80;
                const card_gap: i32 = 3;
                const group_gap: i32 = 6;
                const header_h: i32 = 22;
                const card_w = inner_w - notif_inner_pad * 2;
                const card_x = inner_x + notif_inner_pad;

                // Get current timestamp for relative times
                var ts: std.os.linux.timespec = undefined;
                _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
                const now_ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);

                // Build app groups (newest → oldest order)
                const max_groups = 16;
                var group_app: [max_groups][]const u8 = undefined;
                var group_count: [max_groups]usize = undefined;
                var group_len: usize = 0;

                for (0..notif_count) |i| {
                    const ni = notif_count - 1 - i;
                    const a = notif.list[ni].app_name[0..notif.list[ni].app_name_len];
                    var found = false;
                    for (0..group_len) |g| {
                        if (group_len > 0 and std.mem.eql(u8, a, group_app[g])) {
                            group_count[g] += 1;
                            found = true;
                            break;
                        }
                    }
                    if (!found and group_len < max_groups) {
                        group_app[group_len] = a;
                        group_count[group_len] = 1;
                        group_len += 1;
                    }
                }

                var card_y: i32 = notif_content_y;
                var drawn: usize = 0;
                var g: usize = 0;
                while (g < group_len and (card_y - notif_content_y) < notif_content_h) {
                    if (drawn > 0) {
                        card_y += group_gap;
                        if (card_y - notif_content_y > notif_content_h) break;
                    }

                    // Draw group header
                    const header_text = if (group_app[g].len > 0) group_app[g] else "Unknown";
                    const header_fg = colOutline;
                    const header_y = card_y;
                    canvas.fillRoundedRectMSAA(card_x, header_y, card_w, header_h, @divTrunc(header_h, 2), colLayer2);
                    if (self.font_small) |*f| {
                        header_text: {
                            const hw = render_mod.textWidth(f, header_text);
                            const full_w = card_w - 20;
                            const display = if (hw > full_w) blk: {
                                var lo: usize = 0;
                                var hi: usize = header_text.len;
                                while (lo < hi) {
                                    const mid = (lo + hi + 1) / 2;
                                    if (render_mod.textWidth(f, header_text[0..mid]) <= full_w - 12) lo = mid else hi = mid - 1;
                                }
                                if (lo == 0) break :header_text;
                                var hbuf: [64]u8 = undefined;
                                @memcpy(hbuf[0..lo], header_text[0..lo]);
                                hbuf[lo] = '.'; hbuf[lo + 1] = '.'; hbuf[lo + 2] = '.';
                                break :blk hbuf[0 .. lo + 3];
                            } else header_text;
                            render_mod.renderText(&canvas, f, display, card_x + 10, header_y + @divTrunc(header_h - f.lineHeight(), 2) + f.baselineOffset(), header_fg);
                        }
                    }
                    card_y += header_h + card_gap;

                    // Draw notifications for this group
                    for (0..notif_count) |i| {
                        if ((card_y - notif_content_y) + card_h > notif_content_h) break;
                        const ni = notif_count - 1 - i;
                        const n = &notif.list[ni];
                        const a = n.app_name[0..n.app_name_len];
                        if (!std.mem.eql(u8, a, group_app[g])) continue;

                        const draw_y = card_y - self.scroll_offset;

                        if (draw_y + card_h > notif_content_y and draw_y < notif_content_y + notif_content_h) {
                            // Urgency left border
                            if (n.urgency == 2) {
                                canvas.fillRoundedRectMSAA(card_x, draw_y, 3, card_h, 1, colError);
                            }

                            canvas.fillRoundedRectMSAA(card_x + 3, draw_y, card_w - 3, card_h, Appearance.sidebar_small_radius, colLayer2);

                            const card_pad: i32 = 10;

                            // App name + time row
                            if (self.font_small) |*f| {
                                const app_str: []const u8 = n.app_name[0..n.app_name_len];
                                var time_buf: [16]u8 = undefined;
                                const rel_time = notif_mod.formatRelativeTime(n.timestamp_ms, now_ms, &time_buf);

                                if (app_str.len > 0) {
                                    const max_app_w = card_w - card_pad * 2 - 50;
                                    var abuf: [64]u8 = undefined;
                                    const display = if (render_mod.textWidth(f, app_str) > max_app_w) blk: {
                                        var lo: usize = 0;
                                        var hi: usize = app_str.len;
                                        while (lo < hi) {
                                            const mid = (lo + hi + 1) / 2;
                                            if (render_mod.textWidth(f, app_str[0..mid]) <= max_app_w - 12) lo = mid else hi = mid - 1;
                                        }
                                        if (lo == 0) break :blk "";
                                        @memcpy(abuf[0..lo], app_str[0..lo]);
                                        abuf[lo] = '.'; abuf[lo + 1] = '.'; abuf[lo + 2] = '.';
                                        break :blk abuf[0 .. lo + 3];
                                    } else app_str;
                                    render_mod.renderText(&canvas, f, display, card_x + card_pad + 3, draw_y + 12 + f.baselineOffset(), colOutline);
                                }

                                // Time on right
                                if (rel_time.len > 0) {
                                    const tw = render_mod.textWidth(f, rel_time);
                                    render_mod.renderText(&canvas, f, rel_time, card_x + card_w - card_pad - tw - 3, draw_y + 12 + f.baselineOffset(), colOnLayer1Inactive);
                                }
                            }

                            // Summary
                            if (self.font) |*f| {
                                const sum_str: []const u8 = n.summary[0..n.summary_len];
                                if (sum_str.len > 0) {
                                    const max_text_w = card_w - card_pad * 2 - 30 - 3;
                                    var tbuf: [256]u8 = undefined;
                                    const display = if (render_mod.textWidth(f, sum_str) > max_text_w) blk: {
                                        var lo: usize = 0;
                                        var hi: usize = sum_str.len;
                                        while (lo < hi) {
                                            const mid = (lo + hi + 1) / 2;
                                            if (render_mod.textWidth(f, sum_str[0..mid]) <= max_text_w - 12) lo = mid else hi = mid - 1;
                                        }
                                        if (lo == 0) break :blk "";
                                        @memcpy(tbuf[0..lo], sum_str[0..lo]);
                                        tbuf[lo] = '.'; tbuf[lo + 1] = '.'; tbuf[lo + 2] = '.';
                                        break :blk tbuf[0 .. lo + 3];
                                    } else sum_str;
                                    if (display.len > 0) {
                                        render_mod.renderText(&canvas, f, display, card_x + card_pad + 3, draw_y + 30 + f.baselineOffset(), colOnLayer2);
                                    }
                                }
                            }

                            // Body
                            if (self.font_small) |*f| {
                                const body_str: []const u8 = n.body[0..n.body_len];
                                if (body_str.len > 0) {
                                    const max_text_w = card_w - card_pad * 2 - 3;
                                    var bbuf: [512]u8 = undefined;
                                    const display = if (render_mod.textWidth(f, body_str) > max_text_w) blk: {
                                        var lo: usize = 0;
                                        var hi: usize = body_str.len;
                                        while (lo < hi) {
                                            const mid = (lo + hi + 1) / 2;
                                            if (render_mod.textWidth(f, body_str[0..mid]) <= max_text_w - 12) lo = mid else hi = mid - 1;
                                        }
                                        if (lo == 0) break :blk "";
                                        @memcpy(bbuf[0..lo], body_str[0..lo]);
                                        bbuf[lo] = '.'; bbuf[lo + 1] = '.'; bbuf[lo + 2] = '.';
                                        break :blk bbuf[0 .. lo + 3];
                                    } else body_str;
                                    if (display.len > 0) {
                                        render_mod.renderText(&canvas, f, display, card_x + card_pad + 3, draw_y + 48 + f.baselineOffset(), colOnLayer1Inactive);
                                    }
                                }
                            }

                            // Close button
                            if (self.font_material) |*fMat| {
                                render_mod.renderText(&canvas, fMat, "close", card_x + card_w - 36 - 3, draw_y + 10 + fMat.baselineOffset(), colOnLayer1Inactive);
                            }
                        }

                        card_y += card_h + card_gap;
                        drawn += 1;
                    }
                    g += 1;
                }
            }

            // Status bar at bottom of notification section (fixed height, proper padding)
            const status_h: i32 = 36;
            const status_y = notif_y + notif_h - notif_inner_pad - status_h;
            const status_w = inner_w - notif_inner_pad * 2;
            const status_x = inner_x + notif_inner_pad;

            canvas.fillRoundedRectMSAA(status_x, status_y, status_w, status_h, @divTrunc(status_h, 2), colLayer2);

            if (self.font) |*f| {
                const count = notif.list_len;
                var count_buf: [32]u8 = undefined;
                const count_str = std.fmt.bufPrint(&count_buf, "{d} notifications", .{count}) catch "notifications";
                const tbl = status_y + @divTrunc(status_h - f.lineHeight(), 2) + f.baselineOffset();
                const tw = render_mod.textWidth(f, count_str);
                render_mod.renderText(&canvas, f, count_str, status_x + @divTrunc(status_w - tw, 2), tbl, colOnLayer1);
            }

            if (self.font_material) |*fMat| {
                const icon_y = status_y + @divTrunc(status_h - fMat.lineHeight(), 2) + fMat.baselineOffset();
                render_mod.renderText(&canvas, fMat, "notifications_off", status_x + 10, icon_y, colOnLayer1Inactive);
            }

            if (self.font_material) |*fMat| {
                const icon_y = status_y + @divTrunc(status_h - fMat.lineHeight(), 2) + fMat.baselineOffset();
                render_mod.renderText(&canvas, fMat, "delete_sweep", status_x + status_w - 30, icon_y, colOnLayer1Inactive);
            }
        }

        cur_y += notif_h + 10;

        // Section 5: BottomWidgetGroup
        canvas.fillRoundedRectMSAA(inner_x, bottom_y, inner_w, bottom_h, Appearance.sidebar_widget_radius, colLayer1);

        if (self.bottom_collapsed) {
            // Collapsed: expand button + summary text
            const collapse_btn_size: i32 = 30;
            const collapse_btn_cx = inner_x + 10 + @divTrunc(collapse_btn_size, 2);
            const collapse_btn_cy = bottom_y + @divTrunc(bottom_h, 2);

            canvas.fillCircle(collapse_btn_cx, collapse_btn_cy, @divTrunc(collapse_btn_size, 2), colLayer2);
            if (self.font_material) |*fMat| {
                const icon_y = collapse_btn_cy - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                const icon_w = render_mod.textWidth(fMat, "keyboard_arrow_up");
                render_mod.renderText(&canvas, fMat, "keyboard_arrow_up", collapse_btn_cx - @divTrunc(icon_w, 2), icon_y, colOnLayer1);
            }

            if (self.font) |*f| {
                const summary = "Calendar • 0 tasks";
                const text_y = bottom_y + @divTrunc(bottom_h - f.lineHeight(), 2) + f.baselineOffset();
                render_mod.renderText(&canvas, f, summary, inner_x + 50, text_y, colOnLayer1);
            }
        } else {
            // Expanded: navigation rail + content area
            const nav_x = inner_x + 10;
            const nav_y = bottom_y + 10;
            const nav_btn_size: i32 = 36;
            const nav_spacing: i32 = 5;
            const nav_icons = [_][]const u8{ "calendar_month", "done_outline", "schedule" };

            // Vertical stack: chevron closely grouped above tab icons
            const chevron_cx = nav_x + @divTrunc(nav_btn_size, 2);
            const chevron_cy = nav_y + @divTrunc(nav_btn_size, 2);
            canvas.fillCircle(chevron_cx, chevron_cy, @divTrunc(nav_btn_size, 2), colLayer2);
            if (self.font_material) |*fMat| {
                const icon_y = chevron_cy - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                const icon_w = render_mod.textWidth(fMat, "keyboard_arrow_down");
                render_mod.renderText(&canvas, fMat, "keyboard_arrow_down", chevron_cx - @divTrunc(icon_w, 2), icon_y, colOnLayer1);
            }

            // Tab icons closely spaced below chevron with equal margins
            const tab_start_y = nav_y + nav_btn_size + 5;

            for (nav_icons, 0..) |icon, i| {
                const btn_cy = tab_start_y + @as(i32, @intCast(i)) * (nav_btn_size + nav_spacing) + @divTrunc(nav_btn_size, 2);
                const btn_cx = nav_x + @divTrunc(nav_btn_size, 2);

                const is_selected = self.selected_tab == i;
                if (is_selected) {
                    canvas.fillCircle(btn_cx, btn_cy, @divTrunc(nav_btn_size, 2), colPrimary);
                } else {
                    canvas.fillCircle(btn_cx, btn_cy, @divTrunc(nav_btn_size, 2), colLayer2);
                }

                if (self.font_material) |*fMat| {
                    const icon_y = btn_cy - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                    const icon_w = render_mod.textWidth(fMat, icon);
                    const icon_color = if (is_selected) colOnPrimary else colOnLayer1;
                    render_mod.renderText(&canvas, fMat, icon, btn_cx - @divTrunc(icon_w, 2), icon_y, icon_color);
                }
            }

            // Content area - calendar grid starts after nav rail
            const content_x = nav_x + nav_btn_size + 15;
            const content_w = inner_w - (content_x - inner_x) - 10;
            const content_y = bottom_y + 10;
            const content_h = bottom_h - 20;

            // Draw calendar grid for calendar tab
            if (self.selected_tab == 0) {
                // Get current date using Howard Hinnant's civil_from_days algorithm
                var ts: std.os.linux.timespec = undefined;
                _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
                const epoch_seconds = @as(i64, @intCast(ts.sec));
                const days_since_epoch = @divFloor(epoch_seconds, 86400);
                // Howard Hinnant's civil_from_days algorithm
                const z = days_since_epoch + 719468;
                const era: i64 = @divFloor(z, 146097);
                const doe: i64 = z - era * 146097;
                const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
                const y: i64 = yoe + era * 400;
                const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
                const mp: i64 = @divFloor(5 * doy + 2, 153);
                const m: i64 = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
                const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
                var cal_year: i32 = @intCast(if (m <= 2) y + 1 else y);
                var cal_month: i32 = @intCast(m);
                const today_day: i32 = @intCast(d);

                // Apply month offset for navigation
                cal_month += self.cal_month_offset;
                while (cal_month > 12) {
                    cal_month -= 12;
                    cal_year += 1;
                }
                while (cal_month < 1) {
                    cal_month += 12;
                    cal_year -= 1;
                }

                const final_month: usize = @intCast(cal_month);
                const final_day: i32 = if (self.cal_month_offset == 0) today_day else 0; // Only highlight today on current month

                const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
                const day_names = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
                const days_per_month_leap = [_]i32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
                const days_per_month = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
                const is_leap = (@mod(@as(i64, cal_year), 4) == 0 and @mod(@as(i64, cal_year), 100) != 0) or (@mod(@as(i64, cal_year), 400) == 0);
                const month_days = if (is_leap) days_per_month_leap[final_month - 1] else days_per_month[final_month - 1];

                // Calculate first day of month (0=Monday, 6=Sunday)
                // Using Zeller's congruence
                var zeller_m: i64 = @intCast(cal_month);
                var zeller_y: i64 = @intCast(cal_year);
                if (cal_month < 3) {
                    zeller_m += 12;
                    zeller_y -= 1;
                }
                const q: i64 = 1;
                const K: i64 = @mod(zeller_y, 100);
                const J: i64 = @divFloor(zeller_y, 100);
                var h: i64 = q + @divFloor(13 * (zeller_m + 1), 5) + K + @divFloor(K, 4) + @divFloor(J, 4) - 2 * J;
                h = @mod(h, 7);
                const first_day_of_month: i32 = @intCast(@mod(h + 5, 7));

                // Calendar layout - fixed cell size like end-4 (38px + 5px spacing)
                const cell_size: i32 = 38;
                const cell_spacing: i32 = 5;
                const cal_nav_size: i32 = 24;
                const cal_nav_pad: i32 = 8;
                const grid_w = 7 * cell_size + 6 * cell_spacing;
                const cal_x = content_x + @divTrunc(content_w - grid_w, 2);

                // Header row: < Jul 2026 > centered over grid, flush with content top
                // 16px bottom margin between header and day names
                // Day names use 18px height (text only, not 38px cells)
                // Grid: 6 rows of 38px cells with consistent 5px gaps
                // Matches end-4 CalendarWidget.qml ColumnLayout spacing

                const header_y = content_y;
                if (self.font) |*f| {
                    const month_text = month_names[final_month - 1];
                    var year_buf: [8]u8 = undefined;
                    const year_str = std.fmt.bufPrint(&year_buf, "{d}", .{cal_year}) catch "2026";
                    var header_buf: [16]u8 = undefined;
                    const header = std.fmt.bufPrint(&header_buf, "{s} {s}", .{ month_text, year_str }) catch "Jul 2026";
                    const header_text_w = render_mod.textWidth(f, header);

                    // Group width: [nav] [pad] [text] [pad] [nav]
                    const header_group_w = cal_nav_size + cal_nav_pad + header_text_w + cal_nav_pad + cal_nav_size;
                    const header_group_x = cal_x + @divTrunc(grid_w - header_group_w, 2);
                    const header_center_y = header_y + @divTrunc(cal_nav_size, 2);

                    // Left chevron
                    const left_btn_cx = header_group_x + @divTrunc(cal_nav_size, 2);
                    canvas.fillCircle(left_btn_cx, header_center_y, @divTrunc(cal_nav_size, 2), colLayer2);

                    // Header text
                    const text_x = header_group_x + cal_nav_size + cal_nav_pad;
                    const text_baseline_y = header_center_y - @divTrunc(f.lineHeight(), 2) + f.baselineOffset();
                    render_mod.renderText(&canvas, f, header, text_x, text_baseline_y, colOnLayer1);

                    // Right chevron
                    const right_btn_cx = header_group_x + cal_nav_size + cal_nav_pad + header_text_w + cal_nav_pad + @divTrunc(cal_nav_size, 2);
                    canvas.fillCircle(right_btn_cx, header_center_y, @divTrunc(cal_nav_size, 2), colLayer2);

                    // Chevron icons on top of circles
                    if (self.font_material) |*fMat| {
                        const l_icon_y = header_center_y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                        const l_icon_w = render_mod.textWidth(fMat, "chevron_left");
                        render_mod.renderText(&canvas, fMat, "chevron_left", left_btn_cx - @divTrunc(l_icon_w, 2), l_icon_y, colOnLayer1);

                        const r_icon_y = header_center_y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                        const r_icon_w = render_mod.textWidth(fMat, "chevron_right");
                        render_mod.renderText(&canvas, fMat, "chevron_right", right_btn_cx - @divTrunc(r_icon_w, 2), r_icon_y, colOnLayer1);
                    }
                }

                // Day names row with 16px bottom margin from header
                const header_bottom_margin: i32 = 16;
                const day_names_y = header_y + cal_nav_size + header_bottom_margin;
                if (self.font_small) |*f| {
                    for (day_names, 0..) |dname, i| {
                        const cell_cx = cal_x + @as(i32, @intCast(i)) * (cell_size + cell_spacing) + @divTrunc(cell_size, 2);
                        const dx = cell_cx - @divTrunc(render_mod.textWidth(f, dname), 2);
                        render_mod.renderText(&canvas, f, dname, dx, day_names_y, colOnLayer1Inactive);
                    }
                }

                // Calendar grid: consistent 5px gap, fixed 43px rows
                const day_names_h: i32 = 18;
                const grid_y = day_names_y + day_names_h + cell_spacing;
                const row_h = cell_size + cell_spacing; // 43px per row

                if (self.font_small) |*f| {
                    var row: i32 = 0;
                    while (row < 6) : (row += 1) {
                        var col: i32 = 0;
                        while (col < 7) : (col += 1) {
                            const day_num = row * 7 + col - first_day_of_month + 1;
                            if (day_num >= 1 and day_num <= month_days) {
                                const is_today = day_num == final_day;
                                const cell_cx = cal_x + @as(i32, @intCast(col)) * (cell_size + cell_spacing) + @divTrunc(cell_size, 2);
                                const cell_cy = grid_y + @as(i32, @intCast(row)) * row_h + @divTrunc(row_h, 2);

                                var day_buf: [4]u8 = undefined;
                                const day_str = if (day_num < 10) blk: {
                                    day_buf[0] = '0';
                                    day_buf[1] = @as(u8, @intCast('0' + day_num));
                                    break :blk day_buf[0..2];
                                } else blk: {
                                    day_buf[0] = @as(u8, @intCast('0' + @divTrunc(day_num, 10)));
                                    day_buf[1] = @as(u8, @intCast('0' + @mod(day_num, 10)));
                                    break :blk day_buf[0..2];
                                };

                                if (is_today) {
                                    canvas.fillCircle(cell_cx, cell_cy, 10.0, colPrimary);
                                }
                                const dx = cell_cx - @divTrunc(render_mod.textWidth(f, day_str), 2);
                                const dy = cell_cy - @divTrunc(f.lineHeight(), 2) + f.baselineOffset();
                                const text_color = if (is_today) colOnPrimary else colOnLayer1;
                                render_mod.renderText(&canvas, f, day_str, dx, dy, text_color);
                            }
                        }
                    }
                }
            } else if (self.selected_tab == 1) {
                // ── Todo tab ──
                // Tab bar: Unfinished | Done  (matching end-4 SecondaryTabBar)
                const tab_h: i32 = 40;
                const tab_y = content_y;

                // Bottom border for tab bar
                canvas.fillRect(content_x, tab_y + tab_h - 1, content_w, 1, colLayer2);

                // Two tabs with equal width
                const half_w = @divTrunc(content_w, 2);
                const tab_labels = [_][]const u8{ "Unfinished", "Done" };
                const tab_icons = [_][]const u8{ "checklist", "check_circle" };

                if (self.font) |*f| {
                    if (self.font_material) |*fMat| {
                        for (tab_labels, 0..) |label, ti| {
                            const is_sel = (ti == 0 and !self.todo_showing_done) or (ti == 1 and self.todo_showing_done);
                            const tcol = if (is_sel) colPrimary else colOnLayer1;
                            const tx = content_x + @as(i32, @intCast(ti)) * half_w;

                            // Tab indicator line when selected
                            if (is_sel) {
                                canvas.fillRect(tx, tab_y + tab_h - 3, half_w, 3, colPrimary);
                            }

                            // Icon
                            const icon_text = tab_icons[ti];
                            const iw = render_mod.textWidth(fMat, icon_text);
                            const ilh = fMat.lineHeight();
                            const text_total_w = iw + 5 + render_mod.textWidth(f, label);
                            const group_x = tx + @divTrunc(half_w - text_total_w, 2);
                            const ic_y = tab_y + @divTrunc(tab_h - ilh, 2) + fMat.baselineOffset();
                            render_mod.renderText(&canvas, fMat, icon_text, group_x, ic_y, tcol);

                            // Label
                            const lx = group_x + iw + 5;
                            const ly = tab_y + @divTrunc(tab_h - f.lineHeight(), 2) + f.baselineOffset();
                            render_mod.renderText(&canvas, f, label, lx, ly, tcol);
                        }
                    }
                }

                // Task list area
                const fab_size: i32 = 48;
                const fab_margin: i32 = 14;
                const list_y = tab_y + tab_h + 5;
                const list_bottom_pad = fab_size + fab_margin * 2 + 5;
                const list_avail_h = (content_y + content_h) - list_y - list_bottom_pad;

                const card_h: i32 = 54;
                const card_gap: i32 = 5;
                const card_round: f64 = 12.0;
                const card_text_pad_x: i32 = 10;

                // Count items for current filter
                var shown_count: usize = 0;
                for (0..self.todo_count) |i| {
                    const item = &self.todo_items[i];
                    if (item.done == self.todo_showing_done) {
                        shown_count += 1;
                    }
                }

                // Clamp scroll
                const total_list_h = @as(i32, @intCast(shown_count)) * (card_h + card_gap) - card_gap;
                const max_scroll = @max(0, total_list_h - list_avail_h);
                if (self.todo_scroll < 0) self.todo_scroll = 0;
                if (self.todo_scroll > max_scroll) self.todo_scroll = max_scroll;

                var item_idx: usize = 0;
                var draw_y = list_y - self.todo_scroll;

                if (self.font) |*f| {
                    for (0..self.todo_count) |i| {
                        const item = &self.todo_items[i];
                        if (item.done != self.todo_showing_done) continue;

                        if (draw_y + card_h > list_y and draw_y < list_y + list_avail_h) {
                            // Card background
                            canvas.fillRoundedRectMSAA(content_x, draw_y, content_w, card_h, card_round, colLayer2);

                            // Task text
                            const text_str = item.content[0..item.content_len];
                            const text_x = content_x + card_text_pad_x;
                            const text_y = draw_y + @divTrunc(card_h - f.lineHeight(), 2) + f.baselineOffset();
                            // Truncate if too wide
                            const max_text_w = content_w - card_text_pad_x * 2 - 30 - 5 - 30 - 10; // leave room for buttons
                            var display_text = text_str;
                            if (render_mod.textWidth(f, text_str) > max_text_w) {
                                // Truncate
                                var trunc_len = item.content_len;
                                while (trunc_len > 0 and render_mod.textWidth(f, text_str[0..trunc_len]) > max_text_w) {
                                    trunc_len -= 1;
                                }
                                if (trunc_len >= 3) trunc_len -= 3;
                                var trunc_buf: [256]u8 = undefined;
                                @memcpy(trunc_buf[0..trunc_len], text_str[0..trunc_len]);
                                trunc_buf[trunc_len] = '.';
                                trunc_buf[trunc_len + 1] = '.';
                                trunc_buf[trunc_len + 2] = '.';
                                display_text = trunc_buf[0 .. trunc_len + 3];
                            }
                            render_mod.renderText(&canvas, f, display_text, text_x, text_y, colOnLayer1);

                            // Action buttons (right-aligned)
                            const item_btn_sz: i32 = 28;
                            const btn_right_margin: i32 = 8;
                            const btn_spacing: i32 = 5;
                            const item_btn_y = draw_y + @divTrunc(card_h - item_btn_sz, 2);

                            // Delete button
                            const del_x = content_x + content_w - btn_right_margin - item_btn_sz;
                            canvas.fillCircle(del_x + @divTrunc(item_btn_sz, 2), item_btn_y + @divTrunc(item_btn_sz, 2), @divTrunc(item_btn_sz, 2), colLayer2);

                            // Check/undo button
                            const check_x = del_x - btn_spacing - item_btn_sz;
                            canvas.fillCircle(check_x + @divTrunc(item_btn_sz, 2), item_btn_y + @divTrunc(item_btn_sz, 2), @divTrunc(item_btn_sz, 2), colPrimary);

                            if (self.font_material) |*fMat| {
                                // Check/undo icon
                                const check_icon = if (item.done) "remove_done" else "check";
                                const ciw = render_mod.textWidth(fMat, check_icon);
                                const ciy = item_btn_y + @divTrunc(item_btn_sz - fMat.lineHeight(), 2) + fMat.baselineOffset();
                                render_mod.renderText(&canvas, fMat, check_icon, check_x + @divTrunc(item_btn_sz - ciw, 2), ciy, colOnPrimary);

                                // Delete icon
                                const diw = render_mod.textWidth(fMat, "delete_forever");
                                const diy = item_btn_y + @divTrunc(item_btn_sz - fMat.lineHeight(), 2) + fMat.baselineOffset();
                                render_mod.renderText(&canvas, fMat, "delete_forever", del_x + @divTrunc(item_btn_sz - diw, 2), diy, colOnLayer1);
                            }
                        }

                        draw_y += card_h + card_gap;
                        item_idx += 1;
                    }
                }

                // Empty state
                if (shown_count == 0) {
                    const empty_icon = if (self.todo_showing_done) "checklist" else "check_circle";
                    const empty_text = if (self.todo_showing_done) "Finished tasks will go here" else "Nothing here!";

                    if (self.font_material) |*fMat| {
                        const ei_size: i32 = 55;
                        const ei_x = content_x + @divTrunc(content_w, 2);
                        const ei_y = list_y + @divTrunc(list_avail_h, 2) - 25;
                        canvas.fillCircle(ei_x, ei_y, @divTrunc(ei_size, 2), colLayer2);
                        const eiw = render_mod.textWidth(fMat, empty_icon);
                        const eiy_base = ei_y - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                        render_mod.renderText(&canvas, fMat, empty_icon, ei_x - @divTrunc(eiw, 2), eiy_base, colOutlineVariant);
                    }
                    if (self.font) |*f| {
                        const ew = render_mod.textWidth(f, empty_text);
                        const ey = list_y + @divTrunc(list_avail_h, 2) + 19;
                        render_mod.renderText(&canvas, f, empty_text, content_x + @divTrunc(content_w - ew, 2), ey, colOutlineVariant);
                    }
                }

                // FAB
                const fab_cx = content_x + content_w - fab_margin - @divTrunc(fab_size, 2);
                const fab_cy = content_y + content_h - fab_margin - @divTrunc(fab_size, 2) + 2;
                canvas.fillCircle(fab_cx, fab_cy, @divTrunc(fab_size, 2), colPrimaryContainer);
                if (self.font_material) |*fMat| {
                    const fiw = render_mod.textWidth(fMat, "add");
                    const fiy = fab_cy - @divTrunc(fMat.lineHeight(), 2) + fMat.baselineOffset();
                    render_mod.renderText(&canvas, fMat, "add", fab_cx - @divTrunc(fiw, 2), fiy, colOnPrimaryContainer);
                }

                // Add dialog — M3 elevated dialog with rounded scrim & layered drop shadow
                if (self.todo_show_add) {
                    const dia_margin: i32 = 20;
                    const dia_w = content_w - 2 * dia_margin;
                    const dia_x = content_x + dia_margin;
                    const dia_radius: i32 = Appearance.sidebar_widget_radius;
                    // Scrim — rounded to match content area, using soft color
                    canvas.fillRoundedRectMSAA(content_x, content_y, content_w, content_h, Appearance.sidebar_widget_radius, Color.rgba(0, 0, 0, 60));
                    // Multi-layer drop shadow behind dialog (simulates M3 elevation)
                    const shadow_alphas = [_]u8{ 4, 9, 16, 26, 40 };
                    const shadow_offsets = [_]i32{ 8, 5, 3, 1, 0 };
                    const shadow_spreads = [_]i32{ 14, 9, 5, 2, 0 };
                    const sh_count: usize = 5;
                    // Compute dialog height from content
                    const title_h_est: i32 = 24;
                    const input_h_add: i32 = 44;
                    const btn_h_add: i32 = 36;
                    const dia_inner_pad: i32 = 16;
                    const dia_spacing: i32 = 14;
                    const dia_h = dia_inner_pad + title_h_est + dia_spacing + input_h_add + dia_spacing + btn_h_add + dia_inner_pad;
                    const dia_y = content_y + @divTrunc(content_h - dia_h, 2);
                    var si: usize = 0;
                    while (si < sh_count) : (si += 1) {
                        const sp = shadow_spreads[si];
                        canvas.fillRoundedRectMSAA(dia_x - sp, dia_y - sp + shadow_offsets[si], dia_w + 2 * sp, dia_h + 2 * sp, dia_radius, Color.rgba(0, 0, 0, shadow_alphas[si]));
                    }
                    // Dialog surface
                    canvas.fillRoundedRectMSAA(dia_x, dia_y, dia_w, dia_h, dia_radius, colLayer2);
                    // Subtle 1px border for surface distinction
                    canvas.fillRoundedRectMSAA(dia_x, dia_y, dia_w, dia_h, dia_radius, Color.rgba(0x49, 0x46, 0x4a, 30));
                    // Title
                    if (self.font) |*f| {
                        render_mod.renderText(&canvas, f, "Add task", dia_x + dia_inner_pad, dia_y + dia_inner_pad + f.baselineOffset() + 2, colOnLayer2);
                    }
                    // Input field — transparent bg with outline border (end-4 style)
                    const input_x = dia_x + dia_inner_pad;
                    const input_y = dia_y + dia_inner_pad + title_h_est + dia_spacing;
                    const input_w = dia_w - 2 * dia_inner_pad;
                    canvas.fillRoundedRectMSAA(input_x, input_y, input_w, input_h_add, 8, colLayer1);
                    if (self.todo_input_active) {
                        canvas.fillRoundedRectMSAA(input_x, input_y, input_w, input_h_add, 8, Color.rgba(0xcb, 0xc4, 0xcb, 80));
                    } else {
                        canvas.fillRoundedRectMSAA(input_x, input_y, input_w, input_h_add, 8, Color.rgba(0x94, 0x8f, 0x94, 60));
                    }
                    if (self.font) |*f| {
                        const input_text = self.todo_input_buf[0..self.todo_input_len];
                        if (self.todo_input_len > 0) {
                            const tw = render_mod.textWidth(f, input_text);
                            const display_w = input_w - 24;
                            const scroll_off = if (tw > display_w) tw - display_w else 0;
                            render_mod.renderText(&canvas, f, input_text, input_x + 12 - scroll_off, input_y + @divTrunc(input_h_add - f.lineHeight(), 2) + f.baselineOffset(), colOnLayer2);
                        } else {
                            render_mod.renderText(&canvas, f, "Task description", input_x + 12, input_y + @divTrunc(input_h_add - f.lineHeight(), 2) + f.baselineOffset(), colOnLayer1Inactive);
                        }
                    }
                    // Buttons row (right-aligned, end-4 style)
                    const btns_y = dia_y + dia_h - dia_inner_pad - btn_h_add;
                    const btn_w_add: i32 = 80;
                    const btn_gap_add: i32 = 5;
                    const cancel_x = dia_x + dia_w - dia_inner_pad - 2 * btn_w_add - btn_gap_add;
                    const add_x = dia_x + dia_w - dia_inner_pad - btn_w_add;
                    // Cancel — pill shape, transparent bg
                    canvas.fillRoundedRectMSAA(cancel_x, btns_y, btn_w_add, btn_h_add, @divTrunc(btn_h_add, 2), Color.rgba(0x1c, 0x1b, 0x1c, 0));
                    if (self.font) |*f| {
                        const cw = render_mod.textWidth(f, "Cancel");
                        render_mod.renderText(&canvas, f, "Cancel", cancel_x + @divTrunc(btn_w_add - cw, 2), btns_y + @divTrunc(btn_h_add - f.lineHeight(), 2) + f.baselineOffset(), colPrimary);
                    }
                    // Add — pill shape, primary container bg
                    canvas.fillRoundedRectMSAA(add_x, btns_y, btn_w_add, btn_h_add, @divTrunc(btn_h_add, 2), colPrimaryContainer);
                    if (self.font) |*f| {
                        const aw = render_mod.textWidth(f, "Add");
                        render_mod.renderText(&canvas, f, "Add", add_x + @divTrunc(btn_w_add - aw, 2), btns_y + @divTrunc(btn_h_add - f.lineHeight(), 2) + f.baselineOffset(), colOnPrimaryContainer);
                    }
                }
            } else {
                // Timer tab placeholder
                if (self.font) |*f| {
                    const placeholder = "Timer";
                    const tw = render_mod.textWidth(f, placeholder);
                    const tbl = content_y + @divTrunc(content_h - f.lineHeight(), 2) + f.baselineOffset();
                    render_mod.renderText(&canvas, f, placeholder, content_x + @divTrunc(content_w - tw, 2), tbl, colOnLayer1Inactive);
                }
            }
        }
    }

    pub fn handleScroll(self: *Sidebar, ctx: *Context, delta_y: i32) void {
        // Determine which section has focus for scrolling
        // If bottom widget is expanded and todo tab is selected, scroll todo list
        if (!self.bottom_collapsed and self.selected_tab == 1) {
            self.todo_scroll -= delta_y;
            if (self.todo_scroll < 0) self.todo_scroll = 0;
            // Max scroll is clamped during draw
            self.needs_redraw = true;
            return;
        }

        // Default: scroll notifications
        self.scroll_offset += delta_y;
        if (self.scroll_offset < 0) self.scroll_offset = 0;
        const notif = ctx.notifications;
        const M = Appearance.sidebar_margin;
        const P = Appearance.sidebar_padding;
        const sys_row_h: i32 = 40;
        const sliders_total_h: i32 = 4 + 30 + 4 + 30 + 4; // v_pad + slider + gap + slider + v_pad
        const toggle_h: i32 = 50;
        const bottom_h: i32 = if (self.bottom_collapsed) 50 else Appearance.sidebar_bottom_height;
        const notif_h = self.height - (M + P + sys_row_h + 10 + sliders_total_h + 10 + toggle_h + 10) - bottom_h - P - M;
        const max_scroll = @max(0, @as(i32, @intCast(notif.list_len)) * 83 - notif_h + 50);
        if (self.scroll_offset > max_scroll) self.scroll_offset = max_scroll;
        self.needs_redraw = true;
    }

    pub fn handleClick(self: *Sidebar, ctx: *Context, x: i32, y: i32) void {
        std.log.info("sidebar handleClick: x={} y={} height={}", .{ x, y, self.height });
        const M = Appearance.sidebar_margin;
        const E = Appearance.sidebar_elevation;
        const P = Appearance.sidebar_padding;

        const bg_x = E;
        const bg_w = SIDEBAR_W - M - E;
        if (x < bg_x or x >= bg_x + bg_w) {
            std.log.info("sidebar handleClick: outside bg area", .{});
            return;
        }

        // Section 5: BottomWidgetGroup
        const bottom_h: i32 = if (self.bottom_collapsed) 50 else Appearance.sidebar_bottom_height;
        const bottom_y = self.height - M - P - bottom_h;
        if (y >= bottom_y and y < bottom_y + bottom_h) {
            const nav_x = bg_x + P + 10;
            const nav_y_pos = bottom_y + 10;
            const nav_btn_size: i32 = 36;
            const nav_spacing: i32 = 5;

            if (self.bottom_collapsed) {
                // Collapsed: click on expand button
                const collapse_btn_cx = nav_x + @divTrunc(nav_btn_size, 2);
                const collapse_btn_cy = bottom_y + @divTrunc(bottom_h, 2);
                const dx = x - collapse_btn_cx;
                const dy = y - collapse_btn_cy;
                if (dx * dx + dy * dy <= @divTrunc(nav_btn_size, 2) * @divTrunc(nav_btn_size, 2)) {
                    self.bottom_collapsed = false;
                    self.needs_full_redraw = true;
                    std.log.info("sidebar: bottom expand clicked", .{});
                    return;
                }
            } else {
                // Expanded: click on collapse button
                const collapse_btn_cx = nav_x + @divTrunc(nav_btn_size, 2);
                const collapse_btn_cy = nav_y_pos;
                const dx = x - collapse_btn_cx;
                const dy = y - collapse_btn_cy;
                if (dx * dx + dy * dy <= @divTrunc(nav_btn_size, 2) * @divTrunc(nav_btn_size, 2)) {
                    self.bottom_collapsed = true;
                    self.needs_full_redraw = true;
                    std.log.info("sidebar: bottom collapse clicked", .{});
                    return;
                }

                // Tab buttons
                for (0..3) |i| {
                    const btn_y = nav_y_pos + nav_btn_size + nav_spacing + @as(i32, @intCast(i)) * (nav_btn_size + nav_spacing);
                    const btn_cx = nav_x + @divTrunc(nav_btn_size, 2);
                    const btn_cy = btn_y + @divTrunc(nav_btn_size, 2);
                    const tdx = x - btn_cx;
                    const tdy = y - btn_cy;
                    if (tdx * tdx + tdy * tdy <= @divTrunc(nav_btn_size, 2) * @divTrunc(nav_btn_size, 2)) {
                        self.selected_tab = @intCast(i);
                        self.needs_full_redraw = true;
                        std.log.info("sidebar: nav tab {d} clicked", .{i});
                        return;
                    }
                }

                // Calendar navigation buttons (if calendar tab is selected)
                if (self.selected_tab == 0) {
                    const content_x = nav_x + nav_btn_size + 15;
                    const content_w_cal = bg_w - P * 2 - (content_x - bg_x - P);
                    const cell_size_cal: i32 = 38;
                    const cell_spacing_cal: i32 = 5;
                    const grid_w_cal = 7 * cell_size_cal + 6 * cell_spacing_cal;
                    const cal_x_cal = content_x + @divTrunc(content_w_cal - grid_w_cal, 2);

                    const cal_nav_btn_size: i32 = 24;
                    const cal_nav_btn_pad: i32 = 8;

                    // Match draw: header at bottom_y + 10, center at bottom_y + 10 + 12
                    const chev_click_cy = bottom_y + 22;

                    // Need header text width to compute group position
                    if (self.font) |*f| {
                        const month_names_click = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
                        var ts2: std.os.linux.timespec = undefined;
                        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts2);
                        const ep2 = @as(i64, @intCast(ts2.sec));
                        const dse2 = @divFloor(ep2, 86400);
                        const z2 = dse2 + 719468;
                        const e2 = @divFloor(z2, 146097);
                        const doe2 = z2 - e2 * 146097;
                        const yoe2 = @divFloor(doe2 - @divFloor(doe2, 1460) + @divFloor(doe2, 36524) - @divFloor(doe2, 146096), 365);
                        const y2 = yoe2 + e2 * 400;
                        const doy2 = doe2 - (365 * yoe2 + @divFloor(yoe2, 4) - @divFloor(yoe2, 100));
                        const mp2 = @divFloor(5 * doy2 + 2, 153);
                        const m2 = mp2 + (if (mp2 < 10) @as(i64, 3) else @as(i64, -9));
                        var cy2: i32 = @intCast(if (m2 <= 2) y2 + 1 else y2);
                        var cm2: i32 = @intCast(m2);
                        cm2 += self.cal_month_offset;
                        while (cm2 > 12) { cm2 -= 12; cy2 += 1; }
                        while (cm2 < 1) { cm2 += 12; cy2 -= 1; }

                        const mt = month_names_click[@intCast(cm2 - 1)];
                        var yb: [8]u8 = undefined;
                        const ys = std.fmt.bufPrint(&yb, "{d}", .{cy2}) catch "2026";
                        var hb: [16]u8 = undefined;
                        const hdr = std.fmt.bufPrint(&hb, "{s} {s}", .{ mt, ys }) catch "Jul 2026";
                        const hdr_w = render_mod.textWidth(f, hdr);

                        const group_w = cal_nav_btn_size + cal_nav_btn_pad + hdr_w + cal_nav_btn_pad + cal_nav_btn_size;
                        const group_x = cal_x_cal + @divTrunc(grid_w_cal - group_w, 2);

                        // Left chevron
                        const left_btn_cx = group_x + @divTrunc(cal_nav_btn_size, 2);
                        const ldx = x - left_btn_cx;
                        const ldy = y - chev_click_cy;
                        if (ldx * ldx + ldy * ldy <= @divTrunc(cal_nav_btn_size, 2) * @divTrunc(cal_nav_btn_size, 2)) {
                            self.cal_month_offset -= 1;
                            self.needs_full_redraw = true;
                            std.log.info("sidebar: calendar prev month", .{});
                            return;
                        }

                        // Right chevron
                        const right_btn_cx = group_x + cal_nav_btn_size + cal_nav_btn_pad + hdr_w + cal_nav_btn_pad + @divTrunc(cal_nav_btn_size, 2);
                        const rdx = x - right_btn_cx;
                        const rdy = y - chev_click_cy;
                        if (rdx * rdx + rdy * rdy <= @divTrunc(cal_nav_btn_size, 2) * @divTrunc(cal_nav_btn_size, 2)) {
                            self.cal_month_offset += 1;
                            self.needs_full_redraw = true;
                            std.log.info("sidebar: calendar next month", .{});
                            return;
                        }
                    }
                }

                // Todo tab: tab bar, task items, FAB clicks
                if (self.selected_tab == 1) {
                    const content_x_cal = nav_x + nav_btn_size + 15;
                    const inner_x_cal = bg_x + P;
                    const inner_w_cal = bg_w - 2 * P;
                    const content_w_cal = inner_w_cal - (content_x_cal - inner_x_cal) - 10;
                    const content_h_cal = bottom_h - 20;

                    // Tab bar
                    const tab_h: i32 = 40;
                    const tab_y_cal = bottom_y + 10;
                    if (y >= tab_y_cal and y < tab_y_cal + tab_h) {
                        const rel_x = x - content_x_cal;
                        if (rel_x >= 0 and rel_x < content_w_cal) {
                            const tab_idx = @divTrunc(rel_x * 2, content_w_cal);
                            self.todo_showing_done = (tab_idx == 1);
                            self.needs_full_redraw = true;
                            std.log.info("sidebar: todo tab {s}", .{if (tab_idx == 0) "unfinished" else "done"});
                            return;
                        }
                    }

                    // Dialog intercept: when add dialog is open, only handle dialog/scrim
                    if (self.todo_show_add) {
                        const dia_margin_cal: i32 = 20;
                        const dia_w_cal = content_w_cal - 2 * dia_margin_cal;
                        const dia_x_cal = content_x_cal + dia_margin_cal;
                        const title_h_est_cal: i32 = 24;
                        const input_h_cal: i32 = 44;
                        const btn_h_cal: i32 = 36;
                        const btn_w_cal: i32 = 80;
                        const dia_inner_pad_cal: i32 = 16;
                        const dia_spacing_cal: i32 = 14;
                        const dia_h_cal = dia_inner_pad_cal + title_h_est_cal + dia_spacing_cal + input_h_cal + dia_spacing_cal + btn_h_cal + dia_inner_pad_cal;
                        const dia_y_cal = tab_y_cal + @divTrunc(content_h_cal - dia_h_cal, 2);

                        const btn_gap_cal: i32 = 5;
                        const btns_y_cal = dia_y_cal + dia_h_cal - dia_inner_pad_cal - btn_h_cal;
                        const cancel_x_cal = dia_x_cal + dia_w_cal - dia_inner_pad_cal - 2 * btn_w_cal - btn_gap_cal;
                        const add_x_cal = dia_x_cal + dia_w_cal - dia_inner_pad_cal - btn_w_cal;

                        // Input field hit area
                        const input_x_cal = dia_x_cal + dia_inner_pad_cal;
                        const input_y_cal = dia_y_cal + dia_inner_pad_cal + title_h_est_cal + dia_spacing_cal;
                        const input_w_cal = dia_w_cal - 2 * dia_inner_pad_cal;
                        if (x >= input_x_cal and x < input_x_cal + input_w_cal and y >= input_y_cal and y < input_y_cal + input_h_cal) {
                            self.todo_input_active = true;
                            self.needs_full_redraw = true;
                            return;
                        }
                        // Cancel
                        if (x >= cancel_x_cal and x < cancel_x_cal + btn_w_cal and y >= btns_y_cal and y < btns_y_cal + btn_h_cal) {
                            self.todo_show_add = false;
                            self.todo_input_len = 0;
                            self.todo_input_active = false;
                            self.needs_full_redraw = true;
                            std.log.info("sidebar: todo add dialog cancelled", .{});
                            return;
                        }
                        // Add
                        if (x >= add_x_cal and x < add_x_cal + btn_w_cal and y >= btns_y_cal and y < btns_y_cal + btn_h_cal) {
                            self.addTodoFromInput();
                            return;
                        }
                        // Click outside dialog → cancel
                        if (!(x >= dia_x_cal and x < dia_x_cal + dia_w_cal and y >= dia_y_cal and y < dia_y_cal + dia_h_cal)) {
                            self.todo_show_add = false;
                            self.todo_input_active = false;
                            self.needs_full_redraw = true;
                            return;
                        }
                    }

                    // FAB click
                    const fab_size_cal: i32 = 48;
                    const fab_margin_cal: i32 = 14;
                    const fab_cx_cal = content_x_cal + content_w_cal - fab_margin_cal - @divTrunc(fab_size_cal, 2);
                    const fab_cy_cal = tab_y_cal + content_h_cal - fab_margin_cal - @divTrunc(fab_size_cal, 2) + 2;
                    const fdx = x - fab_cx_cal;
                    const fdy = y - fab_cy_cal;
                    if (fdx * fdx + fdy * fdy <= @divTrunc(fab_size_cal, 2) * @divTrunc(fab_size_cal, 2)) {
                        self.todo_show_add = true;
                        self.todo_input_len = 0;
                        self.todo_input_active = true;
                        self.needs_full_redraw = true;
                        std.log.info("sidebar: todo add dialog opened", .{});
                        return;
                    }

                    // Task item check/delete buttons
                    const card_h_cal: i32 = 54;
                    const card_gap_cal: i32 = 5;
                    const list_y_cal = tab_y_cal + tab_h + 5;
                    const list_bottom_pad_cal = fab_size_cal + fab_margin_cal * 2 + 5;
                    const list_avail_h_cal = (tab_y_cal + content_h_cal) - list_y_cal - list_bottom_pad_cal;

                    // Count items for scroll clamp
                    var shown_count_cal: usize = 0;
                    for (0..self.todo_count) |i| {
                        if (self.todo_items[i].done == self.todo_showing_done) shown_count_cal += 1;
                    }
                    const total_list_h_cal = @as(i32, @intCast(shown_count_cal)) * (card_h_cal + card_gap_cal) - card_gap_cal;
                    const max_scroll_cal = @max(0, total_list_h_cal - list_avail_h_cal);
                    if (self.todo_scroll > max_scroll_cal) self.todo_scroll = max_scroll_cal;
                    // Use current todo_scroll (already clamped in draw)

                    var draw_y_cal = list_y_cal - self.todo_scroll;
                    for (0..self.todo_count) |i| {
                        const item_cal = &self.todo_items[i];
                        if (item_cal.done != self.todo_showing_done) continue;

                        if (draw_y_cal + card_h_cal > list_y_cal and draw_y_cal < list_y_cal + list_avail_h_cal) {
                            const btn_size_cal: i32 = 28;
                            const btn_right_margin_cal: i32 = 8;
                            const btn_spacing_cal: i32 = 5;
                            const btn_y_cal = draw_y_cal + @divTrunc(card_h_cal - btn_size_cal, 2);

                            // Delete button
                            const del_x_cal = content_x_cal + content_w_cal - btn_right_margin_cal - btn_size_cal;
                            const del_center_x = del_x_cal + @divTrunc(btn_size_cal, 2);
                            const btn_center_y = btn_y_cal + @divTrunc(btn_size_cal, 2);
                            const ddx = x - del_center_x;
                            const ddy = y - btn_center_y;
                            const btn_radius_cal = @divTrunc(btn_size_cal, 2);

                            // Check/undo button
                            const check_x_cal = del_x_cal - btn_spacing_cal - btn_size_cal;
                            const check_center_x = check_x_cal + @divTrunc(btn_size_cal, 2);
                            const cdx = x - check_center_x;
                            const cdy = y - btn_center_y;

                            if (cdx * cdx + cdy * cdy <= btn_radius_cal * btn_radius_cal) {
                                // Toggle done/unfinished
                                if (item_cal.done) {
                                    std.log.info("sidebar: todo mark unfinished idx={}", .{i});
                                } else {
                                    std.log.info("sidebar: todo mark done idx={}", .{i});
                                }
                                item_cal.done = !item_cal.done;
                                self.needs_full_redraw = true;
                                return;
                            }

                            if (ddx * ddx + ddy * ddy <= btn_radius_cal * btn_radius_cal) {
                                // Delete item
                                std.log.info("sidebar: todo delete idx={}", .{i});
                                // Shift remaining items
                                for (i..self.todo_count - 1) |j| {
                                    self.todo_items[j] = self.todo_items[j + 1];
                                }
                                self.todo_count -= 1;
                                self.needs_full_redraw = true;
                                return;
                            }
                        }
                        draw_y_cal += card_h_cal + card_gap_cal;
                    }
                }
            }
            return;
        }

        // Section 4: Notifications status bar
        const notif_inner_pad: i32 = 5;
        const sliders_total_h: i32 = 4 + 30 + 4 + 30 + 4;
        const notif_h = self.height - (M + P + 40 + 10 + sliders_total_h + 10 + 50 + 10) - bottom_h - P - M;
        const notif_y = M + P + 40 + 10 + sliders_total_h + 10 + 50 + 10;
        if (y >= notif_y and y < notif_y + notif_h) {
            const status_h: i32 = 36;
            const status_y = notif_y + notif_h - notif_inner_pad - status_h;
            if (y >= status_y and y < status_y + status_h) {
                const status_x = bg_x + P + notif_inner_pad;
                const status_w = bg_w - P * 2 - notif_inner_pad * 2;
                if (x >= status_x and x < status_x + 40) {
                    ctx.notifications.markAllRead();
                    self.needs_redraw = true;
                    return;
                }
                if (x >= status_x + status_w - 40 and x < status_x + status_w) {
                    ctx.notifications.dismissAll();
                    self.needs_redraw = true;
                    return;
                }
                return;
            }

            // Notification cards (grouped by app)
            const card_h: i32 = 80;
            const card_gap: i32 = 3;
            const group_gap: i32 = 6;
            const header_h: i32 = 22;
            const card_x = bg_x + P + notif_inner_pad;
            const card_w = bg_w - P * 2 - notif_inner_pad * 2;
            const notif_count = ctx.notifications.list_len;

            const max_groups = 16;
            var group_app: [max_groups][]const u8 = undefined;
            var group_count: [max_groups]usize = undefined;
            var group_len: usize = 0;

            for (0..notif_count) |i| {
                const ni = notif_count - 1 - i;
                const a = ctx.notifications.list[ni].app_name[0..ctx.notifications.list[ni].app_name_len];
                var found = false;
                for (0..group_len) |g| {
                    if (group_len > 0 and std.mem.eql(u8, a, group_app[g])) {
                        group_count[g] += 1;
                        found = true;
                        break;
                    }
                }
                if (!found and group_len < max_groups) {
                    group_app[group_len] = a;
                    group_count[group_len] = 1;
                    group_len += 1;
                }
            }

            var card_y: i32 = notif_y + notif_inner_pad;
            var drawn: usize = 0;
            var g: usize = 0;
            while (g < group_len) {
                if (drawn > 0) {
                    card_y += group_gap;
                }

                // Skip if past visible area
                if (card_y - self.scroll_offset + header_h > notif_y and card_y - self.scroll_offset < notif_y + notif_h - status_h) {
                    const draw_header_y = card_y - self.scroll_offset;
                    if (x >= card_x and x < card_x + card_w and y >= draw_header_y and y < draw_header_y + header_h) {
                        // Click on group header — mark all from this app as read
                        // Find first notif in this group
                        for (0..notif_count) |i| {
                            const ni = notif_count - 1 - i;
                            const a = ctx.notifications.list[ni].app_name[0..ctx.notifications.list[ni].app_name_len];
                            if (std.mem.eql(u8, a, group_app[g])) {
                                ctx.notifications.dismiss(ctx.notifications.list[ni].id);
                            }
                        }
                        self.needs_redraw = true;
                        return;
                    }
                }
                card_y += header_h + card_gap;

                for (0..notif_count) |i| {
                    if ((card_y - notif_y) + card_h > notif_h) break;
                    const ni = notif_count - 1 - i;
                    const a = ctx.notifications.list[ni].app_name[0..ctx.notifications.list[ni].app_name_len];
                    if (!std.mem.eql(u8, a, group_app[g])) continue;

                    const draw_y = card_y - self.scroll_offset;
                    if (draw_y + card_h > notif_y and draw_y < notif_y + notif_h) {
                        // Close button hit test
                        if (x >= card_x + card_w - 46 - 3 and x < card_x + card_w - 10 - 3 and
                            y >= draw_y and y < draw_y + 24)
                        {
                            ctx.notifications.dismiss(ctx.notifications.list[ni].id);
                            self.needs_redraw = true;
                            return;
                        }
                        // Card body area — mark as read
                        // (click anywhere else on card = dismiss, like end-4)
                        if (x >= card_x + 3 and x < card_x + card_w and
                            y >= draw_y and y < draw_y + card_h)
                        {
                            ctx.notifications.dismiss(ctx.notifications.list[ni].id);
                            self.needs_redraw = true;
                            return;
                        }
                    }
                    card_y += card_h + card_gap;
                    drawn += 1;
                }
                g += 1;
            }
        }
        // Click on non-interactive area inside sidebar → do nothing
        // (Only clicks OUTSIDE the sidebar dismiss it, handled in bar.zig)
        std.log.info("sidebar handleClick: non-interactive area — no action", .{});
    }

    // Todo input helpers (called from bar.zig keyboard listener)
    pub fn appendTodoInputChar(self: *Sidebar, chars: []const u8) void {
        const avail = self.todo_input_buf.len - self.todo_input_len;
        const to_copy = @min(avail, chars.len);
        if (to_copy > 0) {
            @memcpy(self.todo_input_buf[self.todo_input_len..][0..to_copy], chars[0..to_copy]);
            self.todo_input_len += to_copy;
        }
        self.needs_full_redraw = true;
    }

    pub fn deleteTodoInputChar(self: *Sidebar) void {
        if (self.todo_input_len > 0) {
            self.todo_input_len -= 1;
            self.needs_full_redraw = true;
        }
    }

    pub fn addTodoFromInput(self: *Sidebar) void {
        if (self.todo_input_len > 0 and self.todo_count < self.todo_items.len) {
            var new_task = TodoTask{ .done = false };
            @memcpy(new_task.content[0..self.todo_input_len], self.todo_input_buf[0..self.todo_input_len]);
            new_task.content_len = self.todo_input_len;
            self.todo_items[self.todo_count] = new_task;
            self.todo_count += 1;
        }
        self.todo_input_len = 0;
        self.todo_input_active = false;
        self.todo_show_add = false;
        self.needs_full_redraw = true;
        std.log.info("sidebar: todo task added via keyboard", .{});
    }

    pub fn commit(self: *Sidebar, _: *Context) void {
        if (!self.visible) return;
        if (self.animating) return;
        const buf = self.buffer orelse return;
        if (self.surface) |s| {
            s.attach(buf.buffer, 0, 0);
            s.damageBuffer(0, 0, buf.width, buf.height);
            s.commit();
        }
    }
};
