const std = @import("std");
const posix = std.posix;

const Context = @import("wl.zig").Context;
const input = @import("input.zig");
const output_mod = @import("output.zig");
const config_mod = @import("config.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.log.info("mist-bar starting", .{});

    config_mod.reload(allocator);

    var ctx: Context = undefined;
    try Context.init(allocator, &ctx);
    defer ctx.deinit();

    if (ctx.seat) |s| {
        s.setListener(*Context, input.seatListener, &ctx);
    }

    ctx.roundtrip();
    std.log.info("outputs: {d}", .{ctx.output_count});

    for (0..ctx.output_count) |i| {
        output_mod.initOutput(&ctx, i) catch |err| {
            std.log.warn("output {d}: {s}", .{ i, @errorName(err) });
        };
    }

    ctx.roundtrip();
    output_mod.drawOutputs(&ctx);

    const wayland_fd = ctx.getFd();

    while (ctx.running) {
        var fds: [1]posix.pollfd = .{
            .{ .fd = wayland_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        _ = posix.poll(&fds, 100) catch |err| {
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

        // Only redraw if any bar was marked dirty by a configure event
        output_mod.drawOutputs(&ctx);
    }

    output_mod.deinit();
    std.log.info("shutdown", .{});
}
