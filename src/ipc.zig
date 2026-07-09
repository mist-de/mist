const std = @import("std");
const posix = std.posix;
const cc = @import("c.zig").c;

const max_handlers = 64;
const max_command_size = 64 * 1024;
const max_response_size = 4096;

pub const Handler = struct {
    ptr: *const fn (ctx: *anyopaque, args: []const u8) []const u8,
    ctx: *anyopaque,
};

pub const HandlerEntry = struct {
    command: []const u8,
    handler: Handler,
    usage: []const u8,
    description: []const u8,
};

pub const IpcServer = struct {
    listen_fd: i32 = -1,
    socket_path: [128]u8 = undefined,
    socket_path_len: usize = 0,
    handlers: [max_handlers]HandlerEntry = undefined,
    handler_count: usize = 0,
    response_buf: [max_response_size]u8 = undefined,

    pub fn init(self: *IpcServer) void {
        const runtime = std.c.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
        const display = std.c.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

        const path = std.fmt.bufPrint(&self.socket_path, "{s}/mist-{s}.sock", .{ runtime, display }) catch return;
        self.socket_path_len = path.len;
        self.socket_path[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&self.socket_path);

        // Remove stale socket
        _ = std.c.unlink(path_z);

        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC | std.c.SOCK.NONBLOCK, 0);
        if (fd < 0) {
            std.log.warn("ipc: socket() failed", .{});
            return;
        }

        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = std.c.AF.UNIX;
        const path_bytes = path;
        if (path_bytes.len >= addr.path.len) {
            std.log.warn("ipc: socket path too long", .{});
            _ = std.c.close(fd);
            return;
        }
        @memcpy(addr.path[0..path_bytes.len], path_bytes);
        addr.path[path_bytes.len] = 0;

        const rc = std.c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        if (rc < 0) {
            std.log.warn("ipc: bind() failed", .{});
            _ = std.c.close(fd);
            return;
        }

        if (std.c.listen(fd, 128) < 0) {
            std.log.warn("ipc: listen() failed", .{});
            _ = std.c.close(fd);
            _ = std.c.unlink(path_z);
            return;
        }

        self.listen_fd = fd;
        std.log.info("ipc: listening at {s}", .{path});
    }

    pub fn deinit(self: *IpcServer) void {
        if (self.listen_fd >= 0) {
            _ = std.c.close(self.listen_fd);
            const path_z: [*:0]const u8 = @ptrCast(&self.socket_path);
            _ = std.c.unlink(path_z);
        }
    }

    pub fn getFd(self: *IpcServer) i32 {
        return self.listen_fd;
    }

    pub fn registerHandler(
        self: *IpcServer,
        command: []const u8,
        handler_ptr: *const fn (ctx: *anyopaque, args: []const u8) []const u8,
        handler_ctx: *anyopaque,
        usage: []const u8,
        description: []const u8,
    ) void {
        if (self.handler_count >= max_handlers) {
            std.log.warn("ipc: too many handlers, ignoring '{s}'", .{command});
            return;
        }
        self.handlers[self.handler_count] = .{
            .command = command,
            .handler = .{ .ptr = handler_ptr, .ctx = handler_ctx },
            .usage = usage,
            .description = description,
        };
        self.handler_count += 1;
    }

    pub fn dispatch(self: *IpcServer) void {
        while (true) {
            const conn_fd = std.c.accept4(self.listen_fd, null, null, std.c.SOCK.CLOEXEC);
            if (conn_fd < 0) break;
            defer _ = std.c.close(conn_fd);

            // Read command
            var cmd_buf: [max_command_size]u8 = undefined;
            var pos: usize = 0;
            while (pos < cmd_buf.len) {
                const n = std.c.read(conn_fd, cmd_buf[pos..].ptr, cmd_buf.len - pos);
                if (n < 0) {
                    const err = std.posix.errno(@as(i32, @intCast(-n)));
                    if (err == .INTR) continue;
                    break;
                }
                if (n == 0) break; // EOF
                pos += @as(usize, @intCast(n));
            }
            const command = cmd_buf[0..pos];

            // Find handler
            const space_idx = for (command, 0..) |c, i| {
                if (c == ' ' or c == '\n') break i;
            } else command.len;

            const cmd_name = command[0..space_idx];
            var args: []const u8 = "";
            if (space_idx < command.len) {
                var arg_start = space_idx + 1;
                while (arg_start < command.len and command[arg_start] == ' ') arg_start += 1;
                args = command[arg_start..];
                // Strip trailing newlines
                while (args.len > 0 and (args[args.len - 1] == '\n' or args[args.len - 1] == '\r')) {
                    args = args[0 .. args.len - 1];
                }
            }

            const response = if (std.mem.eql(u8, cmd_name, "--help") or std.mem.eql(u8, cmd_name, "-h"))
                self.buildHelp()
            else if (std.mem.eql(u8, cmd_name, ""))
                "error: empty command\n"
            else blk: {
                const found = for (0..self.handler_count) |i| {
                    if (std.mem.eql(u8, self.handlers[i].command, cmd_name)) {
                        break &self.handlers[i];
                    }
                } else null;

                if (found) |entry| {
                    break :blk entry.handler.ptr(entry.handler.ctx, args);
                } else {
                    break :blk "error: unknown command (try: --help)\n";
                }
            };

            // Write response
            var sent: usize = 0;
            while (sent < response.len) {
                const n = std.c.send(conn_fd, @as([*]const u8, @ptrCast(response.ptr)) + sent, response.len - sent, 0);
                if (n < 0) break;
                sent += @as(usize, @intCast(n));
            }
        }
    }

    fn buildHelp(self: *IpcServer) []const u8 {
        var pos: usize = 0;
        const header = "Usage: mist msg call <command> [args]\n\nCommands:\n";
        @memcpy(self.response_buf[0..header.len], header);
        pos = header.len;

        // Find max usage length
        var max_usage: usize = 0;
        for (0..self.handler_count) |i| {
            const u = if (self.handlers[i].usage.len > 0) self.handlers[i].usage else self.handlers[i].command;
            if (u.len > max_usage) max_usage = u.len;
        }

        for (0..self.handler_count) |i| {
            const entry = &self.handlers[i];
            const u = if (entry.usage.len > 0) entry.usage else entry.command;
            if (pos + u.len + 2 >= self.response_buf.len) break;
            self.response_buf[pos] = ' ';
            self.response_buf[pos + 1] = ' ';
            pos += 2;
            @memcpy(self.response_buf[pos..][0..u.len], u);
            pos += u.len;
            if (entry.description.len > 0) {
                const pad = max_usage -| u.len + 2;
                var p: usize = 0;
                while (p < pad and pos < self.response_buf.len) : (p += 1) {
                    self.response_buf[pos] = ' ';
                    pos += 1;
                }
                const desc_len = @min(entry.description.len, self.response_buf.len -| pos -| 1);
                @memcpy(self.response_buf[pos..][0..desc_len], entry.description[0..desc_len]);
                pos += desc_len;
            }
            if (pos < self.response_buf.len) {
                self.response_buf[pos] = '\n';
                pos += 1;
            }
        }

        return self.response_buf[0..pos];
    }

    pub fn socketPath(self: *IpcServer) []const u8 {
        return self.socket_path[0..self.socket_path_len];
    }
};

