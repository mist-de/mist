const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const wp = wayland.client.wp;
const ext = wayland.client.ext;
const zriver = wayland.client.zriver;
const zdwl = wayland.client.zdwl;

const config_mod = @import("config.zig");
const cc = @import("c.zig").c;
const ResourceState = config_mod.ResourceState;
const Appearance = config_mod.Appearance;
const mpris_mod = @import("mpris.zig");
const MediaPopup = @import("media_popup.zig").MediaPopup;
const NotificationPanel = @import("notification_popup.zig").NotificationPanel;
const notif_mod = @import("notifications.zig");
const sidebar_mod = @import("sidebar.zig");
const ipc_mod = @import("ipc.zig");

pub const CursorShape = wp.CursorShapeDeviceV1.Shape;

pub const max_outputs = 8;

pub const OutputIndex = enum(u8) {
    none = 0xFF,
    _0 = 0,
    _1,
    _2,
    _3,
    _4,
    _5,
    _6,
    _7,
};

pub const OutputInfo = struct {
    output: *wl.Output,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    name: [64]u8 = .{0} ** 64,
};

pub const max_toplevels = 32;

pub const ToplevelInfo = struct {
    handle: *zwlr.ForeignToplevelHandleV1,
    title: [256]u8 = .{0} ** 256,
    app_id: [256]u8 = .{0} ** 256,
};

pub const WorkspaceInfo = struct {
    handle: *ext.WorkspaceHandleV1,
    name: [128]u8 = .{0} ** 128,
    active: bool = false,
};

