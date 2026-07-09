const std = @import("std");
const bc = @import("basu_c.zig").c;

const max_notifications = 64;
const max_actions = 8;

pub const ActionEntry = struct {
    key: [32]u8 = undefined,
    key_len: usize = 0,
    label: [64]u8 = undefined,
    label_len: usize = 0,
};

pub const POPUP_TIMEOUT_MS: i64 = 7000;

pub const Notification = struct {
    id: u32 = 0,
    app_name: [64]u8 = undefined,
    app_name_len: usize = 0,
    summary: [256]u8 = undefined,
    summary_len: usize = 0,
    body: [512]u8 = undefined,
    body_len: usize = 0,
    app_icon: [256]u8 = undefined,
    app_icon_len: usize = 0,
    timestamp_ms: i64 = 0,
    urgency: u8 = 1,
    actions: [max_actions]ActionEntry = undefined,
    action_count: u8 = 0,
    popup: bool = false,
    popup_timeout_ms: i64 = 0,
};

pub const NotificationServer = struct {
    bus: ?*bc.sd_bus = null,
    list: [max_notifications]Notification = undefined,
    list_len: usize = 0,
    unread: u32 = 0,
    next_id: u32 = 1,
    changed: bool = false,
    popup_len: usize = 0,

    pub fn init(self: *NotificationServer) void {
        var b: ?*bc.sd_bus = null;
        const rc = bc.sd_bus_open_user(&b);
        if (rc < 0) {
            std.log.warn("notifications: dbus open failed", .{});
            return;
        }

        _ = bc.sd_bus_add_object(
            b,
            null,
            "/org/freedesktop/Notifications",
            @ptrCast(&objectHandler),
            @ptrCast(self),
        );

        const name_rc = bc.sd_bus_request_name(b, "org.freedesktop.Notifications", bc.SD_BUS_NAME_REPLACE_EXISTING);
        if (name_rc < 0) {
            std.log.warn("notifications: failed to claim name (rc={d}), another daemon running?", .{name_rc});
        }

        _ = bc.sd_bus_flush(b);

        self.bus = b;
    }

    fn objectHandler(
        msg: ?*bc.sd_bus_message,
        userdata: ?*anyopaque,
        ret_error: ?*anyopaque,
    ) callconv(.c) c_int {
        _ = ret_error;
        const self: *NotificationServer = @ptrCast(@alignCast(userdata));
        const m = msg orelse return -1;
        self.handleMessage(m);
        return 1;
    }

    pub fn deinit(self: *NotificationServer) void {
        if (self.bus) |b| {
            _ = bc.sd_bus_flush(b);
            bc.sd_bus_close(b);
            _ = bc.sd_bus_unref(b);
        }
    }

    pub fn getFd(self: *NotificationServer) i32 {
        return if (self.bus) |b| bc.sd_bus_get_fd(b) else -1;
    }

    pub fn process(self: *NotificationServer) void {
        const b = self.bus orelse return;
        var msg: ?*bc.sd_bus_message = null;
        // Loop until no more progress — matches Noctalia's pattern (max 16 events, 4ms budget)
        var budget: u8 = 0;
        while (bc.sd_bus_process(b, &msg) > 0 and budget < 16) : (budget += 1) {
            if (msg) |m| {
                _ = bc.sd_bus_message_unref(m);
            }
        }
        _ = bc.sd_bus_flush(b);
    }

    pub fn getEvents(self: *NotificationServer) i16 {
        const b = self.bus orelse return 0;
        const ev: i32 = bc.sd_bus_get_events(b);
        return @intCast(ev & 0x7fff);
    }

    pub fn getTimeout(self: *NotificationServer) u64 {
        const b = self.bus orelse return std.math.maxInt(u64);
        var timeout_usec: u64 = 0;
        _ = bc.sd_bus_get_timeout(b, &timeout_usec);
        return timeout_usec;
    }

    fn handleMessage(self: *NotificationServer, msg: *bc.sd_bus_message) void {
        const iface = bc.sd_bus_message_get_interface(msg) orelse return;
        const member = bc.sd_bus_message_get_member(msg) orelse return;

        const iface_z: [*:0]const u8 = @ptrCast(iface);
        const member_z: [*:0]const u8 = @ptrCast(member);

        if (std.mem.eql(u8, std.mem.span(iface_z), "org.freedesktop.Notifications")) {
            if (std.mem.eql(u8, std.mem.span(member_z), "Notify")) {
                self.handleNotify(msg);
            } else if (std.mem.eql(u8, std.mem.span(member_z), "CloseNotification")) {
                self.handleCloseNotification(msg);
            } else if (std.mem.eql(u8, std.mem.span(member_z), "GetCapabilities")) {
                self.handleGetCapabilities(msg);
            } else if (std.mem.eql(u8, std.mem.span(member_z), "GetServerInformation")) {
                self.handleGetServerInformation(msg);
            }
        } else if (std.mem.eql(u8, std.mem.span(iface_z), "org.freedesktop.DBus.Introspectable")) {
            if (std.mem.eql(u8, std.mem.span(member_z), "Introspect")) {
                self.handleIntrospect(msg);
            }
        }
    }

    fn handleIntrospect(self: *NotificationServer, msg: *bc.sd_bus_message) void {
        _ = self;
        const xml =
            \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
            \\  "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
            \\<node>
            \\  <interface name="org.freedesktop.Notifications">
            \\    <method name="Notify">
            \\      <arg name="app_name" type="s" direction="in"/>
            \\      <arg name="replaces_id" type="u" direction="in"/>
            \\      <arg name="app_icon" type="s" direction="in"/>
            \\      <arg name="summary" type="s" direction="in"/>
            \\      <arg name="body" type="s" direction="in"/>
            \\      <arg name="actions" type="as" direction="in"/>
            \\      <arg name="hints" type="a{sv}" direction="in"/>
            \\      <arg name="expire_timeout" type="i" direction="in"/>
            \\      <arg name="id" type="u" direction="out"/>
            \\    </method>
            \\    <method name="CloseNotification">
            \\      <arg name="id" type="u" direction="in"/>
            \\    </method>
            \\    <method name="GetCapabilities">
            \\      <arg name="capabilities" type="as" direction="out"/>
            \\    </method>
            \\    <method name="GetServerInformation">
            \\      <arg name="name" type="s" direction="out"/>
            \\      <arg name="vendor" type="s" direction="out"/>
            \\      <arg name="version" type="s" direction="out"/>
            \\      <arg name="spec_version" type="s" direction="out"/>
            \\    </method>
            \\  </interface>
            \\</node>
        ;
        _ = bc.sd_bus_reply_method_return(msg, "s", @as([*:0]const u8, @ptrCast(xml)));
    }

    fn handleNotify(self: *NotificationServer, msg: *bc.sd_bus_message) void {
        var app_name: ?[*:0]const u8 = null;
        var replaces_id: u32 = 0;
        var app_icon: ?[*:0]const u8 = null;
        var summary: ?[*:0]const u8 = null;
        var body: ?[*:0]const u8 = null;

        _ = bc.sd_bus_message_read_basic(msg, 's', @ptrCast(&app_name));
        // replaces_id is u32 in spec, but some clients (dbus-send) send int32
        var replaces_id_i: i32 = 0;
        var rt: u8 = undefined;
        var rs: [*c]const u8 = undefined;
        _ = bc.sd_bus_message_peek_type(msg, &rt, @ptrCast(&rs));
        if (rt == 'u') {
            _ = bc.sd_bus_message_read_basic(msg, 'u', @ptrCast(&replaces_id));
        } else if (rt == 'i') {
            _ = bc.sd_bus_message_read_basic(msg, 'i', @ptrCast(&replaces_id_i));
            replaces_id = @intCast(@max(replaces_id_i, 0));
        }
        _ = bc.sd_bus_message_read_basic(msg, 's', @ptrCast(&app_icon));
        _ = bc.sd_bus_message_read_basic(msg, 's', @ptrCast(&summary));
        _ = bc.sd_bus_message_read_basic(msg, 's', @ptrCast(&body));

        // Parse actions array
        var tmp_actions: [max_actions]ActionEntry = undefined;
        var action_count: u8 = 0;
        _ = bc.sd_bus_message_enter_container(msg, 'a', "s");
        while (bc.sd_bus_message_at_end(msg, 0) == 0 and action_count < max_actions) {
            var action_key: ?[*:0]const u8 = null;
            var action_label: ?[*:0]const u8 = null;
            _ = bc.sd_bus_message_read_basic(msg, 's', @ptrCast(&action_key));
            if (bc.sd_bus_message_at_end(msg, 0) == 0) {
                _ = bc.sd_bus_message_read_basic(msg, 's', @ptrCast(&action_label));
            }
            if (action_key) |k| {
                tmp_actions[action_count].key_len = copyZ32(&tmp_actions[action_count].key, k);
                if (action_label) |l| {
                    tmp_actions[action_count].label_len = copyZ64(&tmp_actions[action_count].label, l);
                }
                action_count += 1;
            }
        }
        _ = bc.sd_bus_message_exit_container(msg);

        // Skip hints dict — handle both a{sv} and a{ss}
        const urgency: u8 = 1;
        {
            var hints_type: u8 = undefined;
            var hints_sig_c: [*c]const u8 = undefined;
            _ = bc.sd_bus_message_peek_type(msg, &hints_type, @ptrCast(&hints_sig_c));
            if (hints_type == 'a' and hints_sig_c != null) {
                const esig_span = std.mem.span(hints_sig_c);
                if (bc.sd_bus_message_enter_container(msg, 'a', esig_span) > 0) {
                    while (bc.sd_bus_message_at_end(msg, 0) == 0) {
                        var et: u8 = undefined;
                        var es_c: [*c]const u8 = undefined;
                        _ = bc.sd_bus_message_peek_type(msg, &et, @ptrCast(&es_c));
                        if (et == '{' and es_c != null) {
                            const es_span = std.mem.span(es_c);
                            _ = bc.sd_bus_message_enter_container(msg, '{', es_span);
                            var dummy: ?[*:0]const u8 = null;
                            _ = bc.sd_bus_message_read_basic(msg, 's', @ptrCast(&dummy));
                            var vt: u8 = undefined;
                            var vs_c: [*c]const u8 = undefined;
                            _ = bc.sd_bus_message_peek_type(msg, &vt, @ptrCast(&vs_c));
                            const skip_t: [*c]const u8 = if (vs_c != null) vs_c else @ptrCast("v");
                            _ = bc.sd_bus_message_skip(msg, skip_t);
                            _ = bc.sd_bus_message_exit_container(msg);
                        } else break;
                    }
                    _ = bc.sd_bus_message_exit_container(msg);
                }
            }
        }

        // Read expire_timeout
        var expire_timeout: i32 = -1;
        _ = bc.sd_bus_message_read_basic(msg, 'i', @ptrCast(&expire_timeout));

        var id: u32 = 0;
        if (replaces_id > 0) {
            var found = false;
            for (0..self.list_len) |i| {
                if (self.list[i].id == replaces_id) {
                    id = replaces_id;
                    self.fillNotification(&self.list[i], app_name, app_icon, summary, body, urgency, &tmp_actions, action_count);
                    var ts: std.os.linux.timespec = undefined;
                    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
                    self.list[i].timestamp_ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
                    self.list[i].popup = true;
                    self.list[i].popup_timeout_ms = self.list[i].timestamp_ms + POPUP_TIMEOUT_MS;
                    self.popup_len += 1;
                    self.changed = true;
                    found = true;
                    break;
                }
            }
            if (!found) {
                id = self.addNewNotification(app_name, app_icon, summary, body, urgency, &tmp_actions, action_count);
            }
        } else {
            id = self.addNewNotification(app_name, app_icon, summary, body, urgency, &tmp_actions, action_count);
        }

        // Reply with the notification ID
        _ = bc.sd_bus_reply_method_return(msg, "u", @as(c_uint, id));
    }

    fn addNewNotification(
        self: *NotificationServer,
        app_name: ?[*:0]const u8,
        app_icon: ?[*:0]const u8,
        summary: ?[*:0]const u8,
        body: ?[*:0]const u8,
        urgency: u8,
        actions: []ActionEntry,
        action_count: u8,
    ) u32 {
        _ = actions;
        const id = self.next_id;
        self.next_id += 1;
        if (self.next_id == 0) self.next_id = 1;

        if (self.list_len < max_notifications) {
            var notif = &self.list[self.list_len];
            self.fillNotification(notif, app_name, app_icon, summary, body, urgency, null, action_count);
            notif.id = id;

            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
            notif.timestamp_ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
            notif.popup = true;
            notif.popup_timeout_ms = notif.timestamp_ms + POPUP_TIMEOUT_MS;

            self.list_len += 1;
        } else {
            var i: usize = 0;
            while (i < self.list_len - 1) : (i += 1) {
                self.list[i] = self.list[i + 1];
            }
            var notif = &self.list[self.list_len - 1];
            self.fillNotification(notif, app_name, app_icon, summary, body, urgency, null, action_count);
            notif.id = id;

            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
            notif.timestamp_ms = @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
            notif.popup = true;
            notif.popup_timeout_ms = notif.timestamp_ms + POPUP_TIMEOUT_MS;
        }

        self.popup_len += 1;
        self.unread += 1;
        self.changed = true;
        return id;
    }

    fn fillNotification(
        self: *NotificationServer,
        notif: *Notification,
        app_name: ?[*:0]const u8,
        app_icon: ?[*:0]const u8,
        summary: ?[*:0]const u8,
        body_text: ?[*:0]const u8,
        urgency: u8,
        actions: ?[]ActionEntry,
        action_count: u8,
    ) void {
        _ = self;
        notif.app_name_len = copyZ64(&notif.app_name, app_name);
        notif.app_icon_len = copyZ(&notif.app_icon, app_icon);
        notif.summary_len = copyZ(&notif.summary, summary);
        notif.body_len = copyZ512(&notif.body, body_text);
        notif.urgency = urgency;
        notif.action_count = if (actions) |a| @min(action_count, @as(u8, @intCast(@min(a.len, max_actions)))) else 0;
        if (actions) |a| {
            for (0..notif.action_count) |i| {
                notif.actions[i] = a[i];
            }
        }
    }

    fn handleCloseNotification(self: *NotificationServer, msg: *bc.sd_bus_message) void {
        var id: u32 = 0;
        _ = bc.sd_bus_message_read_basic(msg, 'u', @ptrCast(&id));
        self.dismiss(id);
        _ = bc.sd_bus_reply_method_return(msg, "");
    }

    fn handleGetCapabilities(self: *NotificationServer, msg: *bc.sd_bus_message) void {
        _ = self;
        _ = bc.sd_bus_reply_method_return(msg, "as", @as(c_uint, 2), "actions", "body");
    }

    fn handleGetServerInformation(self: *NotificationServer, msg: *bc.sd_bus_message) void {
        _ = self;
        _ = bc.sd_bus_reply_method_return(
            msg,
            "ssss",
            @as([*:0]const u8, "mist-notifications"),
            @as([*:0]const u8, "mist"),
            @as([*:0]const u8, "1.0"),
            @as([*:0]const u8, "1.2"),
        );
    }

    pub fn dismiss(self: *NotificationServer, id: u32) void {
        var i: usize = 0;
        while (i < self.list_len) {
            if (self.list[i].id == id) {
                if (self.list[i].popup and self.popup_len > 0) self.popup_len -= 1;
                var j = i;
                while (j < self.list_len - 1) : (j += 1) {
                    self.list[j] = self.list[j + 1];
                }
                self.list_len -= 1;
                if (self.unread > 0) self.unread -= 1;
                self.changed = true;
                return;
            }
            i += 1;
        }
    }

    pub fn dismissAll(self: *NotificationServer) void {
        self.list_len = 0;
        self.unread = 0;
        self.popup_len = 0;
        self.changed = true;
    }

    pub fn markAllRead(self: *NotificationServer) void {
        self.unread = 0;
        self.changed = true;
    }

    pub fn timeoutExpiredPopups(self: *NotificationServer, now_ms: i64) void {
        for (0..self.list_len) |i| {
            if (self.list[i].popup and now_ms >= self.list[i].popup_timeout_ms) {
                self.list[i].popup = false;
                if (self.popup_len > 0) self.popup_len -= 1;
                self.changed = true;
            }
        }
    }

    pub fn timeoutAllPopups(self: *NotificationServer) void {
        for (0..self.list_len) |i| {
            if (self.list[i].popup) {
                self.list[i].popup = false;
            }
        }
        self.popup_len = 0;
        self.changed = true;
    }

    fn copyZ(dest: *[256]u8, src: ?[*:0]const u8) usize {
        if (src) |s| {
            const span = std.mem.span(s);
            const len = @min(span.len, dest.len - 1);
            @memcpy(dest[0..len], span[0..len]);
            dest[len] = 0;
            return len;
        }
        dest[0] = 0;
        return 0;
    }

    fn copyZ64(dest: *[64]u8, src: ?[*:0]const u8) usize {
        if (src) |s| {
            const span = std.mem.span(s);
            const len = @min(span.len, dest.len - 1);
            @memcpy(dest[0..len], span[0..len]);
            dest[len] = 0;
            return len;
        }
        dest[0] = 0;
        return 0;
    }

    fn copyZ32(dest: *[32]u8, src: ?[*:0]const u8) usize {
        if (src) |s| {
            const span = std.mem.span(s);
            const len = @min(span.len, dest.len - 1);
            @memcpy(dest[0..len], span[0..len]);
            dest[len] = 0;
            return len;
        }
        dest[0] = 0;
        return 0;
    }

    fn copyZ512(dest: *[512]u8, src: ?[*:0]const u8) usize {
        if (src) |s| {
            const span = std.mem.span(s);
            const len = @min(span.len, dest.len - 1);
            @memcpy(dest[0..len], span[0..len]);
            dest[len] = 0;
            return len;
        }
        dest[0] = 0;
        return 0;
    }
};

pub fn formatRelativeTime(ts_ms: i64, now_ms: i64, buf: []u8) []const u8 {
    const diff_ms = now_ms - ts_ms;
    if (diff_ms < 0) return "now";
    const secs = @divTrunc(diff_ms, 1000);
    if (secs < 5) return "now";
    if (secs < 60) {
        return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "now";
    }
    const mins = @divTrunc(secs, 60);
    if (mins < 60) {
        return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "now";
    }
    const hrs = @divTrunc(mins, 60);
    if (hrs < 24) {
        return std.fmt.bufPrint(buf, "{d}h", .{hrs}) catch "now";
    }
    const days = @divTrunc(hrs, 24);
    return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "now";
}