/// CLI client: connect to socket, send command, print response.
pub fn runClient(args: []const [*:0]const u8) !void {
    const runtime = std.c.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const display = std.c.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/mist-{s}.sock", .{ runtime, display });
    path_buf[path.len] = 0;

    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketCreateFailed;
    defer _ = std.c.close(fd);

    var addr = std.mem.zeroes(posix.sockaddr.un);
    addr.family = std.c.AF.UNIX;
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;

    var rc = std.c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    if (rc < 0) {
        // Auto-start daemon if in a Wayland session
        if (std.c.getenv("WAYLAND_DISPLAY") != null) {
            std.log.info("mist not running — starting daemon...", .{});
            var launch_buf: [512]u8 = undefined;
            const launch_cmd = blk: {
                if (std.c.getenv("MIST_BIN")) |env| {
                    const s = std.mem.span(env);
                    break :blk std.fmt.bufPrint(&launch_buf, "{s} >/dev/null 2>&1 &", .{s}) catch "mist >/dev/null 2>&1 &";
                }
                // Try to read /proc/self/exe (Linux)
                var exe_buf: [512]u8 = undefined;
                const n = cc.readlink("/proc/self/exe", @as([*]u8, &exe_buf), exe_buf.len);
                if (n > 0) {
                    const p = exe_buf[0..@as(usize, @intCast(n))];
                    break :blk std.fmt.bufPrint(&launch_buf, "{s} >/dev/null 2>&1 &", .{p}) catch "mist >/dev/null 2>&1 &";
                }
                break :blk "mist >/dev/null 2>&1 &";
            };
            launch_buf[launch_cmd.len] = 0;
            _ = cc.system(@ptrCast(&launch_buf));
            var waited: usize = 0;
            while (waited < 20) : (waited += 1) {
                var ts = std.mem.zeroes(std.os.linux.timespec);
                ts.nsec = 100_000_000; // 100ms
                _ = cc.nanosleep(@ptrCast(&ts), null);
                rc = std.c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
                if (rc >= 0) break;
            }
        }
        if (rc < 0) {
            std.log.err("mist is not running. Start it first: 'mist'", .{});
            return error.ConnectionFailed;
        }
    }

    // Build command string
    var cmd_buf: [max_command_size]u8 = undefined;
    var pos: usize = 0;
    for (args, 0..) |arg, i| {
        const s = std.mem.sliceTo(arg, 0);
        if (i > 0) {
            cmd_buf[pos] = ' ';
            pos += 1;
        }
        if (pos + s.len > cmd_buf.len) return error.CommandTooLong;
        @memcpy(cmd_buf[pos..][0..s.len], s);
        pos += s.len;
    }

    // Send command
    var sent: usize = 0;
    while (sent < pos) {
        const n = std.c.send(fd, @as([*]const u8, @ptrCast(&cmd_buf)) + sent, pos - sent, 0);
        if (n < 0) return error.WriteFailed;
        sent += @as(usize, @intCast(n));
    }

    // Shutdown write side so server sees EOF
    _ = std.c.shutdown(fd, 1); // SHUT_WR

    // Read response
    var resp_buf: [max_response_size]u8 = undefined;
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = std.c.read(fd, @as([*]u8, @ptrCast(&resp_buf)) + total, resp_buf.len - total);
        if (n < 0) {
            const err = posix.errno(@as(i32, @intCast(-n)));
            if (err == .INTR) continue;
            break;
        }
        if (n == 0) break;
        total += @as(usize, @intCast(n));
    }

    // Write response to stdout
    _ = std.c.write(1, @as([*]const u8, @ptrCast(&resp_buf)), total);
}
