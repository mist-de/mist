const std = @import("std");
const Wayland = @import("wayland.zig");
const wl = Wayland.wl;
const ext = Wayland.ext;
const zdwl = Wayland.zdwl;

const log = std.log.scoped(.Workspace);

const max_tags = 9;

const Backend = enum {
    none,
    dwl_ipc,
    ext_workspace,
    external,
};

pub const TagState = struct {
    active: u32 = 0,
    urgent: u32 = 0,
    tag_count: u8 = 5,
};

pub var tag_state: TagState = .{};
var backend: Backend = .none;

pub fn detect(wayland: *Wayland) void {
    if (wayland.dwl_ipc_manager != null) {
        backend = .dwl_ipc;
        log.info("backend: dwl-ipc (MangoWM)", .{});
    } else if (wayland.ext_workspace_manager != null) {
        backend = .ext_workspace;
        log.info("backend: ext-workspace (Niri)", .{});
    } else {
        backend = .external;
        log.info("backend: external CLI (River)", .{});
    }
}

pub fn switchToTag(tag: u8) void {
    const system = struct { extern "c" fn system(cmd: [*:0]const u8) c_int; };
    var buf: [128]u8 = undefined;
    const mask = @as(u32, 1) << @as(u5, @intCast(tag));
    const cmd = std.fmt.bufPrintZ(
        &buf,
        "riverctl set-focused-tags {d} 2>/dev/null || wlrctl workspace {d} 2>/dev/null",
        .{ mask, tag + 1 },
    ) catch return;
    _ = system.system(cmd);
}

pub fn onDwlTags(amount: u32) void {
    tag_state.tag_count = @as(u8, @intCast(@min(amount, max_tags)));
    tag_state.active = 0;
    tag_state.urgent = 0;
}

pub fn onDwlTagUpdate(tag: u32, state_flags: u32, _: u32, _: u32) void {
    const mask = @as(u32, 1) << @as(u5, @intCast(tag));
    if (state_flags & 1 != 0) {
        tag_state.active |= mask;
    } else {
        tag_state.active &= ~mask;
    }
    if (state_flags & 2 != 0) {
        tag_state.urgent |= mask;
    } else {
        tag_state.urgent &= ~mask;
    }
}

pub fn isTagActive(tag: u8) bool {
    const mask = @as(u32, 1) << @as(u5, @intCast(tag));
    return (tag_state.active & mask) != 0;
}

pub fn isTagUrgent(tag: u8) bool {
    const mask = @as(u32, 1) << @as(u5, @intCast(tag));
    return (tag_state.urgent & mask) != 0;
}
