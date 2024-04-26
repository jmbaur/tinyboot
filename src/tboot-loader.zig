const coreboot_support = @import("build_options").coreboot_support;

const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const posix = std.posix;
const fs = std.fs;
const linux = std.os.linux;

const Autoboot = @import("./boot.zig").Autoboot;
const Console = @import("./seat.zig").Console;
const Seat = @import("./seat.zig").Seat;
const Shell = @import("./shell.zig").Shell;
const device = @import("./device.zig");
const log = @import("./log.zig");
const system = @import("./system.zig");
const security = @import("./security.zig");

pub const std_options = .{
    .logFn = log.logFn,
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

const State = struct {
    /// Master epoll file descriptor for driving the event loop.
    epoll_fd: posix.fd_t,

    /// Netlink socket for capturing new Kobject uevent events.
    device_nl_fd: posix.fd_t,

    /// Timer for determining when new Kobject uevent events have settled.
    device_timer_fd: posix.fd_t,
};

fn run_event_loop(allocator: std.mem.Allocator) !?posix.RebootCommand {
    const epoll_fd = try posix.epoll_create1(0);
    defer posix.close(epoll_fd);

    var device_watcher = try device.DeviceWatcher.init();
    try device_watcher.register(epoll_fd);
    defer device_watcher.deinit();

    var seat = s: {
        var pids = std.ArrayList(posix.pid_t).init(allocator);
        errdefer pids.deinit();

        var fds = std.ArrayList(posix.fd_t).init(allocator);
        errdefer fds.deinit();

        var consoles = std.ArrayList(Console).init(allocator);

        const active_consoles = try device.findActiveConsoles(allocator);
        defer allocator.free(active_consoles);

        for (active_consoles) |fd| {
            var sock_pair = [2]posix.fd_t{ 0, 0 };
            if (os.linux.socketpair(os.linux.PF.LOCAL, os.linux.SOCK.STREAM, 0, &sock_pair) != 0) {
                continue;
            }

            const pid = try posix.fork();
            if (pid == 0) {
                try system.setupTty(fd, .user_input);

                try posix.dup2(fd, posix.STDIN_FILENO);
                try posix.dup2(fd, posix.STDOUT_FILENO);
                try posix.dup2(fd, posix.STDERR_FILENO);

                var shell = Shell.init(sock_pair[0], log.log_buffer.?);
                defer shell.deinit();

                shell.run() catch |err| {
                    // Use std.debug.print since we want to print the error
                    // directly to stderr of the child process, as there won't
                    // be a way to stream output from std.log.* calls.
                    std.debug.print("failed to run shell: {any}\n", .{err});
                };

                posix.exit(0);
            } else {
                try consoles.append(.{
                    .pid = pid,
                    .pid_fd = @as(posix.fd_t, @intCast(os.linux.pidfd_open(pid, 0))),
                    .comm_fd = sock_pair[1],
                });
                log.addConsole(sock_pair[1]);
            }
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

        const n_events = posix.epoll_wait(epoll_fd, &events, -1);

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
                device_watcher.handle_new_event() catch |err| {
                    std.log.err("failed to handle new device: {}", .{err});
                };
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
        std.debug.panic("not pid 1\n", .{});
    }

    main_unwrapped() catch |err| {
        std.debug.panic("failed to boot: {any}\n", .{err});
    };

    std.debug.panic("epic failure :/", .{});
}

fn main_unwrapped() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try system.setupSystem();

    try log.initLogger();
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

    security.initialize_security(allocator) catch |err| {
        std.log.warn("failed to initialize secure boot: {}", .{err});
    };

    const reboot_cmd = try run_event_loop(allocator) orelse posix.RebootCommand.POWER_OFF;

    try posix.reboot(reboot_cmd);
}
