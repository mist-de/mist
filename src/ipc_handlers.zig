const std = @import("std");
const Context = @import("wl.zig").Context;
const config_mod = @import("config.zig");
const bar_mod = @import("bar.zig");

var resp_buf: [4096]u8 = undefined;

fn ctx(c: *anyopaque) *Context {
    return @ptrCast(@alignCast(c));
}

fn setVolume(context: *Context, val: f32) void {
    config_mod.setVolume(&context.resources, val);
    bar_mod.markAllDirty(context);
}

fn setMicVolume(context: *Context, val: f32) void {
    config_mod.setMicVolume(&context.resources, val);
    bar_mod.markAllDirty(context);
}

// ── Status ────────────────────────────────────────────────────────────────────

pub fn handleStatus(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    const mpris = context.mpris orelse return "{\n  \"mpris\": null\n}\n";

    const result = build: {
        var pos: usize = 0;
        const header = "{\n";
        if (pos + header.len >= resp_buf.len) break :build "{}\n";
        @memcpy(resp_buf[pos..][0..header.len], header);
        pos += header.len;

        // Workspace
        const ws = if (context.active_workspace) |aw| blk: {
            const end = std.mem.indexOfScalar(u8, &context.workspaces[aw].name, 0) orelse context.workspaces[aw].name.len;
            break :blk context.workspaces[aw].name[0..end];
        } else "none";
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"workspace\": \"{s}\",\n", .{ws}) catch break :build "{}\n").len;

        // Active window
        if (context.active_toplevel) |at| {
            const title = std.mem.sliceTo(&context.toplevels[at].title, 0);
            const app_id = std.mem.sliceTo(&context.toplevels[at].app_id, 0);
            pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"window\": \"{s}\",\n  \"app_id\": \"{s}\",\n", .{ title, app_id }) catch break :build "{}\n").len;
        }

        // MPRIS
        pos += (std.fmt.bufPrint(resp_buf[pos..],
            \\  "mpris": {{
            \\    "player": "{s}",
            \\    "title": "{s}",
            \\    "artist": "{s}",
            \\    "status": "{s}",
            \\    "position": {},
            \\    "length": {},
            \\    "has_art": {}
            \\  }},
        , .{
            if (mpris.has_player) mpris.name else "",
            mpris.title,
            mpris.artist,
            @tagName(mpris.status),
            mpris.position,
            mpris.length,
            mpris.art_has,
        }) catch break :build "{}\n").len;

        // Audio
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"audio_volume\": {d:.2},\n", .{context.resources.audio_volume}) catch break :build "{}\n").len;
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"audio_muted\": {},\n", .{context.resources.audio_muted}) catch break :build "{}\n").len;
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"mic_volume\": {d:.2},\n", .{context.resources.mic_volume}) catch break :build "{}\n").len;
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"mic_muted\": {},\n", .{context.resources.mic_muted}) catch break :build "{}\n").len;

        // Battery
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"battery_pct\": {},\n", .{context.resources.battery_pct}) catch break :build "{}\n").len;

        // Notifications
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"notifications\": {},\n", .{context.notifications.list_len}) catch break :build "{}\n").len;
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"unread\": {},\n", .{context.notifications.unread}) catch break :build "{}\n").len;

        // Sidebar / popup
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"sidebar_open\": {},\n", .{context.sidebar_open}) catch break :build "{}\n").len;
        pos += (std.fmt.bufPrint(resp_buf[pos..], "  \"media_popup\": {},\n", .{context.media_popup.visible}) catch break :build "{}\n").len;

        const footer = "}\n";
        if (pos + footer.len >= resp_buf.len) break :build "{}\n";
        @memcpy(resp_buf[pos..][0..footer.len], footer);
        break :build resp_buf[0 .. pos + footer.len];
    };
    return result;
}

// ── Volume ────────────────────────────────────────────────────────────────────

pub fn handleVolumeGet(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const n = std.fmt.bufPrint(&resp_buf, "{d:.2}\n", .{ctx(c).resources.audio_volume}) catch return "error: buf\n";
    return resp_buf[0..n.len];
}