pub const Context = struct {
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    sub_compositor: ?*wl.Subcompositor = null,
    shm: ?*wl.Shm = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    foreign_toplevel: ?*zwlr.ForeignToplevelManagerV1 = null,
    workspace_manager: ?*ext.WorkspaceManagerV1 = null,
    seat: ?*wl.Seat = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    xkb_ctx: ?*cc.xkb_context = null,
    xkb_keymap: ?*cc.xkb_keymap = null,
    xkb_state: ?*cc.xkb_state = null,
    river_control: ?*zriver.ControlV1 = null,
    dwl_ipc_manager: ?*zdwl.IpcManagerV2 = null,
    dwl_ipc_output: ?*zdwl.IpcOutputV2 = null,

    outputs: [max_outputs]OutputInfo = undefined,
    output_count: usize = 0,
    running: bool = true,

    last_enter_serial: u32 = 0,
    last_enter_surface: ?*wl.Surface = null,
    pointer_surface: ?*wl.Surface = null,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    popup_surface: ?*wl.Surface = null,

    toplevels: [max_toplevels]ToplevelInfo = undefined,
    toplevel_count: usize = 0,
    active_toplevel: ?usize = null,

    workspaces: [16]WorkspaceInfo = undefined,
    workspace_count: usize = 0,
    active_workspace: ?usize = null,

    bar_dirty: bool = false,
    resources: ResourceState = .{},

    now_ms: i64 = 0,

    scroll_accum: i32 = 0,
    dwl_ipc_active_tag: ?u32 = null,

    media_popup: MediaPopup = .{},
    notification_popup: NotificationPanel = .{},
    notifications: notif_mod.NotificationServer = .{},
    sidebar: sidebar_mod.Sidebar = .{},
    ipc: ipc_mod.IpcServer = .{},
    sidebar_open: bool = false,
    bar_surface: ?*wl.Surface = null,

    mpris: ?*mpris_mod.MprisPlayer = null,
    media_area_x0: i32 = 0,
    media_area_x1: i32 = 0,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, self: *Context) !void {
        const display = try wl.Display.connect(null);
        self.* = Context{
            .display = display,
            .registry = try display.getRegistry(),
            .allocator = allocator,
        };

        self.registry.setListener(*Context, registryListener, self);
        self.roundtrip();

        if (self.foreign_toplevel) |ftm| {
            ftm.setListener(*Context, foreignToplevelManagerListener, self);
        }

        if (self.workspace_manager) |wsm| {
            wsm.setListener(*Context, workspaceManagerListener, self);
        }

        if (self.dwl_ipc_manager) |mgr| {
            if (self.output_count > 0) {
                self.dwl_ipc_output = mgr.getOutput(self.outputs[0].output) catch null;
                if (self.dwl_ipc_output) |dwl_out| {
                    std.log.info("  -> dwl_ipc_output bound", .{});
                    dwl_out.setListener(*Context, dwlIpcOutputListener, self);
                }
            }
            mgr.release();
            self.dwl_ipc_manager = null;
        }

        // Second roundtrip done by caller after seat listener is set (see main.zig)
    }

    pub fn deinit(self: *Context) void {
        self.display.disconnect();
    }

    pub fn roundtrip(self: *Context) void {
        _ = self.display.roundtrip();
    }

    pub fn flush(self: *Context) void {
        _ = self.display.flush();
    }

    pub fn dispatch(self: *Context) void {
        _ = self.display.dispatch();
    }

    pub fn getFd(self: *Context) i32 {
        return self.display.getFd();
    }
};

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, ctx: *Context) void {
    switch (event) {
        .global => |global| {
            const iface = std.mem.span(global.interface);
            std.log.info("registry global: '{s}' ver={d}", .{ iface, global.version });
            if (std.mem.eql(u8, iface, std.mem.span(wl.Compositor.interface.name))) {
                ctx.compositor = registry.bind(global.name, wl.Compositor, global.version) catch null;
                std.log.info("  -> compositor={any}", .{ctx.compositor});
            } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
                ctx.sub_compositor = registry.bind(global.name, wl.Subcompositor, global.version) catch null;
                std.log.info("  -> sub_compositor={any}", .{ctx.sub_compositor});
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Shm.interface.name))) {
                ctx.shm = registry.bind(global.name, wl.Shm, global.version) catch null;
                std.log.info("  -> shm={any}", .{ctx.shm});
            } else if (std.mem.eql(u8, iface, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                ctx.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, @min(global.version, 5)) catch null;
                std.log.info("  -> layer_shell={any}", .{ctx.layer_shell});
            } else if (std.mem.eql(u8, iface, std.mem.span(wp.CursorShapeManagerV1.interface.name))) {
                ctx.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, global.version) catch null;
            } else if (std.mem.eql(u8, iface, std.mem.span(zwlr.ForeignToplevelManagerV1.interface.name))) {
                ctx.foreign_toplevel = registry.bind(global.name, zwlr.ForeignToplevelManagerV1, global.version) catch null;
            } else if (std.mem.eql(u8, iface, std.mem.span(ext.WorkspaceManagerV1.interface.name))) {
                ctx.workspace_manager = registry.bind(global.name, ext.WorkspaceManagerV1, global.version) catch null;
            } else if (std.mem.eql(u8, iface, std.mem.span(zriver.ControlV1.interface.name))) {
                ctx.river_control = registry.bind(global.name, zriver.ControlV1, 1) catch null;
                std.log.info("  -> river_control={any}", .{ctx.river_control});
            } else if (std.mem.eql(u8, iface, std.mem.span(zdwl.IpcManagerV2.interface.name))) {
                ctx.dwl_ipc_manager = registry.bind(global.name, zdwl.IpcManagerV2, 1) catch null;
                if (ctx.dwl_ipc_manager != null) {
                    std.log.info("  -> dwl_ipc_manager bound", .{});
                } else {
                    std.log.warn("  -> dwl_ipc_manager bind FAILED", .{});
                }
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Seat.interface.name))) {
                ctx.seat = registry.bind(global.name, wl.Seat, @min(global.version, 8)) catch null;
                std.log.info("  -> seat={any}", .{ctx.seat});
            } else if (std.mem.eql(u8, iface, std.mem.span(wl.Output.interface.name))) {
                if (ctx.output_count < max_outputs) {
                    const output = registry.bind(global.name, wl.Output, global.version) catch null;
                    if (output) |o| {
                        const info = &ctx.outputs[ctx.output_count];
                        info.* = .{ .output = o };
                        o.setListener(*Context, outputListener, ctx);
                        ctx.output_count += 1;
                        std.log.info("  -> output #{d} bound: info={*} output={any}", .{ ctx.output_count - 1, info, o });
                    } else {
                        std.log.warn("  -> output bind FAILED", .{});
                    }
                }
            } else {
                std.log.info("  -> ignored", .{});
            }
        },
        .global_remove => |remove| {
            _ = remove;
        },
    }
}

