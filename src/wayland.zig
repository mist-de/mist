const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland_lib = @import("wayland");
pub const wl = wayland_lib.client.wl;
pub const zwlr = wayland_lib.client.zwlr;
pub const wp = wayland_lib.client.wp;
pub const ext = wayland_lib.client.ext;
pub const zdwl = wayland_lib.client.zdwl;

const workspace = @import("workspace.zig");
const Output = @import("output.zig");
const seat_utils = @import("seat.zig");

const log = std.log.scoped(.Wayland);

pub const Wayland = @This();

pub const NAMESPACE: [:0]const u8 = "mist-bar";
pub const max_outputs = 8;

pub const OutputIndex = enum(u8) {
    none = 255,
    _,

    pub fn fromInt(idx: usize) OutputIndex {
        return @enumFromInt(@as(u8, @intCast(idx)));
    }
};

pub const CursorShape = wp.CursorShapeDeviceV1.Shape;
pub const max_toplevels = 32;

const ToplevelEntry = struct {
    handle: *zwlr.ForeignToplevelHandleV1,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    is_activated: bool = false,
};

display: *wl.Display,
registry: *wl.Registry,
compositor: ?*wl.Compositor,
shm: ?*wl.Shm,
layer_shell: ?*zwlr.LayerShellV1,
seat: ?*wl.Seat,
cursor_shape_manager: ?*wp.CursorShapeManagerV1,

foreign_toplevel_manager: ?*zwlr.ForeignToplevelManagerV1 = null,
focused_title: [256]u8 = undefined,
focused_title_len: usize = 0,

dwl_ipc_manager: ?*zdwl.IpcManagerV2 = null,
dwl_ipc_outputs: [max_outputs]?*zdwl.IpcOutputV2 = [_]?*zdwl.IpcOutputV2{null} ** max_outputs,
ext_workspace_manager: ?*ext.WorkspaceManagerV1 = null,

outputs: [max_outputs]Output = undefined,
output_count: usize = 0,

running: bool = true,

pointer: ?*wl.Pointer = null,
last_motion_surface: OutputIndex = .none,
last_enter_serial: u32 = 0,
last_cursor_shape: ?CursorShape = null,
pointer_over_popup: bool = false,

toplevel_entries: [max_toplevels]ToplevelEntry = undefined,
toplevel_count: usize = 0,

pub fn init(self: *Wayland) !void {
    const display = try wl.Display.connect(null);
    errdefer display.disconnect();
    const registry = try display.getRegistry();

    self.* = .{
        .display = display,
        .registry = registry,
        .compositor = null,
        .shm = null,
        .layer_shell = null,
        .seat = null,
        .cursor_shape_manager = null,
        .foreign_toplevel_manager = null,
        .focused_title = undefined,
        .focused_title_len = 0,
        .dwl_ipc_manager = null,
        .dwl_ipc_outputs = [_]?*zdwl.IpcOutputV2{null} ** max_outputs,
        .ext_workspace_manager = null,
        .outputs = undefined,
        .output_count = 0,
        .running = true,
        .pointer = null,
        .last_motion_surface = .none,
        .last_enter_serial = 0,
        .last_cursor_shape = null,
        .pointer_over_popup = false,
        .toplevel_entries = undefined,
        .toplevel_count = 0,
    };

    registry.setListener(*Wayland, registryListener, self);
    _ = display.roundtrip();

    workspace.detect(self);

    if (self.compositor == null) return error.NoCompositor;
    if (self.shm == null) return error.NoShm;
    if (self.layer_shell == null) return error.NoLayerShell;

    log.info("Wayland connection established", .{});
}

pub fn deinit(self: *Wayland) void {
    for (self.outputs[0..self.output_count]) |*output| {
        output.deinit();
    }
    self.registry.destroy();
    self.display.disconnect();
}

pub fn dispatch(self: *Wayland) std.posix.E {
    return self.display.dispatch();
}

pub fn roundtrip(self: *Wayland) !void {
    _ = self.display.roundtrip();
}

pub fn findOutput(
    self: *Wayland,
    comptime T: type,
    target: T,
    comptime checker: *const fn (*const Output, T) bool,
) ?*Output {
    for (self.outputs[0..self.output_count]) |*output| {
        if (checker(output, target)) return output;
    }
    return null;
}