pub fn handleVolumeMute(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    setVolume(ctx(c), 0);
    return "ok\n";
}

pub fn handleVolumeUnmute(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    setVolume(context, if (context.resources.audio_volume < 0.01) 0.5 else context.resources.audio_volume);
    return "ok\n";
}

pub fn handleVolumeUp(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    setVolume(context, @min(2.0, context.resources.audio_volume + 0.05));
    return "ok\n";
}

pub fn handleVolumeDown(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    setVolume(context, @max(0, context.resources.audio_volume - 0.05));
    return "ok\n";
}

pub fn handleVolumeToggle(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    if (context.resources.audio_muted or context.resources.audio_volume < 0.01) {
        setVolume(context, 0.5);
    } else {
        setVolume(context, 0);
    }
    return "ok\n";
}

// ── Microphone ────────────────────────────────────────────────────────────────

pub fn handleMicGet(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const n = std.fmt.bufPrint(&resp_buf, "{d:.2}\n", .{ctx(c).resources.mic_volume}) catch return "error: buf\n";
    return resp_buf[0..n.len];
}

pub fn handleMicMute(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    setMicVolume(ctx(c), 0);
    return "ok\n";
}

pub fn handleMicUnmute(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    setMicVolume(context, if (context.resources.mic_volume < 0.01) 0.5 else context.resources.mic_volume);
    return "ok\n";
}

pub fn handleMicUp(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    setMicVolume(context, @min(2.0, context.resources.mic_volume + 0.05));
    return "ok\n";
}

pub fn handleMicDown(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    setMicVolume(context, @max(0, context.resources.mic_volume - 0.05));
    return "ok\n";
}

pub fn handleMicToggle(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    if (context.resources.mic_muted or context.resources.mic_volume < 0.01) {
        setMicVolume(context, 0.5);
    } else {
        setMicVolume(context, 0);
    }
    return "ok\n";
}

// ── Media (MPRIS) ─────────────────────────────────────────────────────────────

fn handleMediaAction(c: *anyopaque, action: enum { play_pause, next, prev }) []const u8 {
    const context = ctx(c);
    if (context.mpris) |mpris| {
        switch (action) {
            .play_pause => mpris.playPause(),
            .next => mpris.next(),
            .prev => mpris.previous(),
        }
    }
    return "ok\n";
}

pub fn handleMediaPlayPause(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    return handleMediaAction(c, .play_pause);
}

pub fn handleMediaNext(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    return handleMediaAction(c, .next);
}

pub fn handleMediaPrevious(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    return handleMediaAction(c, .prev);
}

// ── Workspace ─────────────────────────────────────────────────────────────────

pub fn handleWorkspaceSwitch(c: *anyopaque, args: []const u8) []const u8 {
    const context = ctx(c);
    const num = std.fmt.parseInt(u32, args, 10) catch return "error: usage: workspace-switch <N>\n";
    if (num > 0 and num - 1 < context.workspace_count) {
        bar_mod.switchToWorkspace(context, num - 1);
        return "ok\n";
    }
    return "error: invalid workspace number\n";
}

pub fn handleWorkspaceNext(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    const target = if (context.active_workspace) |aw|
        @min(context.workspace_count - 1, aw + 1)
    else 0;
    bar_mod.switchToWorkspace(context, @intCast(target));
    return "ok\n";
}

pub fn handleWorkspacePrevious(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    const target = if (context.active_workspace) |aw|
        aw -| 1
    else 0;
    bar_mod.switchToWorkspace(context, @intCast(target));
    return "ok\n";
}

// ── Sidebar ───────────────────────────────────────────────────────────────────

pub fn handleSidebarToggle(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    ctx(c).sidebar.toggle(ctx(c));
    return "ok\n";
}

pub fn handleSidebarShow(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    if (!context.sidebar.visible) context.sidebar.show(context);
    return "ok\n";
}

pub fn handleSidebarHide(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    if (context.sidebar.visible) {
        context.sidebar.hide(context);
        context.sidebar_open = false;
    }
    return "ok\n";
}

