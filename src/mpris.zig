const std = @import("std");
const bc = @import("basu_c.zig").c;

pub const PlaybackStatus = enum(u2) {
    stopped = 0,
    playing = 1,
    paused = 2,
};

pub const MprisPlayer = struct {
    bus: ?*bc.sd_bus = null,
    name_buf: [128]u8 = undefined,
    name: [:0]const u8 = "",
    title: [:0]const u8 = "",
    artist: [:0]const u8 = "",
    status: PlaybackStatus = .stopped,
    position: i64 = 0,
    length: i64 = 0,
    has_player: bool = false,
    changed: bool = false,

    title_buf: [256]u8 = undefined,
    artist_buf: [256]u8 = undefined,

    pub fn init() !MprisPlayer {
        var b: ?*bc.sd_bus = null;
        const rc = bc.sd_bus_open_user(&b);
        if (rc < 0) return error.DBusConnectFailed;
        return MprisPlayer{ .bus = b };
    }

    pub fn deinit(self: *MprisPlayer) void {
        if (self.bus) |b| {
            _ = bc.sd_bus_flush(b);
            bc.sd_bus_close(b);
            _ = bc.sd_bus_unref(b);
        }
    }

    pub fn getFd(self: *MprisPlayer) i32 {
        return if (self.bus) |b| bc.sd_bus_get_fd(b) else -1;
    }

    pub fn process(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        while (true) {
            var msg: ?*bc.sd_bus_message = null;
            const rc = bc.sd_bus_process(b, &msg);
            if (rc <= 0) break;
        }
    }

    pub fn query(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        const pname = self.findPlayer(b) orelse {
            if (self.has_player) self.changed = true;
            self.has_player = false;
            return;
        };
        if (!self.has_player) { self.changed = true; }

        self.name = pname;
        self.has_player = true;
        self.readProperties(b);
    }

    fn findPlayer(self: *MprisPlayer, bus: *bc.sd_bus) ?[:0]const u8 {
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);

        var reply: ?*bc.sd_bus_message = null;
        const rc = bc.sd_bus_call_method(
            bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "ListNames",
            &error_val, &reply, null,
        );
        if (rc < 0) return null;
        defer _ = bc.sd_bus_message_unref(reply);

        var rrc = bc.sd_bus_message_enter_container(reply, 'a', "s");
        if (rrc <= 0) return null;

        while (true) {
            var name: ?[*:0]const u8 = null;
            rrc = bc.sd_bus_message_read(reply, "s", &name);
            if (rrc <= 0) break;
            const n = name orelse continue;
            const s = std.mem.span(n);
            if (std.mem.startsWith(u8, s, "org.mpris.MediaPlayer2.")) {
            const len = @min(s.len, self.name_buf.len - 1);
            @memcpy(self.name_buf[0..len], s[0..len]);
            self.name_buf[len] = 0;
            _ = bc.sd_bus_message_exit_container(reply);
            return self.name_buf[0..len :0];
            }
        }
        _ = bc.sd_bus_message_exit_container(reply);
        return null;
    }

    fn readProperties(self: *MprisPlayer, bus: *bc.sd_bus) void {
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);

        const dest = @as([*:0]const u8, @ptrCast(self.name.ptr));
        const path: [*:0]const u8 = "/org/mpris/MediaPlayer2";
        const iface_player: [*:0]const u8 = "org.mpris.MediaPlayer2.Player";

        // PlaybackStatus via sd_bus_get_property_string
        {
            var status_str: [*c]u8 = null;
            const r = bc.sd_bus_get_property_string(bus, dest, path, iface_player, "PlaybackStatus", &error_val, &status_str);
            if (r >= 0) {
                if (status_str) |s| {
                    const ss = std.mem.span(s);
                    const new_status: PlaybackStatus = if (std.mem.eql(u8, ss, "Playing")) .playing else if (std.mem.eql(u8, ss, "Paused")) .paused else .stopped;
                    if (new_status != self.status) self.changed = true;
                    self.status = new_status;
                    std.c.free(@as(?*anyopaque, @ptrCast(s)));
                }
            }
        }

        // Position via sd_bus_get_property_trivial (type 'x' = int64)
        {
            var pos: i64 = 0;
            const r = bc.sd_bus_get_property_trivial(bus, dest, path, iface_player, "Position", &error_val, 'x', @ptrCast(&pos));
            if (r >= 0) {
                if (pos != self.position) self.changed = true;
                self.position = pos;
            }
        }

        // Metadata via sd_bus_get_property with type "a{sv}" — manual dict parsing
        self.readMetadata(bus, dest, path, iface_player, &error_val);
    }

    fn readMetadata(self: *MprisPlayer, bus: *bc.sd_bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, error_val: *bc.sd_bus_error) void {
        var reply: ?*bc.sd_bus_message = null;
        // sd_bus_get_property enters the variant internally, cursor at array
        const rc = bc.sd_bus_get_property(bus, dest, path, iface, "Metadata", error_val, &reply, "a{sv}");
        if (rc < 0) return;
        defer _ = bc.sd_bus_message_unref(reply);
        const m = reply.?;

        var rrc = bc.sd_bus_message_enter_container(m, 'a', "{sv}");
        if (rrc <= 0) return;

        var has_title = false;
        var has_artist = false;
        var has_length = false;

        while (true) {
            rrc = bc.sd_bus_message_enter_container(m, 'e', "sv");
            if (rrc <= 0) break;

            var key: ?[*:0]const u8 = null;
            rrc = bc.sd_bus_message_read(m, "s", &key);
            if (rrc <= 0) {
                _ = bc.sd_bus_message_exit_container(m);
                break;
            }
            const k = key orelse {
                _ = bc.sd_bus_message_exit_container(m);
                break;
            };
            const ks = std.mem.span(k);

            // Peek variant type before entering (StackOverflow pattern)
            var vt_str: [*c]const u8 = undefined;
            rrc = bc.sd_bus_message_peek_type(m, null, @ptrCast(&vt_str));
            if (rrc <= 0) {
                _ = bc.sd_bus_message_exit_container(m);
                break;
            }
            const vt = if (vt_str) |p| p[0] else 0;

            // Enter variant with peeked type as expected contents
            rrc = bc.sd_bus_message_enter_container(m, 'v', vt_str);
            if (rrc <= 0) {
                _ = bc.sd_bus_message_exit_container(m);
                break;
            }

            const handled = if (std.mem.eql(u8, ks, "xesam:title") and vt == 's') blk: {
                var val: [*:0]const u8 = undefined;
                if (bc.sd_bus_message_read(m, "s", &val) > 0) {
                    const vs = std.mem.span(val);
                    const len = @min(vs.len, self.title_buf.len - 1);
                    @memcpy(self.title_buf[0..len], vs[0..len]);
                    self.title_buf[len] = 0;
                    self.title = self.title_buf[0..len :0];
                    has_title = true;
                    break :blk true;
                }
                break :blk false;
            } else if (std.mem.eql(u8, ks, "xesam:artist") and vt == 'a') blk: {
                rrc = bc.sd_bus_message_enter_container(m, 'a', "s");
                if (rrc > 0) {
                    var first = true;
                    var pos: usize = 0;
                    while (pos < self.artist_buf.len) {
                        var val: [*:0]const u8 = undefined;
                        if (bc.sd_bus_message_read(m, "s", &val) <= 0) break;
                        if (!first and pos + 2 <= self.artist_buf.len) {
                            self.artist_buf[pos] = ',';
                            self.artist_buf[pos + 1] = ' ';
                            pos += 2;
                        }
                        first = false;
                        const vs = std.mem.span(val);
                        const copy_len = @min(vs.len, self.artist_buf.len -| pos);
                        @memcpy(self.artist_buf[pos..][0..copy_len], vs[0..copy_len]);
                        pos += copy_len;
                    }
                    _ = bc.sd_bus_message_exit_container(m);
                    self.artist_buf[pos] = 0;
                    self.artist = self.artist_buf[0..pos :0];
                    has_artist = true;
                    break :blk true;
                }
                break :blk false;
            } else if (std.mem.eql(u8, ks, "mpris:length") and vt == 'x') blk: {
                var val: i64 = 0;
                if (bc.sd_bus_message_read(m, "x", &val) > 0) {
                    self.length = val;
                    has_length = true;
                    break :blk true;
                }
                break :blk false;
            } else false;

            if (!handled) {
                if (vt_str) |vs| _ = bc.sd_bus_message_skip(m, vs);
            }

            _ = bc.sd_bus_message_exit_container(m); // variant
            _ = bc.sd_bus_message_exit_container(m); // dict entry
        }
        _ = bc.sd_bus_message_exit_container(m); // array

        if (has_title or has_artist or has_length) self.changed = true;
    }

    pub fn playPause(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);
        _ = bc.sd_bus_call_method(b, self.name, "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "PlayPause",
            &error_val, null, null);
    }

    pub fn next(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);
        _ = bc.sd_bus_call_method(b, self.name, "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Next",
            &error_val, null, null);
    }

    pub fn previous(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);
        _ = bc.sd_bus_call_method(b, self.name, "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Previous",
            &error_val, null, null);
    }
};
