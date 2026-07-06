const std = @import("std");
const posix = std.posix;

const Context = @import("wl.zig").Context;
const bar_mod = @import("bar.zig");
const config_mod = @import("config.zig");
const mpris_mod = @import("mpris.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.log.info("mist-bar starting", .{});

    config_mod.reload(allocator);

    var ctx: Context = undefined;
    try Context.init(allocator, &ctx);
    defer ctx.deinit();

    if (ctx.seat) |s| {
        s.setListener(*Context, bar_mod.seatListener, &ctx);
    }

    // Roundtrip to get seat capabilities + initial toplevel/workspace state
    // Must happen AFTER seat listener is set (see wl.zig init note)
    ctx.roundtrip();
    std.log.info("outputs: {d}", .{ctx.output_count});

    // MPRIS media player (D-Bus via basu)
    var mpris = mpris_mod.MprisPlayer.init() catch |err| blk: {
        std.log.warn("mpris init: {s}", .{@errorName(err)});
        break :blk mpris_mod.MprisPlayer{};
    };
    mpris.query();
    ctx.mpris = &mpris;

    for (0..ctx.output_count) |i| {
        bar_mod.initOutput(&ctx, i) catch |err| {
            std.log.warn("output {d}: {s}", .{ i, @errorName(err) });
        };
    }

    ctx.roundtrip();
    bar_mod.drawOutputs(&ctx, &mpris);

    // Initialize media controls popup (hidden off-screen until shown)
    ctx.media_popup.init(&ctx, 0, allocator) catch |err| {
        std.log.warn("media popup init: {s}", .{@errorName(err)});
    };

    const wayland_fd = ctx.getFd();
    var mpris_tick: u32 = 0;

    while (ctx.running) {
        const dbus_fd = mpris.getFd();
        var fds: [2]posix.pollfd = undefined;
        fds[0] = .{ .fd = wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = if (dbus_fd >= 0) dbus_fd else wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        const nfds: u16 = if (dbus_fd >= 0) 2 else 1;

        _ = posix.poll(fds[0..nfds], 100) catch |err| {
            std.log.warn("poll: {s}", .{@errorName(err)});
            break;
        };

        if (fds[0].revents & posix.POLL.IN != 0) {
            ctx.dispatch();
        }

        if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
            std.log.warn("connection lost", .{});
            break;
        }

        if (dbus_fd >= 0 and fds[1].revents & posix.POLL.IN != 0) {
            mpris.process();
        }

        // Periodic MPRIS re-query (~1s at 100ms poll intervals)
        mpris_tick += 1;
        if (mpris_tick >= 10) {
            mpris_tick = 0;
            mpris.query();
        }

        // Periodic resource update (~3s at 100ms poll intervals)
        ctx.resource_counter += 1;
        if (ctx.resource_counter >= 30) {
            ctx.resource_counter = 0;
            config_mod.updateResources(&ctx.resources);
            ctx.bar_dirty = true;
        }

        // Redraw when workspace/toplevel state changed
        if (mpris.changed) {
            ctx.bar_dirty = true;
            ctx.media_popup.markDirty();
            mpris.changed = false;
        }
        if (ctx.bar_dirty) {
            bar_mod.markAllDirty(&ctx);
            ctx.bar_dirty = false;
        }
        bar_mod.drawOutputs(&ctx, &mpris);

        // Draw media controls popup if visible (only commits when needs_redraw)
        if (ctx.media_popup.visible) {
            const was_dirty = ctx.media_popup.needs_redraw;
            ctx.media_popup.draw(&ctx);
            if (was_dirty) ctx.media_popup.commit(&ctx);
        }
    }

    mpris.deinit();
    bar_mod.deinitOutputs();
    std.log.info("shutdown", .{});
}
