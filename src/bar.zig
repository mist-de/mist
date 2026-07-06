const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Context = @import("wl.zig").Context;
const LayerSurface = @import("wl.zig").LayerSurface;
const ShmBuffer = @import("wl.zig").ShmBuffer;
const CursorShape = @import("wl.zig").CursorShape;
const Canvas = @import("render.zig").Canvas;
const config_mod = @import("config.zig");
const Color = config_mod.Color;
const Appearance = config_mod.Appearance;
const Rect = config_mod.Rect;
const Font = @import("text.zig").Font;
const text_mod = @import("text.zig");

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
        }

        if (bar.font == null) std.log.err("NO REGULAR FONT LOADED", .{});
        if (bar.font_icon == null) std.log.err("NO ICON FONT LOADED", .{});

        return bar;
    }

    pub fn deinit(self: *Bar) void {
        if (self.buffer) |*b| b.deinit();
        if (self.font) |*f| f.deinit();
        if (self.font_icon) |*f| f.deinit();
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

        const col_layer1 = Color.rgba(0x1c, 0x1b, 0x1c, 0xE0);
        const col_on_layer0 = Color.rgba(0xe6, 0xe1, 0xe1, 0xFF);
        const col_on_layer1 = Color.rgba(0xcb, 0xc5, 0xca, 0xFF);
        const col_on_layer1_inactive = Color.rgba(0x7d, 0x78, 0x7c, 0xFF);
        const col_primary = Color.rgba(0xcb, 0xc4, 0xcb, 0xFF);
        const col_on_primary = Color.rgba(0x32, 0x2f, 0x34, 0xFF);
        const col_secondary_container = Color.rgba(0x4d, 0x4b, 0x4d, 0x99);
        const col_on_secondary_container = Color.rgba(0xec, 0xe6, 0xe9, 0xFF);
        const col_outline_variant = Color.rgba(0x49, 0x46, 0x4a, 0xFF);
        const col_outline = Color.rgba(0x94, 0x8f, 0x94, 0xFF);
        const col_subtext = col_outline;

        const bar_y: i32 = 0;
        const screen_rounding: i32 = 23;

        // ═══ LEFT: Sidebar button + Active window title ═══
        const sidebar_x: i32 = screen_rounding;
        const sidebar_btn_size: i32 = 30;
        const sidebar_icon_r: i32 = 10;
        const sidebar_cx = sidebar_x + @divTrunc(sidebar_btn_size, 2);
        const sidebar_cy = @divTrunc(bar_h, 2);
        canvas.fillCircle(sidebar_cx, sidebar_cy, sidebar_icon_r, col_on_layer0);

        const aw_x = sidebar_x + sidebar_btn_size + 10;
        const aw_right_limit = @divTrunc(bar_w, 2) - 80;
        if (aw_right_limit > aw_x and self.font != null) {
            const f_ptr = &self.font.?;
            const group_h = 12 + 15 - 4;
            const group_top = @divTrunc(bar_h - group_h, 2);
            const row1_y = group_top + 12;
            const row2_y = row1_y - 4 + 15;

            const app_name: []const u8 = if (ctx.active_toplevel) |at|
                std.mem.sliceTo(&ctx.toplevels[at].app_id, 0)
            else
                "mist";
            const window_title: []const u8 = if (ctx.active_toplevel) |at|
                std.mem.sliceTo(&ctx.toplevels[at].title, 0)
            else
                "Mist DE";

            text_mod.renderText(&canvas, f_ptr, app_name, aw_x, row1_y, col_subtext);
            text_mod.renderText(&canvas, f_ptr, window_title, aw_x, row2_y, col_on_layer0);
        }

        // ═══ CENTER: 3 BarGroups ═══
        const center_spacing: i32 = 4;
        const center_mod_w: i32 = if (bar_w > 1200) 360 else if (bar_w > 1000) 280 else 190;
        const ws_btn_size: i32 = 26;
        const ws_count: i32 = 5;
        const ws_bargroup_padding: i32 = 4;
        const ws_w = ws_btn_size * ws_count + ws_bargroup_padding * 2;
        const total_center = center_mod_w + center_spacing + ws_w + center_spacing + center_mod_w;
        const center_x = @divTrunc(bar_w - total_center, 2);
        const group_bg_y = bar_y + 4;
        const group_bg_h = bar_h - 8;
        const group_radius: i32 = 12;

        // Left center: Resources + Media
        const lc_x = center_x;
        canvas.fillRoundedRect(lc_x, group_bg_y, center_mod_w, group_bg_h, group_radius, col_layer1);

        var res_x = lc_x + 5;
        const res_center_y = @divTrunc(bar_h, 2);
        for (0..3) |ri| {
            const ring_outer: i32 = 10;
            const ring_inner: i32 = 8;
            const ring_cx = res_x + ring_outer;
            const ring_cy = res_center_y;
            canvas.fillRing(ring_cx, ring_cy, ring_inner, ring_outer, col_outline_variant);
            canvas.fillRing(ring_cx, ring_cy, ring_inner, ring_outer - 1, col_on_secondary_container);
            canvas.fillCircle(ring_cx, ring_cy, 3, col_on_secondary_container);
            if (self.font) |*f| {
                const tbl = @divTrunc(bar_h - f.lineHeight(), 2) + f.baselineOffset();
                text_mod.renderText(&canvas, f, "52", res_x + ring_outer * 2 + 2, tbl, col_on_layer1);
            }
            res_x += 42;
            if (ri < 2) res_x += 6;
        }

        if (center_mod_w > 200) {
            res_x += 6;
            const media_ring_cx = res_x + 10;
            canvas.fillRing(media_ring_cx, res_center_y, 8, 10, col_outline_variant);
            canvas.fillRing(media_ring_cx, res_center_y, 8, 9, col_on_secondary_container);
            canvas.fillCircle(media_ring_cx, res_center_y, 3, col_on_secondary_container);
            res_x += 24;
            const media_text_w = lc_x + center_mod_w - res_x - 5;
            if (media_text_w > 10 and self.font != null) {
                const f_ptr = &self.font.?;
                const tbl = @divTrunc(bar_h - f_ptr.lineHeight(), 2) + f_ptr.baselineOffset();
                text_mod.renderText(&canvas, f_ptr, "Song Title", res_x, tbl, col_on_layer1);
            }
        }

        // Middle center: Workspaces
        const mc_x = lc_x + center_mod_w + center_spacing;
        canvas.fillRoundedRect(mc_x, group_bg_y, ws_w, group_bg_h, group_radius, col_layer1);

        const ws_cell_y = bar_y + @divTrunc(bar_h - ws_btn_size, 2);
        const ws_start_x = mc_x + ws_bargroup_padding;

        const ws_display_count: usize = @min(@as(usize, @intCast(ws_count)), ctx.workspace_count);
        var occupied_buf: [16]bool = .{false} ** 16;
        var active_ws: usize = 0;
        for (0..ws_display_count) |wi| {
            const ws_info = &ctx.workspaces[wi];
            occupied_buf[wi] = ws_info.name_len > 0;
            if (ws_info.active) active_ws = wi;
        }
        if (ws_display_count == 0) {
            occupied_buf[0] = true;
            occupied_buf[1] = true;
            occupied_buf[2] = true;
            active_ws = 0;
        }
        const occupied = occupied_buf;
        const half_btn = @divTrunc(ws_btn_size, 2);

        var group_start: ?usize = null;
        for (0..6) |i| {
            const at_end = i == 5;
            if (!at_end and occupied[i]) {
                if (group_start == null) group_start = i;
            } else {
                if (group_start) |start| {
                    const end = i - 1;
                    const gx = ws_start_x + @as(i32, @intCast(start)) * ws_btn_size;
                    const gw = @as(i32, @intCast(end - start + 1)) * ws_btn_size;
                    if (start == end) {
                        canvas.fillCircle(gx + half_btn, ws_cell_y + half_btn, half_btn, col_secondary_container);
                    } else {
                        canvas.fillRoundedRect(gx, ws_cell_y, gw, ws_btn_size, half_btn, col_secondary_container);
                    }
                    group_start = null;
                }
            }
        }

        const ws_active_margin: i32 = 2;
        const ws_active_size = ws_btn_size - ws_active_margin * 2;
        {
            const active_x = ws_start_x + @as(i32, @intCast(active_ws)) * ws_btn_size + ws_active_margin;
            const active_y = ws_cell_y + ws_active_margin;
            canvas.fillRoundedRect(active_x, active_y, ws_active_size, ws_active_size, 9999, col_primary);
        }

        const dot_diam: i32 = 5;
        const dot_r = @divTrunc(dot_diam, 2);
        for (0..5) |i| {
            const btn_x = ws_start_x + @as(i32, @intCast(i)) * ws_btn_size;
            const dot_color = if (i == active_ws)
                col_on_primary
            else if (occupied[i])
                col_on_secondary_container
            else
                col_on_layer1_inactive;
            canvas.fillCircle(btn_x + half_btn, ws_cell_y + half_btn, dot_r, dot_color);
        }

        // Right center: Clock + Battery
        const rc_x = mc_x + ws_w + center_spacing;
        canvas.fillRoundedRect(rc_x, group_bg_y, center_mod_w, group_bg_h, group_radius, col_layer1);

        if (self.font) |*f| {
            const tbl = @divTrunc(bar_h - f.lineHeight(), 2) + f.baselineOffset();
            const clock_str = "12:34";
            const sep_str = "\u{2022}";
            const date_str = "Mon 6 Jul";
            const clock_w = text_mod.textWidth(f, clock_str);
            const sep_w = text_mod.textWidth(f, sep_str);
            const date_w = text_mod.textWidth(f, date_str);
            const total_clock_w = clock_w + 4 + sep_w + 4 + date_w;
            var cx = rc_x + @divTrunc(center_mod_w - total_clock_w, 2);
            text_mod.renderText(&canvas, f, clock_str, cx, tbl, col_on_layer1);
            cx += clock_w + 4;
            text_mod.renderText(&canvas, f, sep_str, cx, tbl, col_on_layer1);
            cx += sep_w + 4;
            text_mod.renderText(&canvas, f, date_str, cx, tbl, col_on_layer1);
        }

        const bat_w: i32 = 30;
        const bat_h: i32 = 18;
        const bat_x = rc_x + center_mod_w - bat_w - 8;
        const bat_y_pos = @divTrunc(bar_h - bat_h, 2);
        canvas.fillRoundedRect(bat_x, bat_y_pos, bat_w, bat_h, 9999, col_outline_variant);
        const bat_fill_w = @divTrunc((bat_w - 4) * 80, 100);
        canvas.fillRoundedRect(bat_x + 2, bat_y_pos + 2, bat_fill_w, bat_h - 4, 9999, col_on_secondary_container);
        if (self.font) |*f| {
            const tbl = bat_y_pos + @divTrunc(bat_h - f.lineHeight(), 2) + f.baselineOffset();
            text_mod.renderText(&canvas, f, "80%", bat_x + 2, tbl, col_on_layer1);
        }

        // ═══ RIGHT: RTL sidebar + system tray ═══
        var rtl_x: i32 = bar_w - screen_rounding;
        const rsb_icon_size: i32 = 19;
        const rsb_spacing: i32 = 15;
        const rsb_content_w = 6 * rsb_icon_size + 5 * rsb_spacing;
        const rsb_w = rsb_content_w + 20;
        const rsb_x = rtl_x - rsb_w;

        var icon_x = rsb_x + 10;
        const icon_cy = @divTrunc(bar_h, 2);
        for (0..6) |_| {
            canvas.fillRect(icon_x, icon_cy - @divTrunc(rsb_icon_size, 2), rsb_icon_size, rsb_icon_size, col_on_layer0);
            icon_x += rsb_icon_size + rsb_spacing;
        }

        rtl_x = rsb_x - 5;

        const tray_item_size: i32 = 20;
        const tray_overflow_size: i32 = 24;
        const tray_col_spacing: i32 = 15;
        const tray_total_w = tray_overflow_size + tray_col_spacing + 3 * tray_item_size + 2 * tray_col_spacing;
        const tray_x = rtl_x - tray_total_w;

        var tix = tray_x;
        canvas.fillCircle(tix + @divTrunc(tray_overflow_size, 2), icon_cy, @divTrunc(tray_overflow_size, 2), col_outline);
        tix += tray_overflow_size + tray_col_spacing;
        for (0..3) |_| {
            canvas.fillCircle(tix + @divTrunc(tray_item_size, 2), icon_cy, @divTrunc(tray_item_size, 2), col_outline);
            tix += tray_item_size + tray_col_spacing;
        }

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
    const screen_rounding: i32 = 23;
    const center_spacing: i32 = 4;
    const center_mod_w: i32 = if (bar_w > 1200) 360 else if (bar_w > 1000) 280 else 190;
    const ws_btn_size: i32 = 26;
    const ws_count: i32 = 5;
    const ws_bargroup_padding: i32 = 4;
    const ws_w = ws_btn_size * ws_count + ws_bargroup_padding * 2;
    const total_center = center_mod_w + center_spacing + ws_w + center_spacing + center_mod_w;
    const center_x = @divTrunc(bar_w - total_center, 2);

    const mc_x = center_x + center_mod_w + center_spacing;
    const ws_start_x = mc_x + ws_bargroup_padding;
    const ws_cell_y = @divTrunc(bar_h - ws_btn_size, 2);

    if (y >= ws_cell_y and y < ws_cell_y + ws_btn_size) {
        for (0..5) |i| {
            const btn_x = ws_start_x + @as(i32, @intCast(i)) * ws_btn_size;
            if (x >= btn_x and x < btn_x + ws_btn_size) {
                std.log.info("workspace {d} clicked", .{i});
                if (ctx.active_workspace) |aw| {
                    ctx.workspaces[aw].handle.deactivate();
                }
                if (i < ctx.workspace_count) {
                    ctx.workspaces[i].handle.activate();
                    ctx.active_workspace = i;
                }
                ctx.roundtrip();
                markAllDirty(ctx);
                return;
            }
        }
    }

    const sidebar_x = screen_rounding;
    const sidebar_btn_size: i32 = 30;
    if (x >= sidebar_x and x < sidebar_x + sidebar_btn_size and y >= 0 and y < bar_h) {
        std.log.info("sidebar button clicked", .{});
        return;
    }

    const rsb_icon_size: i32 = 19;
    const rsb_spacing: i32 = 15;
    const rsb_content_w = 6 * rsb_icon_size + 5 * rsb_spacing;
    const rsb_w = rsb_content_w + 20;
    const rsb_x = bar_w - rsb_w - screen_rounding;
    if (x >= rsb_x and x < bar_w - screen_rounding and y >= 0 and y < bar_h) {
        std.log.info("right sidebar clicked at x={d}", .{x});
        return;
    }

    if (ctx.active_toplevel) |at| {
        const aw_x = sidebar_x + sidebar_btn_size + 10;
        const aw_right = @divTrunc(bar_w, 2) - 80;
        if (x >= aw_x and x < aw_right and y >= 0 and y < bar_h) {
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
