const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = std.posix.system;

const linux_headers = @import("linux_headers");
const coreboot_support = @import("build_options").coreboot_support;
const log_level: std.log.Level = @enumFromInt(@import("build_options").loglevel);

const Autoboot = @import("./boot.zig").Autoboot;
const Client = @import("./client.zig").Client;
const Server = @import("./server.zig").Server;
const device = @import("./device.zig");
const log = @import("./log.zig");
const security = @import("./security.zig");
const setupSystem = @import("./system.zig").setupSystem;
const setupTty = @import("./system.zig").setupTty;

pub const std_options = .{
    .logFn = log.logFn,
    .log_level = log_level,
};

const State = struct {
    /// Master epoll file descriptor for driving the event loop.
    epoll_fd: posix.fd_t,

    /// All children processes managed by us.
    children: std.ArrayList(posix.pid_t),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return @This(){
            .epoll_fd = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC),
            .children = std.ArrayList(posix.fd_t).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        defer self.children.deinit();

        for (self.children.items) |child| {
            _ = posix.waitpid(child, 0);
        }

        posix.close(self.epoll_fd);
    }
};

fn runEventLoop(allocator: std.mem.Allocator) !?posix.RebootCommand {
    var state = try State.init(allocator);
    defer state.deinit();

    var device_watcher = try device.DeviceWatcher.init();
    try device_watcher.register(state.epoll_fd);
    defer device_watcher.deinit();

    var server = try Server.init(allocator);
    try server.registerSelf(state.epoll_fd);
    // NOTE: This must be _after_ state.deinit() so that we are ensured that
    // the server is deinitialized _before_ state deinit is called, since state
    // deinit waits for all children to exit, which will only succeed after the
    // server's connections to each client has been closed.
    //
    // TODO(jared): Just put the server
    // on the state instance so we can encode this ordering properly in a
    // single function.
    defer server.deinit();

    const active_consoles = try device.findActiveConsoles(allocator);
    defer allocator.free(active_consoles);

    // Spawn off clients
    {
        const argv_buf = try allocator.allocSentinel(?[*:0]const u8, 1, null);
        defer allocator.free(argv_buf);
        const argv0 = try allocator.dupeZ(u8, "/proc/self/exe");
        defer allocator.free(argv0);
        argv_buf[0] = argv0.ptr;
        const envp_buf = try allocator.allocSentinel(?[*:0]u8, 0, null);
        defer allocator.free(envp_buf);

        std.log.debug("using {} console(s)", .{active_consoles.len});
        for (active_consoles) |fd| {
            const pid = try posix.fork();
            if (pid == 0) {
                try posix.dup2(fd, posix.STDIN_FILENO);
                try posix.dup2(fd, posix.STDOUT_FILENO);
                try posix.dup2(fd, posix.STDERR_FILENO);

                const err = posix.execveZ(argv_buf.ptr[0].?, argv_buf.ptr, envp_buf);
                std.log.err("failed to spawn console process: {}", .{err});
            } else {
                try state.children.append(pid);
            }
        }
    }

    var autoboot = try Autoboot.init();
    try autoboot.register(state.epoll_fd);
    defer autoboot.deinit();

    try device_watcher.startSettleTimer();

    var user_presence = false;

    // main event loop
    while (true) {
        const max_events = 8;
        var events = [_]system.epoll_event{undefined} ** max_events;

        const n_events = posix.epoll_wait(state.epoll_fd, &events, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];

            if (event.data.fd == device_watcher.settle_fd) {
                std.log.info("devices settled", .{});
                if (!user_presence) {
                    try autoboot.start();
                }
            } else if (event.data.fd == autoboot.ready_fd) {
                if (try autoboot.finish()) |outcome| {
                    return outcome;
                } else {
                    std.log.info("nothing to boot", .{});
                    server.forceShell();
                }
            } else if (event.data.fd == device_watcher.nl_fd) {
                device_watcher.handleNewEvent() catch |err| {
                    std.log.err("failed to handle new device: {}", .{err});
                };
            } else if (event.data.fd == server.inner.stream.handle) {
                const conn = try server.inner.accept();
                std.log.debug("new client connected", .{});
                try server.registerClient(state.epoll_fd, conn.stream);
            } else {
                if (!user_presence) {
                    try autoboot.stop();
                    user_presence = true;
                    std.log.info("user presence detected", .{});
                }

                if (try server.handleNewEvent(event)) |outcome| {
                    std.log.debug("got outcome {}", .{outcome});
                    return outcome;
                }
            }
        }
    }
}

fn consoleClient() !void {
    var tty = try setupTty(posix.STDIN_FILENO, .user_input);
    defer tty.reset();

    try log.initLogger(.Client);
    defer log.deinitLogger();

    var client = try Client.init();
    defer client.deinit();

    try client.run();
}

fn pid1() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try setupSystem();

    try log.initLogger(.Server);
    defer log.deinitLogger();

    const cmdline = cmdline: {
        var cmdline_file = try std.fs.openFileAbsolute("/proc/self/cmdline", .{ .mode = .read_only });
        defer cmdline_file.close();
        const cmdline_raw = try cmdline_file.readToEndAlloc(allocator, 2048);
        defer allocator.free(cmdline_raw);
        const buf = try allocator.dupe(u8, cmdline_raw);
        _ = std.mem.replace(u8, cmdline_raw, &.{0}, " ", buf);
        break :cmdline buf;
    };
    defer allocator.free(cmdline);
    std.log.info("{s}", .{cmdline});

    std.log.info("tinyboot started", .{});

    if (coreboot_support) {
        std.log.info("built with coreboot support", .{});
    }

    security.initializeSecurity(allocator) catch |err| {
        std.log.warn("failed to initialize secure boot: {}", .{err});
    };

    const reboot_cmd = try runEventLoop(allocator) orelse posix.RebootCommand.POWER_OFF;

    try posix.reboot(reboot_cmd);
}

pub fn main() !void {
    if (false) {
        const foo =
            \\{"msg":{"Boot":{"linux":"/run/GQrY5amWP1ZbtbAZ/kernel","initrd":null,"cmdline":"console=ttyS0,115200n8"}}}
        ;

        if (std.unicode.utf8ValidateSlice(foo)) {
            std.log.info("is valid", .{});
        } else {
            std.log.info("is not valid", .{});
        }
        return;
    }

    switch (system.getpid()) {
        1 => {
            pid1() catch |err| {
                std.log.err("failed to boot: {any}\n", .{err});
            };

            std.debug.panic("epic failure :/", .{});
        },
        else => try consoleClient(),
    }
}