pub fn findOutputIndex(
    self: *Wayland,
    comptime T: type,
    target: T,
    comptime checker: *const fn (*const Output, T) bool,
) OutputIndex {
    for (self.outputs[0..self.output_count], 0..) |*output, i| {
        if (checker(output, target)) return OutputIndex.fromInt(i);
    }
    return .none;
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Wayland) void {
    switch (event) {
        .global => |g| {
            if (std.mem.orderZ(u8, g.interface, "wl_compositor") == .eq) {
                self.compositor = registry.bind(g.name, wl.Compositor, @min(g.version, 6)) catch return;
            } else if (std.mem.orderZ(u8, g.interface, "wl_shm") == .eq) {
                self.shm = registry.bind(g.name, wl.Shm, @min(g.version, 1)) catch return;
            } else if (std.mem.orderZ(u8, g.interface, "zwlr_layer_shell_v1") == .eq) {
                self.layer_shell = registry.bind(g.name, zwlr.LayerShellV1, @min(g.version, 4)) catch return;
            } else if (std.mem.orderZ(u8, g.interface, "wl_output") == .eq) {
                const output = registry.bind(g.name, wl.Output, @min(g.version, 4)) catch return;
                onOutputAdded(self, output, g.name);
            } else if (std.mem.orderZ(u8, g.interface, "wl_seat") == .eq) {
                const seat = registry.bind(g.name, wl.Seat, @min(g.version, 7)) catch return;
                self.seat = seat;
                seat.setListener(*Wayland, seat_utils.seatListener, self);
            } else if (std.mem.orderZ(u8, g.interface, "wp_cursor_shape_manager_v1") == .eq) {
                self.cursor_shape_manager = registry.bind(g.name, wp.CursorShapeManagerV1, @min(g.version, 1)) catch return;
            } else if (std.mem.orderZ(u8, g.interface, "zwlr_foreign_toplevel_manager_v1") == .eq) {
                self.foreign_toplevel_manager = registry.bind(g.name, zwlr.ForeignToplevelManagerV1, @min(g.version, 3)) catch return;
                self.foreign_toplevel_manager.?.setListener(*Wayland, toplevelManagerListener, self);
            } else if (std.mem.orderZ(u8, g.interface, "zdwl_ipc_manager_v2") == .eq) {
                self.dwl_ipc_manager = registry.bind(g.name, zdwl.IpcManagerV2, @min(g.version, 2)) catch return;
                self.dwl_ipc_manager.?.setListener(*Wayland, dwlIpcManagerListener, self);
            } else if (std.mem.orderZ(u8, g.interface, "ext_workspace_manager_v1") == .eq) {
                self.ext_workspace_manager = registry.bind(g.name, ext.WorkspaceManagerV1, @min(g.version, 1)) catch return;
                self.ext_workspace_manager.?.setListener(*Wayland, extWorkspaceManagerListener, self);
            }
        },
        .global_remove => |remove| {
            for (self.outputs[0..self.output_count], 0..) |*output, i| {
                if (output.output_context.id == remove.name) {
                    output.deinit();
                    if (self.dwl_ipc_outputs[i]) |dwl_out| {
                        dwl_out.destroy();
                    }
                    std.mem.copyForwards(Output, self.outputs[i..], self.outputs[i + 1 .. self.output_count]);
                    std.mem.copyForwards(?*zdwl.IpcOutputV2, self.dwl_ipc_outputs[i..], self.dwl_ipc_outputs[i + 1 .. self.output_count]);
                    self.output_count -= 1;
                    return;
                }
            }
        },
    }
}

fn onOutputAdded(self: *Wayland, wl_output: *wl.Output, name: u32) void {
    if (self.output_count >= max_outputs) {
        log.warn("Max outputs reached ({}), ignoring new output", .{max_outputs});
        return;
    }

    const idx = self.output_count;
    self.outputs[idx] = Output.init(.{
        .output = wl_output,
        .id = name,
        .wayland_context = self,
    }) catch |err| {
        log.warn("Failed to initialize output: {s}", .{@errorName(err)});
        return;
    };

    if (self.dwl_ipc_manager) |mgr| {
        self.dwl_ipc_outputs[idx] = mgr.getOutput(wl_output) catch null;
        if (self.dwl_ipc_outputs[idx]) |dwl_out| {
            dwl_out.setListener(*Wayland, dwlIpcOutputListener, self);
        }
    }

    self.output_count += 1;
    log.info("Output added: {} (total: {})", .{ name, self.output_count });
}