pub fn handleSidebarGet(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const n = std.fmt.bufPrint(&resp_buf, "{}\n", .{ctx(c).sidebar.visible}) catch return "error: buf\n";
    return resp_buf[0..n.len];
}

// ── Popup (media controls popup) ──────────────────────────────────────────────

pub fn handlePopupToggle(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    ctx(c).media_popup.toggle(ctx(c));
    return "ok\n";
}

pub fn handlePopupShow(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    if (!context.media_popup.visible) context.media_popup.show(context);
    return "ok\n";
}

pub fn handlePopupHide(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const context = ctx(c);
    if (context.media_popup.visible) context.media_popup.hide(context);
    return "ok\n";
}

// ── Notifications ─────────────────────────────────────────────────────────────

pub fn handleNotificationCount(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const n = std.fmt.bufPrint(&resp_buf, "{}\n", .{ctx(c).notifications.list_len}) catch return "error: buf\n";
    return resp_buf[0..n.len];
}

pub fn handleNotificationStatus(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const notif = &ctx(c).notifications;
    const n = std.fmt.bufPrint(&resp_buf, "{} notifications, {} unread\n", .{ notif.list_len, notif.unread }) catch return "error: buf\n";
    return resp_buf[0..n.len];
}

pub fn handleNotificationDismiss(c: *anyopaque, args: []const u8) []const u8 {
    const context = ctx(c);
    const id = std.fmt.parseInt(u32, args, 10) catch return "error: usage: notification-dismiss <id>\n";
    context.notifications.dismiss(id);
    context.bar_dirty = true;
    return "ok\n";
}

pub fn handleNotificationDismissAll(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    ctx(c).notifications.dismissAll();
    ctx(c).bar_dirty = true;
    return "ok\n";
}

pub fn handleNotificationMarkAllRead(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    ctx(c).notifications.markAllRead();
    ctx(c).bar_dirty = true;
    return "ok\n";
}

pub fn handleNotificationDndSet(c: *anyopaque, args: []const u8) []const u8 {
    _ = c;
    const on = std.mem.eql(u8, args, "on") or std.mem.eql(u8, args, "true") or std.mem.eql(u8, args, "1");
    _ = on;
    // DND not yet implemented in notifications.zig
    return "ok\n";
}

pub fn handleNotificationDndToggle(c: *anyopaque, args: []const u8) []const u8 {
    _ = c;
    _ = args;
    return "ok\n";
}

pub fn handleNotificationDndStatus(c: *anyopaque, args: []const u8) []const u8 {
    _ = c;
    _ = args;
    return "off\n";
}

// ── Clock / Resources ─────────────────────────────────────────────────────────

pub fn handleClock(c: *anyopaque, args: []const u8) []const u8 {
    _ = c;
    _ = args;
    const c_basic = @import("cbasic.zig").c;
    var raw: c_basic.time_t = undefined;
    _ = c_basic.time(&raw);
    var tm: c_basic.tm = undefined;
    _ = c_basic.localtime_r(&raw, &tm);

    const n = std.fmt.bufPrint(&resp_buf, "{d:0>2}:{d:0>2}:{d:0>2}\n", .{
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    }) catch return "error: buf\n";
    return resp_buf[0..n.len];
}

pub fn handleResources(c: *anyopaque, args: []const u8) []const u8 {
    _ = args;
    const r = &ctx(c).resources;
    var pos: usize = 0;

    pos += (std.fmt.bufPrint(resp_buf[pos..], "cpu: {d:.0}%\n", .{r.cpu_usage * 100}) catch return "error: buf\n").len;
    pos += (std.fmt.bufPrint(resp_buf[pos..], "memory: {d:.0}%\n", .{r.memory_used_pct * 100}) catch return "error: buf\n").len;
    if (r.swap_total_kb > 0) {
        pos += (std.fmt.bufPrint(resp_buf[pos..], "swap: {d:.0}%\n", .{r.swap_used_pct * 100}) catch return "error: buf\n").len;
    }
    if (r.battery_pct >= 0) {
        pos += (std.fmt.bufPrint(resp_buf[pos..], "battery: {}%\n", .{r.battery_pct}) catch return "error: buf\n").len;
    }
    return resp_buf[0..pos];
}