fn outputListener(output: *wl.Output, event: wl.Output.Event, ctx: *Context) void {
    std.log.info("outputListener: ctx.outputs[0].output={any} event_output={any} output_count={d}", .{
        if (ctx.output_count > 0) ctx.outputs[0].output else null,
        output,
        ctx.output_count,
    });
    const info = for (0..ctx.output_count) |i| {
        if (ctx.outputs[i].output == output) break &ctx.outputs[i];
    } else {
        std.log.warn("output event from unknown output", .{});
        return;
    };

    switch (event) {
        .geometry => |geo| {
            std.log.info("output geometry: {d}x{d} (info ptr={*})", .{ geo.physical_width, geo.physical_height, info });
        },
        .mode => |mode| {
            info.mode_w = mode.width;
            info.mode_h = mode.height;
            std.log.info("output mode: {d}x{d} -> info.mode_w={d}", .{ mode.width, mode.height, info.mode_w });
        },
        .name => |name_ev| {
            const name_src = std.mem.sliceTo(name_ev.name, 0);
            const name_len = @min(name_src.len, info.name.len - 1);
            @memcpy(info.name[0..name_len], name_src[0..name_len]);
            info.name[name_len] = 0;
            std.log.info("output name: '{s}' info.name='{s}'", .{ name_src, std.mem.sliceTo(&info.name, 0) });
        },
        .scale => |scale_ev| {
            std.log.info("output scale: {d}", .{scale_ev.factor});
        },
        .description, .done => {},
    }
}

fn foreignToplevelManagerListener(manager: *zwlr.ForeignToplevelManagerV1, event: zwlr.ForeignToplevelManagerV1.Event, ctx: *Context) void {
    _ = manager;
    switch (event) {
        .toplevel => |ev| {
            if (ctx.toplevel_count >= max_toplevels) return;
            const info = &ctx.toplevels[ctx.toplevel_count];
            info.* = .{ .handle = ev.toplevel };
            ev.toplevel.setListener(*Context, toplevelHandleListener, ctx);
            ctx.toplevel_count += 1;
            ctx.bar_dirty = true;
            std.log.info("foreign toplevel: new handle #{d}", .{ctx.toplevel_count - 1});
        },
        .finished => {
            ctx.foreign_toplevel = null;
            ctx.bar_dirty = true;
        },
    }
}

