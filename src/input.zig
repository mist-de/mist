const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Context = @import("wl.zig").Context;
const CursorShape = @import("wl.zig").CursorShape;
const output_mod = @import("output.zig");

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
    // Find which bar this click is on
    const bar_h: i32 = 40;
    const bar_w: i32 = ctx.outputs[0].mode_w;

    // Workspace button area: center section, middle group
    // Recalculate layout matching bar.zig
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

    // Check workspace clicks
    if (y >= ws_cell_y and y < ws_cell_y + ws_btn_size) {
        for (0..5) |i| {
            const btn_x = ws_start_x + @as(i32, @intCast(i)) * ws_btn_size;
            if (x >= btn_x and x < btn_x + ws_btn_size) {
                std.log.info("workspace {d} clicked", .{i});
                // Activate workspace via ext_workspace_manager_v1
                if (ctx.active_workspace) |aw| {
                    // Deactivate current
                    ctx.workspaces[aw].handle.deactivate();
                }
                if (i < ctx.workspace_count) {
                    ctx.workspaces[i].handle.activate();
                    ctx.active_workspace = i;
                }
                ctx.roundtrip();
                output_mod.markAllDirty(ctx);
                return;
            }
        }
    }

    // Check left sidebar button click (app launcher area)
    const sidebar_x = screen_rounding;
    const sidebar_btn_size: i32 = 30;
    if (x >= sidebar_x and x < sidebar_x + sidebar_btn_size and y >= 0 and y < bar_h) {
        std.log.info("sidebar button clicked", .{});
        return;
    }

    // Check right sidebar button clicks (system tray area)
    const rsb_icon_size: i32 = 19;
    const rsb_spacing: i32 = 15;
    const rsb_content_w = 6 * rsb_icon_size + 5 * rsb_spacing;
    const rsb_w = rsb_content_w + 20;
    const rsb_x = bar_w - rsb_w - screen_rounding;
    if (x >= rsb_x and x < bar_w - screen_rounding and y >= 0 and y < bar_h) {
        std.log.info("right sidebar clicked at x={d}", .{x});
        return;
    }

    // Click on active window area -> activate the focused toplevel
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
