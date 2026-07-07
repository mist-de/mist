const std = @import("std");
const posix = std.posix;

const Context = @import("wl.zig").Context;
const bar_mod = @import("bar.zig");
const config_mod = @import("config.zig");
const mpris_mod = @import("mpris.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.log.info("mist-bar starting", .{});

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
    var last_mpris_query_ms: i64 = 0;
    var last_resource_ms: i64 = 0;


    while (ctx.running) {
        const dbus_fd = mpris.getFd();
        var fds: [2]posix.pollfd = undefined;
        fds[0] = .{ .fd = wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = if (dbus_fd >= 0) dbus_fd else wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        const nfds: u16 = if (dbus_fd >= 0) 2 else 1;

        const timed_out = blk: {
            const n = posix.poll(fds[0..nfds], 100) catch |err| {
                std.log.warn("poll: {s}", .{@errorName(err)});
                break :blk false;
            };
            break :blk (n == 0);
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

        // Time-based MPRIS re-query (every 200ms)
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        const now_ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        if (now_ms - last_mpris_query_ms >= 200) {
            last_mpris_query_ms = now_ms;
            mpris.query();
        }

        // Check async art loading (non-blocking, each iteration)
        mpris.tickArtLoading();

        // Time-based resource update (every 3s)
        if (now_ms - last_resource_ms >= 3000) {
            last_resource_ms = now_ms;
            config_mod.updateResources(&ctx.resources);
            ctx.bar_dirty = true;
        }

        // Redraw when workspace/toplevel state changed
        if (mpris.changed) {
            ctx.bar_dirty = true;
            ctx.media_popup.markDirty();
            mpris.changed = false;
        }
        // Redraw when async art load completes
        if (mpris.art_loaded_changed) {
            mpris.art_loaded_changed = false;
            ctx.media_popup.markDirty();
        }
        if (ctx.bar_dirty) {
            bar_mod.markAllDirty(&ctx);
            ctx.bar_dirty = false;
        }
        bar_mod.drawOutputs(&ctx, &mpris);

        // Advance position ONLY on poll timeout (matches real-time)
        if (timed_out) {
            if (mpris.has_player and mpris.status == .playing) {
                mpris.position += 100000; // 100ms in μs
                if (mpris.length > 0 and mpris.position > mpris.length) {
                    mpris.position = mpris.length;
                }
                ctx.media_popup.markProgressDirty();
            }
        }

        // Draw media controls popup (only when something actually changed)
        if (ctx.media_popup.visible and ctx.media_popup.needs_redraw) {
            ctx.media_popup.draw(&ctx);
            ctx.media_popup.commit(&ctx);
        }
    }

    mpris.deinit();
    bar_mod.deinitOutputs();
    std.log.info("shutdown", .{});
}
