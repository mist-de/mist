const std = @import("std");
const bc = @import("basu_c.zig").c;
const cc = @import("cbasic.zig").c;
const stb = @import("stb_c.zig").c;

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
    url: [:0]const u8 = "",
    art_url: [:0]const u8 = "",
    status: PlaybackStatus = .stopped,
    position: i64 = 0,
    length: i64 = 0,
    last_pos_advance_ms: i64 = 0,
    has_player: bool = false,
    changed: bool = false,

    // Album art
    art_rgb: [110 * 110 * 3]u8 = undefined,
    art_has: bool = false,
    art_load_needed: bool = false,
    art_loaded_changed: bool = false,
    current_art_url_buf: [512]u8 = undefined,
    current_art_url: [:0]const u8 = "",

    title_buf: [256]u8 = undefined,
    artist_buf: [256]u8 = undefined,
    art_url_buf: [512]u8 = undefined,
    url_buf: [512]u8 = undefined,

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
        // Fallback: if player doesn't provide mpris:artUrl, try YouTube thumbnail
        if (self.art_url.len == 0) {
            self.tryYouTubeThumbnail();
        }
        // Fix Spotify art URL: open.spotify.com/image → i.scdn.co/image (returns 404)
        self.fixSpotifyArtUrl();
        // Always check if art URL changed (not gated on 'changed') for retry on failure
        if (self.art_url.len > 0) {
            if (!std.mem.eql(u8, self.current_art_url, self.art_url)) {
                self.art_has = false;
                self.art_load_needed = true;
            }
        } else {
            self.art_has = false;
        }
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
        const dest = @as([*:0]const u8, @ptrCast(self.name.ptr));
        const path: [*:0]const u8 = "/org/mpris/MediaPlayer2";
        const iface_player: [*:0]const u8 = "org.mpris.MediaPlayer2.Player";

        // PlaybackStatus
        {
            var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
            defer bc.sd_bus_error_free(&error_val);
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

        // Position: during playback, trust local wall-clock advancement.
        // Only accept D-Bus Position when:
        //   1. Not playing (pause/stopped → snapshot is authoritative)
        //   2. Playing but D-Bus pos is non-zero and large divergence (seek detection)
        // D-Bus pos==0 during playback is a known MPRIS bug — always ignore it.
        {
            var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
            defer bc.sd_bus_error_free(&error_val);
            var pos: i64 = 0;
            const r = bc.sd_bus_get_property_trivial(bus, dest, path, iface_player, "Position", &error_val, 'x', @ptrCast(&pos));
            if (r >= 0) {
                const dominated = self.status != .playing or
                    (pos != 0 and @abs(pos - self.position) > 2_000_000); // >2s divergence = seek
                if (dominated) {
                    if (pos != self.position) self.changed = true;
                    self.position = pos;
                }
            }
        }

        // Metadata dict parsing
        self.readMetadata(bus, dest, path, iface_player);
    }

    fn readMetadata(self: *MprisPlayer, bus: *bc.sd_bus, dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8) void {
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);

        var reply: ?*bc.sd_bus_message = null;
        // Enter variant (sd_bus_get_property enters internally)
        var rc = bc.sd_bus_get_property(bus, dest, path, iface, "Metadata", &error_val, &reply, "a{sv}");
        // Fallback to call_method
        if (rc < 0) {
            bc.sd_bus_error_free(&error_val);
            error_val = std.mem.zeroes(bc.sd_bus_error);
            rc = bc.sd_bus_call_method(bus, dest, path, "org.freedesktop.DBus.Properties", "Get",
                &error_val, &reply, "ss", iface, "Metadata");
            if (rc < 0) return;
            // Enter variant containing a{sv}
            rc = bc.sd_bus_message_enter_container(reply, 'v', "a{sv}");
            if (rc <= 0) {
                _ = bc.sd_bus_message_unref(reply);
                return;
            }
        }
        defer _ = bc.sd_bus_message_unref(reply);
        const m = reply.?;

        var rrc = bc.sd_bus_message_enter_container(m, 'a', "{sv}");
        if (rrc <= 0) return;

        self.url = "";
        self.art_url = "";
        var has_title = false;
        var has_artist = false;
        var has_length = false;
        var has_art_url = false;

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

            // Peek variant type
            var vt_str: [*c]const u8 = undefined;
            rrc = bc.sd_bus_message_peek_type(m, null, @ptrCast(&vt_str));
            if (rrc <= 0) {
                _ = bc.sd_bus_message_exit_container(m);
                break;
            }
            const vt = if (vt_str) |p| p[0] else 0;

            // Enter variant
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
            } else if (std.mem.eql(u8, ks, "mpris:length") and (vt == 'x' or vt == 't')) blk: {
                if (vt == 'x') {
                    var val: i64 = 0;
                    if (bc.sd_bus_message_read(m, "x", &val) > 0) {
                        self.length = val;
                        has_length = true;
                        break :blk true;
                    }
                } else {
                    var val: u64 = 0;
                    if (bc.sd_bus_message_read(m, "t", &val) > 0) {
                        self.length = @as(i64, @intCast(val));
                        has_length = true;
                        break :blk true;
                    }
                }
                break :blk false;
            } else if (std.mem.eql(u8, ks, "mpris:artUrl") and vt == 's') blk: {
                var val: [*:0]const u8 = undefined;
                if (bc.sd_bus_message_read(m, "s", &val) > 0) {
                    const vs = std.mem.span(val);
                    const len = @min(vs.len, self.art_url_buf.len - 1);
                    @memcpy(self.art_url_buf[0..len], vs[0..len]);
                    self.art_url_buf[len] = 0;
                    self.art_url = self.art_url_buf[0..len :0];
                    has_art_url = true;
                    break :blk true;
                }
                break :blk false;
            } else if (std.mem.eql(u8, ks, "xesam:url") and vt == 's') blk: {
                var val: [*:0]const u8 = undefined;
                if (bc.sd_bus_message_read(m, "s", &val) > 0) {
                    const vs = std.mem.span(val);
                    const len = @min(vs.len, self.url_buf.len - 1);
                    @memcpy(self.url_buf[0..len], vs[0..len]);
                    self.url_buf[len] = 0;
                    self.url = self.url_buf[0..len :0];
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

        if (has_title or has_artist or has_length or has_art_url) self.changed = true;
    }

    fn hashUrl(url: []const u8) u64 {
        var h: u64 = 0x12345678;
        for (url) |c| h = h *% 31 +% @as(u64, c);
        return h;
    }

    /// YouTube thumbnail fallback from xesam:url
    fn tryYouTubeThumbnail(self: *MprisPlayer) void {
        if (self.url.len < 11) return;

        const url = self.url;

        // youtube.com/watch?v= (also matches m.youtube.com, music.youtube.com)
        if (std.mem.indexOf(u8, url, "youtube.com/watch")) |_| {
            if (std.mem.indexOf(u8, url, "v=")) |vpos| {
                const start = vpos + 2;
                var end = start;
                while (end < url.len and url[end] != '&') end += 1;
                const vid = url[start..end];
                if (vid.len >= 11) {
                    self.setYouTubeArtUrl(vid[0..11]);
                    return;
                }
            }
        }

        // youtube.com/shorts/<id>
        if (std.mem.indexOf(u8, url, "youtube.com/shorts/")) |pos| {
            const start = pos + 19;
            var end = start;
            while (end < url.len and url[end] != '?' and url[end] != '&') end += 1;
            const vid = url[start..end];
            if (vid.len >= 11) {
                self.setYouTubeArtUrl(vid[0..11]);
                return;
            }
        }

        // youtu.be/
        if (std.mem.indexOf(u8, url, "youtu.be/")) |pos| {
            const start = pos + 9;
            var end = start;
            while (end < url.len and url[end] != '?' and url[end] != '&') end += 1;
            const vid = url[start..end];
            if (vid.len >= 11) {
                self.setYouTubeArtUrl(vid[0..11]);
            }
        }
    }

    fn setYouTubeArtUrl(self: *MprisPlayer, vid: []const u8) void {
        const buf = &self.art_url_buf;
        const thumbnail_url = std.fmt.bufPrint(buf, "https://img.youtube.com/vi/{s}/hqdefault.jpg", .{vid}) catch return;
        buf[thumbnail_url.len] = 0;
        self.art_url = buf[0..thumbnail_url.len :0];
    }

    /// Spotify's mpris:artUrl returns https://open.spotify.com/image/<hash> which 404s.
    /// Rewrite to https://i.scdn.co/image/<hash> (the actual CDN).
    fn fixSpotifyArtUrl(self: *MprisPlayer) void {
        const prefix = "https://open.spotify.com/image/";
        if (std.mem.startsWith(u8, self.art_url, prefix)) {
            const hash = self.art_url[prefix.len..];
            var new_buf: [512]u8 = undefined;
            const new_url = std.fmt.bufPrint(&new_buf, "https://i.scdn.co/image/{s}", .{hash}) catch return;
            if (new_url.len < self.art_url_buf.len) {
                @memcpy(self.art_url_buf[0..new_url.len], new_url);
                self.art_url_buf[new_url.len] = 0;
                self.art_url = self.art_url_buf[0..new_url.len :0];
            }
        }
    }

    /// Try to load art from cache. Returns true if cache hit.
    fn tryLoadFromCache(self: *MprisPlayer) bool {
        if (self.current_art_url.len == 0) return false;

        var cache_base_buf: [256]u8 = undefined;
        const cache_base = self.getCacheBase(&cache_base_buf);
        const url_hash = hashUrl(self.current_art_url);
        var hash_buf: [32]u8 = undefined;
        const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{url_hash}) catch return false;
        var cache_path_buf: [256]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&cache_path_buf, "{s}/mist/coverart/{s}.raw", .{ cache_base, hash_str }) catch return false;
        cache_path_buf[cache_path.len] = 0;

        const cache_z: [*:0]const u8 = @ptrCast(&cache_path_buf);
        const f = cc.fopen(cache_z, "rb") orelse return false;
        defer _ = cc.fclose(f);
        const n = cc.fread(&self.art_rgb, 1, self.art_rgb.len, f);
        if (n != self.art_rgb.len) return false;
        self.art_has = true;
        self.saveArtUrl();
        self.art_loaded_changed = true;
        return true;
    }

    fn getCacheBase(self: *MprisPlayer, buf: []u8) []const u8 {
        _ = self;
        if (std.c.getenv("XDG_CACHE_HOME")) |env| {
            const s = std.mem.span(env);
            return s;
        } else if (std.c.getenv("HOME")) |home| {
            const h = std.mem.span(home);
            const p = std.fmt.bufPrint(buf, "{s}/.cache", .{h}) catch return "/tmp";
            return buf[0..p.len];
        }
        return "/tmp";
    }

    /// Load album art: 110x110 RGB via stb_image.
    /// Local files: decoded directly. Remote URLs: fetched via std.http.Client.
    fn loadAlbumArt(self: *MprisPlayer) void {
        if (self.art_url.len == 0) return;
        if (std.mem.startsWith(u8, self.art_url, "data:")) return;

        const is_remote = !std.mem.startsWith(u8, self.art_url, "file://");

        if (is_remote) {
            self.loadRemoteArt();
        } else {
            self.loadLocalArt();
        }
    }

    fn loadLocalArt(self: *MprisPlayer) void {
        // Strip file:// prefix
        var src_buf: [1024]u8 = undefined;
        const src_path: [:0]const u8 = blk: {
            const stripped = self.art_url[7..];
            const len = @min(stripped.len, src_buf.len - 1);
            @memcpy(src_buf[0..len], stripped[0..len]);
            src_buf[len] = 0;
            break :blk src_buf[0..len :0];
        };

        const src_z: [*:0]const u8 = @ptrCast(&src_buf);
        if (std.c.access(src_z, std.c.F_OK) != 0) {
            std.log.warn("art file not found: {s}", .{src_path});
            self.saveArtUrl();
            return;
        }

        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const data = stb.stbi_load(src_z, &w, &h, &channels, 3);
        if (data == null or w == 0 or h == 0) {
            std.log.warn("stbi_load failed for: {s}", .{src_path});
            self.saveArtUrl();
            return;
        }
        defer stb.stbi_image_free(data);

        self.decodeAndResize(data, @intCast(w), @intCast(h));
    }

    fn loadRemoteArt(self: *MprisPlayer) void {
        const uri = std.Uri.parse(self.art_url) catch {
            std.log.warn("invalid art URL: {s}", .{self.art_url});
            self.saveArtUrl();
            return;
        };

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
        defer client.deinit();

        var req = client.request(.GET, uri, .{}) catch |err| {
            std.log.warn("art request failed: {s}", .{@errorName(err)});
            self.saveArtUrl();
            return;
        };
        defer req.deinit();

        req.sendBodiless() catch |err| {
            std.log.warn("art send failed: {s}", .{@errorName(err)});
            self.saveArtUrl();
            return;
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            std.log.warn("art receive failed: {s}", .{@errorName(err)});
            self.saveArtUrl();
            return;
        };

        if (response.head.status != .ok) {
            std.log.warn("art HTTP status: {}", .{response.head.status});
            self.saveArtUrl();
            return;
        }

        // Read response body into stack buffer
        var body_buf: [256 * 1024]u8 = undefined;
        var transfer_buf: [4096]u8 = undefined;
        var total: usize = 0;
        const r = response.reader(&transfer_buf);
        while (total < body_buf.len) {
            const n = r.readSliceShort(body_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }

        if (total == 0) {
            std.log.warn("art fetch empty body", .{});
            self.saveArtUrl();
            return;
        }

        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const data = stb.stbi_load_from_memory(&body_buf, @intCast(total), &w, &h, &channels, 3);
        if (data == null or w == 0 or h == 0) {
            std.log.warn("stbi_load_from_memory failed for art URL", .{});
            self.saveArtUrl();
            return;
        }
        defer stb.stbi_image_free(data);

        self.decodeAndResize(data, @intCast(w), @intCast(h));
    }

    fn decodeAndResize(self: *MprisPlayer, data: [*]const u8, w: c_int, h: c_int) void {
        const resized = stb.stbir_resize(
            data, w, h, 0,
            @ptrCast(&self.art_rgb), 110, 110, 0,
            stb.STBIR_RGB, stb.STBIR_TYPE_UINT8,
            stb.STBIR_EDGE_CLAMP, stb.STBIR_FILTER_DEFAULT,
        );
        if (resized != null) {
            self.art_has = true;
            self.saveArtUrl();
            self.art_loaded_changed = true;
        } else {
            std.log.warn("stbir_resize failed", .{});
            self.saveArtUrl();
        }
    }

    /// Process pending art load. Called every main-loop iteration.
    pub fn tickArtLoading(self: *MprisPlayer) void {
        // Always try loading from cache — catches background-downloaded art
        if (!self.art_has) {
            if (self.tryLoadFromCache()) return;
        }

        if (self.art_load_needed) {
            self.art_load_needed = false;
            self.loadAlbumArt();
        }
    }

    fn saveArtUrl(self: *MprisPlayer) void {
        const len = @min(self.art_url.len, self.current_art_url_buf.len - 1);
        @memcpy(self.current_art_url_buf[0..len], self.art_url[0..len]);
        self.current_art_url_buf[len] = 0;
        self.current_art_url = self.current_art_url_buf[0..len :0];
    }

    pub fn playPause(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        if (!self.has_player or self.name.len == 0) return;
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);
        var reply: ?*bc.sd_bus_message = null;
        _ = bc.sd_bus_call_method(b, self.name.ptr, "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "PlayPause",
            &error_val, &reply, null);
        if (reply) |r| _ = bc.sd_bus_message_unref(r);
    }

    pub fn next(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        if (!self.has_player or self.name.len == 0) return;
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);
        var reply: ?*bc.sd_bus_message = null;
        const rc = bc.sd_bus_call_method(b, self.name.ptr, "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Next",
            &error_val, &reply, null);
        if (reply) |r| _ = bc.sd_bus_message_unref(r);
        if (rc < 0) {
            const msg: [*:0]const u8 = if (error_val.message != null) error_val.message else "unknown";
            std.log.warn("MPRIS Next failed: {s}", .{std.mem.sliceTo(msg, 0)});
        }
    }

    pub fn previous(self: *MprisPlayer) void {
        const b = self.bus orelse return;
        if (!self.has_player or self.name.len == 0) return;
        var error_val: bc.sd_bus_error = std.mem.zeroes(bc.sd_bus_error);
        defer bc.sd_bus_error_free(&error_val);
        var reply: ?*bc.sd_bus_message = null;
        const rc = bc.sd_bus_call_method(b, self.name.ptr, "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player", "Previous",
            &error_val, &reply, null);
        if (reply) |r| _ = bc.sd_bus_message_unref(r);
        if (rc < 0) {
            const msg: [*:0]const u8 = if (error_val.message != null) error_val.message else "unknown";
            std.log.warn("MPRIS Previous failed: {s}", .{std.mem.sliceTo(msg, 0)});
        }
    }
};
