const std = @import("std");
const posix = std.posix;

const Wayland = @import("wayland.zig");
const wl = Wayland.wl;
const Output = @import("output.zig").Output;
const Config = @import("config.zig");
const text = @import("shell/render/text.zig");
const geo = @import("geo.zig");
const battery = @import("battery.zig");
const volume = @import("volume.zig");

const log = std.log.scoped(.main);

var global_font: ?text.Font = null;

pub fn getGlobalFont() ?*text.Font {
    if (global_font) |*f| return f;
    return null;
}

pub fn getGlobalSysInfo() ?*anyopaque {
    return null;
}

pub fn initGlobalSysInfo() void {}

pub fn getGlobalNetworkManager() ?*anyopaque {
    return null;
}

pub fn initGlobalNetworkManager() void {}

pub fn getGlobalMpris() ?*anyopaque {
    return null;
}

pub fn initGlobalMpris() void {}

pub fn getGlobalSystemTray() ?*anyopaque {
    return null;
}

pub fn initGlobalSystemTray() void {}

pub fn getGlobalPipeWire() ?*anyopaque {
    return null;
}

pub fn initGlobalPipeWire() void {}

pub fn getGlobalAlbumArt() ?*anyopaque {
    return null;
}

pub fn setGlobalAlbumArt(_: ?*anyopaque, _: u64) void {}

pub fn getGlobalAlbumArtUrlHash() u64 {
    return 0;
}

pub fn textSystemProvider() ?*anyopaque {
    return null;
}

fn initFont() !text.Font {
    for ([_][:0]const u8{
        "/run/current-system/sw/share/X11/fonts/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
    }) |path| {
        const c = struct { extern "c" fn access(p: [*:0]const u8, m: c_int) c_int; };
        if (c.access(path.ptr, 0) == 0) {
            return text.Font.init(path, 14);
        }
    }
    return error.FontNotFound;
}

pub const App = struct {
    wayland: Wayland,

    fn init(self: *App) !void {
        try self.wayland.init();
        global_font = initFont() catch null;
        Config.initGlobal(std.heap.page_allocator);
        battery.init();
        volume.init();
    }

    fn deinit(self: *App) void {
        volume.deinit();
        battery.deinit();
        self.wayland.deinit();
        if (global_font) |*f| f.deinit();
        Config.deinitGlobal();
    }

    fn run(self: *App) !void {
        var poll_count: u64 = 0;
        while (self.wayland.running) {
            _ = self.wayland.display.flush();

            var fds: [2]posix.pollfd = undefined;
            var nfds: usize = 1;
            fds[0] = .{ .fd = self.wayland.display.getFd(), .events = posix.POLL.IN, .revents = 0 };

            const battery_fd = battery.getFd();
            var battery_fd_index: ?usize = null;
            if (battery_fd >= 0) {
                battery_fd_index = nfds;
                fds[nfds] = .{ .fd = battery_fd, .events = posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }

            _ = posix.poll(fds[0..nfds], 100) catch break;

            if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) break;

            if (battery_fd_index) |idx| {
                if (fds[idx].revents & posix.POLL.IN != 0) {
                    battery.process();
                    for (self.wayland.outputs[0..self.wayland.output_count]) |*output| {
                        output.full_redraw = true;
                        output.requestFrame();
                    }
                }
            }

            // Periodic volume refresh (~5 seconds)
            poll_count += 1;
            if (poll_count % 50 == 0) {
                volume.refresh();
                for (self.wayland.outputs[0..self.wayland.output_count]) |*output| {
                    output.full_redraw = true;
                    output.requestFrame();
                }
            }

            if (fds[0].revents & posix.POLL.IN != 0) {
                switch (self.wayland.dispatch()) {
                    .SUCCESS => {},
                    .CONNRESET, .INVAL => break,
                    else => break,
                }
            }
        }
    }
};

pub fn main() !void {
    var app: App = undefined;
    try app.init();
    defer app.deinit();
    try app.run();
}
