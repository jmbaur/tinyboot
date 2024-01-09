const coreboot_support = @import("build_options").coreboot_support;

const std = @import("std");
const os = std.os;
const fs = std.fs;
const linux = std.os.linux;

const Autoboot = @import("./boot.zig").Autoboot;
const Config = @import("./config.zig").Config;
const Console = @import("./seat.zig").Console;
const DeviceWatcher = @import("./device.zig").DeviceWatcher;
const Seat = @import("./seat.zig").Seat;
const Shell = @import("./shell.zig").Shell;
const device = @import("./device.zig");
const log = @import("./log.zig");
const system = @import("./system.zig");

pub const std_options = struct {
    pub const logFn = log.logFn;
};

const State = struct {
    /// Master epoll file descriptor for driving the event loop.
    epoll_fd: os.fd_t,

    /// Netlink socket for capturing new Kobject uevent events.
    device_nl_fd: os.fd_t,

    /// Timer for determining when new Kobject uevent events have settled.
    device_timer_fd: os.fd_t,
};

fn run_event_loop(a: std.mem.Allocator, cfg: *const Config) !?os.RebootCommand {
    const epoll_fd = try os.epoll_create1(0);
    defer os.close(epoll_fd);

    var device_watcher = try DeviceWatcher.init();
    try device_watcher.register(epoll_fd);
    defer device_watcher.deinit();

    var seat = s: {
        var pids = std.ArrayList(os.pid_t).init(a);
        errdefer pids.deinit();

        var fds = std.ArrayList(os.fd_t).init(a);
        errdefer fds.deinit();

        var consoles = std.ArrayList(Console).init(a);

        for (cfg.consoles) |console| {
            const path = try std.fs.path.join(a, &.{
                std.fs.path.sep_str,
                "dev",
                console.serial_char_device orelse "tty1",
            });
            defer a.free(path);

            const fd = os.open(path, os.O.RDWR | os.O.NOCTTY, 0) catch continue;

            var sock_pair = [2]os.fd_t{ 0, 0 };
            if (os.linux.socketpair(os.linux.PF.LOCAL, os.SOCK.STREAM, 0, &sock_pair) != 0) {
                return error.Todo;
            }

            const pid = try os.fork();
            if (pid == 0) {
                try system.setupTty(fd);

                try os.dup2(fd, os.STDIN_FILENO);
                try os.dup2(fd, os.STDOUT_FILENO);
                try os.dup2(fd, os.STDERR_FILENO);

                var shell = Shell.init(sock_pair[0], log.log_buffer.?);
                defer shell.deinit();

                shell.run() catch |err| {
                    std.debug.print("failed to run shell: {any}\n", .{err});
                };

                os.exit(0);
            } else {
                try consoles.append(.{
                    .pid = pid,
                    .pid_fd = @as(os.fd_t, @intCast(os.linux.pidfd_open(pid, 0))),
                    .comm_fd = sock_pair[1],
                });
                log.addConsole(sock_pair[1]);
            }

            std.log.info("using console {s}", .{path});
        }

        break :s Seat.init(try consoles.toOwnedSlice());
    };
    try seat.register(epoll_fd);
    defer seat.deinit();

    var autoboot = try Autoboot.init();
    try autoboot.register(epoll_fd);
    defer autoboot.deinit();

    try device_watcher.start_settle_timer();

    var user_presence = false;

    // main event loop
    while (true) {
        const max_events = 8;
        const events_one: os.linux.epoll_event = undefined;
        var events = [_]os.linux.epoll_event{events_one} ** max_events;

        const n_events = os.epoll_wait(epoll_fd, &events, -1);

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
                    seat.force_shell();
                }
            } else if (event.data.fd == device_watcher.nl_fd) {
                try device_watcher.handle_new_event();
            } else {
                if (!user_presence) {
                    try autoboot.stop();
                    user_presence = true;
                    std.log.info("user presence detected", .{});
                }

                if (try seat.handle_new_event(event)) |outcome| {
                    return outcome;
                }
            }
        }
    }
}

// PID1 should not return
pub fn main() noreturn {
    if (os.linux.getpid() != 1) {
        std.debug.panic("not pid 1", .{});
    }

    main_unwrapped() catch |err| {
        std.debug.panic("failed to boot: {any}\n", .{err});
    };

    std.debug.panic("epic failure :/", .{});
}

fn main_unwrapped() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();

    try system.setupSystem();

    var args = try std.process.ArgIterator.initWithAllocator(alloc);
    const cfg = try Config.parseFromArgs(alloc, &args);

    try log.initLogger();
    defer log.deinitLogger();

    const cmdline = cmdline: {
        var cmdline_file = try std.fs.openFileAbsolute("/proc/self/cmdline", .{ .mode = .read_only });
        defer cmdline_file.close();
        const cmdline_raw = try cmdline_file.readToEndAlloc(alloc, 2048);
        defer alloc.free(cmdline_raw);
        var buf = try alloc.dupe(u8, cmdline_raw);
        _ = std.mem.replace(u8, cmdline_raw, &.{0}, " ", buf);
        break :cmdline buf;
    };
    defer alloc.free(cmdline);
    std.log.info("{s}", .{cmdline});

    std.log.info("tinyboot started", .{});

    if (coreboot_support) {
        std.log.info("built with coreboot support", .{});
    }

    const reboot_cmd = try run_event_loop(alloc, &cfg) orelse os.RebootCommand.POWER_OFF;
    try os.reboot(reboot_cmd);
}