fn addToplevelEntry(self: *Wayland, handle: *zwlr.ForeignToplevelHandleV1) void {
    if (self.toplevel_count >= max_toplevels) {
        log.warn("Max toplevels reached, ignoring", .{});
        return;
    }
    self.toplevel_entries[self.toplevel_count] = .{ .handle = handle };
    self.toplevel_count += 1;
}

fn findToplevelEntry(self: *Wayland, handle: *zwlr.ForeignToplevelHandleV1) ?*ToplevelEntry {
    for (self.toplevel_entries[0..self.toplevel_count]) |*e| {
        if (e.handle == handle) return e;
    }
    return null;
}

fn removeToplevelEntry(self: *Wayland, handle: *zwlr.ForeignToplevelHandleV1) void {
    for (self.toplevel_entries[0..self.toplevel_count], 0..) |*e, i| {
        if (e.handle == handle) {
            if (i + 1 < self.toplevel_count) {
                std.mem.copyForwards(ToplevelEntry, self.toplevel_entries[i..], self.toplevel_entries[i + 1 .. self.toplevel_count]);
            }
            self.toplevel_count -= 1;
            return;
        }
    }
}

pub fn getFocusedTitle(self: *Wayland) []const u8 {
    return self.focused_title[0..self.focused_title_len];
}

fn toplevelManagerListener(manager: *zwlr.ForeignToplevelManagerV1, event: zwlr.ForeignToplevelManagerV1.Event, self: *Wayland) void {
    _ = manager;
    switch (event) {
        .toplevel => |ev| {
            const handle = ev.toplevel;
            handle.setListener(*Wayland, toplevelHandleListener, self);
            self.addToplevelEntry(handle);
        },
        .finished => {
            self.foreign_toplevel_manager = null;
        },
    }
}

fn toplevelHandleListener(handle: *zwlr.ForeignToplevelHandleV1, event: zwlr.ForeignToplevelHandleV1.Event, self: *Wayland) void {
    const entry = self.findToplevelEntry(handle) orelse return;
    switch (event) {
        .title => |ev| {
            const title = std.mem.span(ev.title);
            const len = @min(title.len, entry.title_buf.len);
            @memcpy(entry.title_buf[0..len], title[0..len]);
            entry.title_len = len;
        },
        .app_id => {},
        .output_enter => {},
        .output_leave => {},
        .state => |ev| {
            const arr = ev.state;
            if (arr.data == null) return;
            const state_slice: []const u32 = @as([*]const u32, @ptrCast(@alignCast(arr.data.?)))[0..@divExact(arr.size, @sizeOf(u32))];
            entry.is_activated = false;
            for (state_slice) |s| {
                if (s == 2) { // activated
                    entry.is_activated = true;
                }
            }
        },
        .done => {
            if (entry.is_activated) {
                self.focused_title_len = entry.title_len;
                @memcpy(self.focused_title[0..entry.title_len], entry.title_buf[0..entry.title_len]);
            }
        },
        .closed => {
            self.removeToplevelEntry(handle);
            handle.destroy();
        },
        .parent => {},
    }
}

fn dwlIpcManagerListener(_: *zdwl.IpcManagerV2, event: zdwl.IpcManagerV2.Event, _: *Wayland) void {
    switch (event) {
        .tags => |ev| workspace.onDwlTags(ev.amount),
        .layout => {},
    }
}

fn dwlIpcOutputListener(_: *zdwl.IpcOutputV2, event: zdwl.IpcOutputV2.Event, _: *Wayland) void {
    switch (event) {
        .tag => |ev| {
            const state_val: u32 = @intCast(@intFromEnum(ev.state));
            workspace.onDwlTagUpdate(ev.tag, state_val, ev.clients, ev.focused);
        },
        .frame => {},
        else => {},
    }
}

fn extWorkspaceManagerListener(_: *ext.WorkspaceManagerV1, event: ext.WorkspaceManagerV1.Event, self: *Wayland) void {
    switch (event) {
        .workspace_group => {},
        .workspace => {},
        .done => {},
        .finished => self.ext_workspace_manager = null,
    }
}
