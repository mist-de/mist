const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wayland_mod = blk: {
        const zig_wayland = @import("zig_wayland");
        const scanner = zig_wayland.Scanner.create(b, .{});

        // System protocols from wayland-protocols
        scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
        scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
        scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
        scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
        scanner.addSystemProtocol("staging/ext-workspace/ext-workspace-v1.xml");

        // Custom protocols (vendored)
        scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
        scanner.addCustomProtocol(b.path("protocols/river-window-management-v1.xml"));
        scanner.addCustomProtocol(b.path("protocols/wlr-foreign-toplevel-management-unstable-v1.xml"));
        scanner.addCustomProtocol(b.path("protocols/dwl-ipc-unstable-v2.xml"));

        scanner.generate("wl_compositor", 5);
        scanner.generate("wl_shm", 1);
        scanner.generate("wl_seat", 7);
        scanner.generate("wl_output", 4);
        scanner.generate("wl_data_device_manager", 3);
        scanner.generate("xdg_wm_base", 6);
        scanner.generate("ext_session_lock_manager_v1", 1);
        scanner.generate("wp_cursor_shape_manager_v1", 1);
        scanner.generate("zwlr_layer_shell_v1", 4);
        scanner.generate("river_window_manager_v1", 5);
        scanner.generate("zwlr_foreign_toplevel_manager_v1", 3);
        scanner.generate("ext_workspace_manager_v1", 1);
        scanner.generate("zdwl_ipc_manager_v2", 2);

        break :blk b.createModule(.{
            .root_source_file = scanner.result,
            .target = target,
            .optimize = optimize,
        });
    };

    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell_mod.addImport("wayland", wayland_mod);

    const shell_exe = b.addExecutable(.{
        .name = "mist-shell",
        .root_module = shell_mod,
    });

    const mod = shell_exe.root_module;
    mod.link_libc = true;
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("freetype", .{});
    mod.linkSystemLibrary("harfbuzz", .{});
    mod.linkSystemLibrary("basu", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    mod.linkSystemLibrary("fontconfig", .{});

    b.installArtifact(shell_exe);

    const run_cmd = b.addRunArtifact(shell_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Mist shell");
    run_step.dependOn(&run_cmd.step);
}