fn toplevelHandleListener(handle: *zwlr.ForeignToplevelHandleV1, event: zwlr.ForeignToplevelHandleV1.Event, ctx: *Context) void {
    const idx = for (0..ctx.toplevel_count) |i| {
        if (ctx.toplevels[i].handle == handle) break i;
    } else return;

    const info = &ctx.toplevels[idx];
    switch (event) {
        .title => |ev| {
            const src = std.mem.sliceTo(ev.title, 0);
            const len = @min(src.len, info.title.len - 1);
            @memcpy(info.title[0..len], src[0..len]);
            info.title[len] = 0;
            ctx.bar_dirty = true;
            std.log.info("toplevel title: '{s}'", .{src});
        },
        .app_id => |ev| {
            const src = std.mem.sliceTo(ev.app_id, 0);
            const len = @min(src.len, info.app_id.len - 1);
            @memcpy(info.app_id[0..len], src[0..len]);
            info.app_id[len] = 0;
            ctx.bar_dirty = true;
            std.log.info("toplevel app_id: '{s}'", .{src});
        },
        .state => |ev| {
            // State: 0=maximized, 1=minimized, 2=fullscreen, 3=active
            var is_active = false;
            const states = ev.state.data orelse return;
            const state_bytes = @as([*]const u8, @ptrCast(states))[0..ev.state.size];
            var i: usize = 0;
            while (i + 4 <= state_bytes.len) : (i += 4) {
                const state_val = std.mem.readInt(u32, state_bytes[i..][0..4], .little);
                if (state_val == 3) is_active = true; // 3 = active
            }
            if (is_active) {
                ctx.active_toplevel = idx;
            } else if (ctx.active_toplevel == idx) {
                ctx.active_toplevel = null;
            }
            ctx.bar_dirty = true;
        },
        .done => {},
        .closed => {
            ctx.bar_dirty = true;
            if (ctx.active_toplevel == idx) ctx.active_toplevel = null;
            var j = idx;
            while (j + 1 < ctx.toplevel_count) : (j += 1) {
                ctx.toplevels[j] = ctx.toplevels[j + 1];
            }
            ctx.toplevel_count -= 1;
            if (ctx.active_toplevel) |at| {
                if (at > idx) ctx.active_toplevel = at - 1;
            }
            handle.destroy();
        },
        .output_enter, .output_leave, .parent => {},
    }
}

/// Listen to dwl-ipc output tag events to track the active tag.
/// Tag events arrive in a batch; active_workspace is committed on the frame event.
fn dwlIpcOutputListener(_: *zdwl.IpcOutputV2, event: zdwl.IpcOutputV2.Event, ctx: *Context) void {
    switch (event) {
        .tag => |ev| {
            // TagState is bitmask: bit 0 = active, bit 1 = urgent
            const state_val: c_int = @intFromEnum(ev.state);
            if (state_val & 1 != 0) {
                ctx.dwl_ipc_active_tag = ev.tag;
            }
        },
        .frame => {
            if (ctx.dwl_ipc_active_tag) |tag| {
                if (tag < ctx.workspace_count) {
                    ctx.active_workspace = tag;
                }
                ctx.bar_dirty = true;
            }
            ctx.dwl_ipc_active_tag = null;
        },
        else => {},
    }
}

fn workspaceManagerListener(manager: *ext.WorkspaceManagerV1, event: ext.WorkspaceManagerV1.Event, ctx: *Context) void {
    _ = manager;
    switch (event) {
        .workspace => |ev| {
            if (ctx.workspace_count >= 16) return;
            const info = &ctx.workspaces[ctx.workspace_count];
            info.* = .{ .handle = ev.workspace };
            ev.workspace.setListener(*Context, workspaceHandleListener, ctx);
            ctx.workspace_count += 1;
            ctx.bar_dirty = true;
            std.log.info("workspace: new handle #{d}", .{ctx.workspace_count - 1});
        },
        .workspace_group, .done, .finished => {},
    }
}

fn workspaceHandleListener(handle: *ext.WorkspaceHandleV1, event: ext.WorkspaceHandleV1.Event, ctx: *Context) void {
    const idx = for (0..ctx.workspace_count) |i| {
        if (ctx.workspaces[i].handle == handle) break i;
    } else return;

    const info = &ctx.workspaces[idx];
    switch (event) {
        .name => |ev| {
            const src = std.mem.sliceTo(ev.name, 0);
            const len = @min(src.len, info.name.len - 1);
            @memcpy(info.name[0..len], src[0..len]);
            info.name[len] = 0;
            ctx.bar_dirty = true;
        },
        .state => |ev| {
            info.active = ev.state.active;
            if (ev.state.active) {
                ctx.active_workspace = idx;
            } else if (ctx.active_workspace == idx) {
                ctx.active_workspace = null;
            }
            ctx.bar_dirty = true;
        },
        .id => ctx.bar_dirty = true,
        .removed => {
            ctx.bar_dirty = true;
            handle.destroy();
            var j = idx;
            while (j + 1 < ctx.workspace_count) : (j += 1) {
                ctx.workspaces[j] = ctx.workspaces[j + 1];
            }
            ctx.workspace_count -= 1;
            if (ctx.active_workspace) |aw| {
                if (aw == idx) {
                    ctx.active_workspace = null;
                } else if (aw > idx) {
                    ctx.active_workspace = aw - 1;
                }
            }
        },
        .capabilities, .coordinates => {},
    }
}

