const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("basu/sd-bus.h");
});

const log = std.log.scoped(.battery);

pub const State = struct {
    percentage: f64 = -1,
    charging: bool = false,
    available: bool = false,
};

var bus: ?*c.sd_bus = null;
var battery_path: [256:0]u8 = @splat(0);
var battery_len: usize = 0;
pub var state: State = .{};

threadlocal var poll_count: u64 = 0;

pub fn init() void {
    var b: ?*c.sd_bus = null;
    if (c.sd_bus_open_system(&b) < 0) {
        log.warn("failed to open system bus", .{});
        return;
    }
    bus = b;

    var reply: ?*c.sd_bus_message = null;
    const rc = c.sd_bus_call_method(
        b,
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower",
        "org.freedesktop.UPower",
        "EnumerateDevices",
        null,
        &reply,
        null,
    );
    if (rc < 0) {
        log.warn("UPower not available", .{});
        return;
    }

    if (c.sd_bus_message_enter_container(reply, 'a', "o") >= 0) {
        var path: [*:0]u8 = undefined;
        while (c.sd_bus_message_read(reply, "o", &path) > 0) {
            const len = std.mem.len(path);
            if (len == 0) continue;
            const slice = path[0..len];
            if (std.mem.indexOf(u8, slice, "BAT") != null or std.mem.indexOf(u8, slice, "battery") != null) {
                @memcpy(battery_path[0..len], slice);
                battery_path[len] = 0;
                battery_len = len;
                break;
            }
        }
        _ = c.sd_bus_message_exit_container(reply);
    }

    _ = c.sd_bus_message_unref(reply);

    if (battery_len > 0) {
        refresh();
        state.available = true;
        log.info("found battery device: {s}, {d:.0}%", .{ battery_path[0..battery_len], state.percentage });
    } else {
        log.info("no battery device found", .{});
    }
}

pub fn refresh() void {
    const b = bus orelse return;
    if (battery_len == 0) return;

    var reply: ?*c.sd_bus_message = null;
    const rc = c.sd_bus_call_method(
        b,
        "org.freedesktop.UPower",
        &battery_path,
        "org.freedesktop.DBus.Properties",
        "Get",
        null,
        &reply,
        "ss",
        "org.freedesktop.UPower.Device",
        "Percentage",
    );
    if (rc >= 0) {
        if (c.sd_bus_message_enter_container(reply, 'v', "d") >= 0) {
            var pct: f64 = 0;
            if (c.sd_bus_message_read(reply, "d", &pct) >= 0) {
                state.percentage = pct;
            }
            _ = c.sd_bus_message_exit_container(reply);
        }
        _ = c.sd_bus_message_unref(reply);
    }

    var reply2: ?*c.sd_bus_message = null;
    const rc2 = c.sd_bus_call_method(
        b,
        "org.freedesktop.UPower",
        &battery_path,
        "org.freedesktop.DBus.Properties",
        "Get",
        null,
        &reply2,
        "ss",
        "org.freedesktop.UPower.Device",
        "State",
    );
    if (rc2 >= 0) {
        if (c.sd_bus_message_enter_container(reply2, 'v', "u") >= 0) {
            var st: u32 = 0;
            if (c.sd_bus_message_read(reply2, "u", &st) >= 0) {
                state.charging = st == 1;
            }
            _ = c.sd_bus_message_exit_container(reply2);
        }
        _ = c.sd_bus_message_unref(reply2);
    }
}

pub fn getFd() posix.fd_t {
    const b = bus orelse return -1;
    return c.sd_bus_get_fd(b);
}

pub fn process() void {
    const b = bus orelse return;
    _ = c.sd_bus_process(b, null);
    poll_count += 1;
    if (poll_count % 50 == 0) {
        refresh();
    }
}

pub fn deinit() void {
    if (bus) |b| {
        _ = c.sd_bus_close(b);
        _ = c.sd_bus_unref(b);
        bus = null;
    }
}
