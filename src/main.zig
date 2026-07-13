const std = @import("std");
const posix = std.posix;
const cc = @import("c.zig").c;
const bc = @import("basu_c.zig").c;

const Context = @import("wl.zig").Context;
const bar_mod = @import("bar.zig");
const config_mod = @import("config.zig");
const mpris_mod = @import("mpris.zig");
const notif_mod = @import("notifications.zig");
const ipc_handlers = @import("ipc_handlers.zig");
const ipc_mod = @import("ipc.zig");
const notif_popup_mod = @import("notification_popup.zig");
const osd_mod = @import("osd.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    const args = init.args.vector;

    // Check for subcommands
    if (args.len >= 2) {
        const cmd = std.mem.sliceTo(args[1], 0);
        if (std.mem.eql(u8, cmd, "msg")) {
            if (args.len < 3) {
                try ipc_mod.runClient(&.{ "--help" });
                return;
            }
            const sub = std.mem.sliceTo(args[2], 0);
            if (std.mem.eql(u8, sub, "call")) {
                if (args.len < 4) {
                    try ipc_mod.runClient(&.{ "--help" });
                } else {
                    try ipc_mod.runClient(args[3..]);
                }
            } else {
                // bare command (backward compat)
                try ipc_mod.runClient(args[2..]);
            }
            return;
        }
        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            const help =
                \\mist — Wayland bar and shell
                \\
                \\Usage:
                \\  mist                        Run the bar/shell daemon
                \\  mist msg call <command>     Send IPC command to running instance
                \\  mist msg <command>          (shorthand, same as above)
                \\  mist --help                 Show this help
                \\
            ;
            _ = std.c.write(1, @as([*]const u8, help), help.len);
            return;
        }
        std.log.err("unknown subcommand '{s}'. Try: mist --help", .{cmd});
        std.process.exit(1);
    }

    std.log.info("mist starting", .{});

    var ctx: Context = undefined;
    try Context.init(allocator, &ctx);
    defer ctx.deinit();

    if (ctx.seat) |s| {
        s.setListener(*Context, bar_mod.seatListener, &ctx);
    }

    // Roundtrip after seat listener (see wl.zig init)
    ctx.roundtrip();
    std.log.info("outputs: {d}, keyboard={any}", .{ ctx.output_count, ctx.keyboard });

    // MPRIS via basu D-Bus
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

    // Initial audio (tracked locally after this)
    config_mod.readAudioState(&ctx.resources);

    // Media controls popup
    ctx.media_popup.init(&ctx, 0, allocator) catch |err| {
        std.log.warn("media popup init: {s}", .{@errorName(err)});
    };

    // Notification toast popup
    ctx.notification_popup.init(&ctx, 0, allocator) catch |err| {
        std.log.warn("notif popup init: {s}", .{@errorName(err)});
    };

    // Notification server (org.freedesktop.Notifications)
    ctx.notifications.init();

    // OSD — volume / mic vertical sliders
    ctx.osd.init(&ctx, 0, allocator) catch |err| {
        std.log.warn("osd init: {s}", .{@errorName(err)});
    };

    // Sidebar init
    ctx.sidebar.init(&ctx, 0, allocator) catch |err| {
        std.log.warn("sidebar init: {s}", .{@errorName(err)});
    };

    // IPC server init
    ctx.ipc.init();
    const ctx_ptr: *anyopaque = @ptrCast(&ctx);
    ctx.ipc.registerHandler("status", ipc_handlers.handleStatus, ctx_ptr, "status", "Print current state as JSON");
    ctx.ipc.registerHandler("volume-get", ipc_handlers.handleVolumeGet, ctx_ptr, "volume-get", "Get audio volume");
    ctx.ipc.registerHandler("volume-up", ipc_handlers.handleVolumeUp, ctx_ptr, "volume-up", "Increase volume by 5%");
    ctx.ipc.registerHandler("volume-down", ipc_handlers.handleVolumeDown, ctx_ptr, "volume-down", "Decrease volume by 5%");
    ctx.ipc.registerHandler("volume-mute", ipc_handlers.handleVolumeMute, ctx_ptr, "volume-mute", "Mute audio");
    ctx.ipc.registerHandler("volume-unmute", ipc_handlers.handleVolumeUnmute, ctx_ptr, "volume-unmute", "Unmute audio");
    ctx.ipc.registerHandler("volume-toggle", ipc_handlers.handleVolumeToggle, ctx_ptr, "volume-toggle", "Toggle mute");
    ctx.ipc.registerHandler("mic-get", ipc_handlers.handleMicGet, ctx_ptr, "mic-get", "Get microphone volume");
    ctx.ipc.registerHandler("mic-up", ipc_handlers.handleMicUp, ctx_ptr, "mic-up", "Increase mic volume by 5%");
    ctx.ipc.registerHandler("mic-down", ipc_handlers.handleMicDown, ctx_ptr, "mic-down", "Decrease mic volume by 5%");
    ctx.ipc.registerHandler("mic-mute", ipc_handlers.handleMicMute, ctx_ptr, "mic-mute", "Mute microphone");
    ctx.ipc.registerHandler("mic-unmute", ipc_handlers.handleMicUnmute, ctx_ptr, "mic-unmute", "Unmute microphone");
    ctx.ipc.registerHandler("mic-toggle", ipc_handlers.handleMicToggle, ctx_ptr, "mic-toggle", "Toggle mic mute");
    ctx.ipc.registerHandler("media-play-pause", ipc_handlers.handleMediaPlayPause, ctx_ptr, "media-play-pause", "Toggle play/pause");
    ctx.ipc.registerHandler("media-next", ipc_handlers.handleMediaNext, ctx_ptr, "media-next", "Next track");
    ctx.ipc.registerHandler("media-previous", ipc_handlers.handleMediaPrevious, ctx_ptr, "media-previous", "Previous track");
    ctx.ipc.registerHandler("workspace-switch", ipc_handlers.handleWorkspaceSwitch, ctx_ptr, "workspace-switch <N>", "Switch to workspace N");
    ctx.ipc.registerHandler("workspace-next", ipc_handlers.handleWorkspaceNext, ctx_ptr, "workspace-next", "Next workspace");
    ctx.ipc.registerHandler("workspace-previous", ipc_handlers.handleWorkspacePrevious, ctx_ptr, "workspace-previous", "Previous workspace");
    ctx.ipc.registerHandler("sidebar-toggle", ipc_handlers.handleSidebarToggle, ctx_ptr, "sidebar-toggle", "Toggle sidebar");
    ctx.ipc.registerHandler("sidebar-show", ipc_handlers.handleSidebarShow, ctx_ptr, "sidebar-show", "Show sidebar");
    ctx.ipc.registerHandler("sidebar-hide", ipc_handlers.handleSidebarHide, ctx_ptr, "sidebar-hide", "Hide sidebar");
    ctx.ipc.registerHandler("sidebar-get", ipc_handlers.handleSidebarGet, ctx_ptr, "sidebar-get", "Get sidebar visibility");
    ctx.ipc.registerHandler("popup-toggle", ipc_handlers.handlePopupToggle, ctx_ptr, "popup-toggle", "Toggle media popup");
    ctx.ipc.registerHandler("popup-show", ipc_handlers.handlePopupShow, ctx_ptr, "popup-show", "Show media popup");
    ctx.ipc.registerHandler("popup-hide", ipc_handlers.handlePopupHide, ctx_ptr, "popup-hide", "Hide media popup");
    ctx.ipc.registerHandler("notification-count", ipc_handlers.handleNotificationCount, ctx_ptr, "notification-count", "Count notifications");
    ctx.ipc.registerHandler("notification-status", ipc_handlers.handleNotificationStatus, ctx_ptr, "notification-status", "Notification status summary");
    ctx.ipc.registerHandler("notification-dismiss", ipc_handlers.handleNotificationDismiss, ctx_ptr, "notification-dismiss <id>", "Dismiss notification by ID");
    ctx.ipc.registerHandler("notification-dismiss-all", ipc_handlers.handleNotificationDismissAll, ctx_ptr, "notification-dismiss-all", "Dismiss all notifications");
    ctx.ipc.registerHandler("notification-mark-all-read", ipc_handlers.handleNotificationMarkAllRead, ctx_ptr, "notification-mark-all-read", "Mark all notifications read");
    ctx.ipc.registerHandler("notification-dnd-set", ipc_handlers.handleNotificationDndSet, ctx_ptr, "notification-dnd-set <on|off>", "Set DND state");
    ctx.ipc.registerHandler("notification-dnd-toggle", ipc_handlers.handleNotificationDndToggle, ctx_ptr, "notification-dnd-toggle", "Toggle DND");
    ctx.ipc.registerHandler("notification-dnd-status", ipc_handlers.handleNotificationDndStatus, ctx_ptr, "notification-dnd-status", "Get DND state");
    ctx.ipc.registerHandler("clock", ipc_handlers.handleClock, ctx_ptr, "clock", "Print current time");
    ctx.ipc.registerHandler("resources", ipc_handlers.handleResources, ctx_ptr, "resources", "Print system resource usage");

    const wayland_fd = ctx.getFd();
    var last_mpris_query_ms: i64 = 0;
    var last_resource_ms: i64 = 0;
    var last_notif_draw_ms: i64 = 0;
    var last_media_draw_ms: i64 = 0;

    // Binary auto-reload: record mtime of running binary
    var binary_mtime: i64 = 0;
    {
        var st: cc.struct_stat = undefined;
        if (cc.stat("/proc/self/exe", &st) == 0)
            binary_mtime = @as(i64, st.st_mtim.tv_sec) * 1_000_000_000 + @as(i64, st.st_mtim.tv_nsec);
    }


    while (ctx.running) {
        const dbus_fd = mpris.getFd();
        const notif_fd = ctx.notifications.getFd();
        const ipc_fd = ctx.ipc.getFd();
        var fds: [4]posix.pollfd = undefined;
        fds[0] = .{ .fd = wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = if (dbus_fd >= 0) dbus_fd else wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        fds[2] = .{ .fd = if (notif_fd >= 0) notif_fd else wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        fds[3] = .{ .fd = if (ipc_fd >= 0) ipc_fd else wayland_fd, .events = posix.POLL.IN, .revents = 0 };
        const nfds: u16 = if (ipc_fd >= 0) 4 else if (notif_fd >= 0) 3 else if (dbus_fd >= 0) 2 else 1;

        const timed_out = blk: {
            // 16ms (60fps) while animating OR while media is playing (smooth
            // wave). 100ms otherwise to stay idle-light.
            const poll_ms: i32 = if (ctx.sidebar.animating or (mpris.has_player and mpris.status == .playing)) 16 else 100;
            const n = posix.poll(fds[0..nfds], poll_ms) catch |err| {
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

        if (notif_fd >= 0 and fds[2].revents & posix.POLL.IN != 0) {
            ctx.notifications.process();
            if (ctx.notifications.changed) {
                ctx.notifications.changed = false;
                ctx.bar_dirty = true;
                ctx.sidebar.markDirty();

                // Show notification panel when there are popups
                if (ctx.notifications.popup_len > 0) {
                    if (!ctx.notification_popup.has_content) {
                        ctx.notification_popup.show(&ctx);
                    }
                    ctx.notification_popup.needs_redraw = true;
                } else {
                    if (ctx.notification_popup.has_content) {
                        ctx.notification_popup.hide();
                    }
                }
            }
        }
        // Flush outgoing D-Bus messages when socket is writable
        if (notif_fd >= 0 and fds[2].revents & posix.POLL.OUT != 0) {
            if (ctx.notifications.bus) |b| {
                _ = bc.sd_bus_flush(b);
            }
        }

        if (ipc_fd >= 0 and fds[3].revents & posix.POLL.IN != 0) {
            ctx.ipc.dispatch();
        }

        // MPRIS re-query every 200ms
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        const now_ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        ctx.now_ms = now_ms;
        if (now_ms - last_mpris_query_ms >= 200) {
            last_mpris_query_ms = now_ms;
            mpris.query();
            // Only reset advance timer when D-Bus corrected position (new track or seek).
            // Don't reset during normal playback — it kills local wall-clock advancement.
            if (mpris.status != .playing) {
                mpris.last_pos_advance_ms = now_ms;
            }
        }

        // Async art loading
        mpris.tickArtLoading();

        // Detect volume/mic changes via IPC and show OSD
        if (ctx.resources.last_vol_change_ms > 0 and now_ms - ctx.resources.last_vol_change_ms < 200) {
            ctx.osd.setVolume(&ctx, ctx.resources.audio_volume, ctx.resources.audio_muted);
        }
        if (ctx.resources.last_mic_change_ms > 0 and now_ms - ctx.resources.last_mic_change_ms < 200) {
            ctx.osd.setVolume(&ctx, ctx.resources.mic_volume, ctx.resources.mic_muted);
        }

        // Resources update every 3s; also check for binary rebuild
        if (now_ms - last_resource_ms >= 3000) {
            last_resource_ms = now_ms;
            config_mod.updateResources(&ctx.resources);
            ctx.bar_dirty = true;

            // Auto-restart if binary was rebuilt (hot reload)
            var st: cc.struct_stat = undefined;
            if (cc.stat("/proc/self/exe", &st) == 0) {
                const mtime = @as(i64, st.st_mtim.tv_sec) * 1_000_000_000 + @as(i64, st.st_mtim.tv_nsec);
                if (binary_mtime != 0 and mtime != binary_mtime) {
                    std.log.info("binary updated — restarting", .{});
                    const pid = cc.fork();
                    if (pid == 0) {
                        var sleep_ts = std.mem.zeroes(cc.struct_timespec);
                        sleep_ts.tv_nsec = 500_000_000; // 500ms
                        _ = cc.nanosleep(&sleep_ts, null);
                        // Build argv for exec: ["mist", NULL]
                        var arg0: [128:0]u8 = undefined;
                        @memcpy(arg0[0..4], "mist");
                        arg0[4] = 0;
                        var argv = [_:null][*c]u8{ @as([*c]u8, @ptrCast(&arg0)), null };
                        _ = cc.execv("/proc/self/exe", &argv);
                        cc._exit(1);
                    }
                    cc._exit(0);
                }
            }
        }

        // Auto-dismiss expired notification popups
        ctx.notifications.timeoutExpiredPopups(now_ms);
        if (ctx.notifications.changed) {
            ctx.notifications.changed = false;
            ctx.bar_dirty = true;
            ctx.sidebar.markDirty();
            if (ctx.notifications.popup_len > 0 and !ctx.notification_popup.has_content) {
                ctx.notification_popup.show(&ctx);
            } else if (ctx.notifications.popup_len == 0 and ctx.notification_popup.has_content) {
                ctx.notification_popup.hide();
            } else if (ctx.notification_popup.has_content) {
                ctx.notification_popup.needs_redraw = true;
            }
        }

        // Redraw on state changes
        if (mpris.changed) {
            ctx.bar_dirty = true;
            ctx.media_popup.markDirty();
            // Reset advance timer so local clock syncs with new track's D-Bus position
            mpris.last_pos_advance_ms = 0;
            mpris.changed = false;
        }
        // Redraw on art load
        if (mpris.art_loaded_changed) {
            mpris.art_loaded_changed = false;
            ctx.media_popup.markDirty();
        }
        if (ctx.bar_dirty) {
            bar_mod.markAllDirty(&ctx);
            ctx.bar_dirty = false;
        }
        bar_mod.drawOutputs(&ctx, &mpris);

        // Position advance on poll timeout — use elapsed wall-clock time
        // instead of fixed 100ms per tick, to avoid over-advancing during
        // sidebar animation (16ms poll)
        if (timed_out) {
            if (mpris.has_player and mpris.status == .playing) {
                if (mpris.last_pos_advance_ms == 0) {
                    mpris.last_pos_advance_ms = now_ms;
                }
                const elapsed_us = (now_ms - mpris.last_pos_advance_ms) * 1000;
                mpris.position += elapsed_us;
                mpris.last_pos_advance_ms = now_ms;
                if (mpris.length > 0 and mpris.position > mpris.length) {
                    mpris.position = mpris.length;
                }
            }
        }
        // Always redraw progress when playing — wave animation needs continuous repaint
        if (mpris.has_player and mpris.status == .playing) {
            ctx.media_popup.markProgressDirty();
        }

        // Draw popup when needed (throttled to ~10fps for progress bar)
        if (ctx.media_popup.visible and ctx.media_popup.needs_redraw) {
            const since_last_media_draw = now_ms - last_media_draw_ms;
            if (since_last_media_draw >= 100) {
                last_media_draw_ms = now_ms;
                ctx.media_popup.draw(&ctx);
                ctx.media_popup.commit(&ctx);
            }
        }

        // Draw notification panel — redraw at ~10fps for progress ring (not every frame)
        if (ctx.notification_popup.has_content) {
            const since_last_notif_draw = now_ms - last_notif_draw_ms;
            if (since_last_notif_draw >= 100) {
                last_notif_draw_ms = now_ms;
                ctx.notification_popup.drawAll(&ctx);
            }
        }

        // Animate sidebar slide
        ctx.sidebar.animate(&ctx);

        // Draw sidebar when needed
        if (ctx.sidebar.visible and (ctx.sidebar.needs_redraw or ctx.sidebar.needs_full_redraw)) {
            ctx.sidebar.draw(&ctx);
            ctx.sidebar.commit(&ctx);
        }

        // OSD auto-hide timer
        ctx.osd.tick(&ctx);

        // Draw OSD when visible
        if (ctx.osd.visible and ctx.osd.needs_redraw) {
            ctx.osd.draw(&ctx);
            ctx.osd.commit(&ctx);
        }

        // Single flush: all surface commits sent atomically to compositor
        ctx.flush();
    }

    mpris.deinit();
    bar_mod.deinitOutputs();
    std.log.info("shutdown", .{});
}