pub const LayerSurface = struct {
    surface: *wl.Surface,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    frame_cb: ?*wl.Callback = null,
    configured: bool = false,
    width: i32 = 0,
    height: i32 = 0,

    pub fn create(ctx: *Context, output_info: *OutputInfo, anchor: zwlr.LayerSurfaceV1.Anchor, height: u32) !LayerSurface {
        const compositor = ctx.compositor orelse return error.NoCompositor;
        const layer_shell = ctx.layer_shell orelse return error.NoLayerShell;

        const surface = try compositor.createSurface();
        const layer = try layer_shell.getLayerSurface(
            surface,
            output_info.output,
            .top,
            "mist-bar",
        );

        layer.setSize(0, height);
        layer.setAnchor(anchor);
        // Bar exclusive zone = bar height only (40px). No Hyprland gaps in MangoWM/Niri.
        // The gap is handled by the sidebar's own offset below.
        layer.setExclusiveZone(@intCast(Appearance.bar_height));
        layer.setKeyboardInteractivity(.none);

        surface.commit();

        return LayerSurface{
            .surface = surface,
            .layer_surface        = layer,
        };
    }

    pub fn destroy(self: *LayerSurface) void {
        if (self.frame_cb) |cb| cb.destroy();
        if (self.layer_surface) |ls| ls.destroy();
        self.surface.destroy();
        self.* = undefined;
    }
};

pub const ShmBuffer = struct {
    buffer: ?*wl.Buffer = null,
    data: []align(std.heap.page_size_min) u8 = &.{},
    width: i32 = 0,
    height: i32 = 0,
    stride: i32 = 0,

    pub fn create(shm: *wl.Shm, w: i32, h: i32) !ShmBuffer {
        const raw_stride = w * 4;
        const stride = (raw_stride + 255) & ~@as(i32, 255);
        const pool_size = @as(usize, @intCast(stride * h));
        const fd = try createFile(pool_size);
        const pool = try shm.createPool(fd, @intCast(pool_size));
        const data = try std.posix.mmap(
            null,
            pool_size,
            std.posix.PROT{ .READ = true, .WRITE = true },
            std.posix.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );
        _ = std.c.close(fd);

        @memset(data, 0);

        const buf = try pool.createBuffer(0, w, h, stride, wl.Shm.Format.argb8888);
        pool.destroy();

        return ShmBuffer{
            .buffer = buf,
            .data = data,
            .width = w,
            .height = h,
            .stride = stride,
        };
    }

    pub fn deinit(self: *ShmBuffer) void {
        std.posix.munmap(self.data);
        if (self.buffer) |b| b.destroy();
        self.* = undefined;
    }
};

pub fn setCursorShape(ctx: *Context, serial: u32, shape: CursorShape) void {
    if (ctx.cursor_shape_manager == null) return;
    if (ctx.pointer) |ptr| {
        const dev = ctx.cursor_shape_manager.?.getPointer(ptr) catch |err| {
            std.log.warn("cursor shape: {s}", .{@errorName(err)});
            return;
        };
        defer dev.destroy();
        dev.setShape(serial, shape);
    }
}

fn createFile(size: usize) !i32 {
    const fd = try std.posix.memfd_create("wl-shm", 0);
    _ = std.c.ftruncate(fd, @intCast(size));
    return fd;
}
