const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const linux_headers = @import("linux_headers");

const Console = @import("./console.zig");
const Device = @import("./device/device.zig");
const DeviceWatcher = @import("./device/watch.zig");
const Log = @import("./log.zig");
const security = @import("./security.zig");
const system = @import("./system.zig");
const utils = @import("./utils.zig");

pub const std_options = .{
    .logFn = Log.logFn,
    .log_level = .debug, // let the kernel do our filtering for us
};

pub const State = struct {
    pub const DeviceWatcherIO = utils.IoPair(DeviceWatcher.Event, State.Event);
    pub const ConsoleIO = utils.IoPair(Console.Event, State.Event);

    /// Master epoll file descriptor for driving the event loop.
    epoll: posix.fd_t,

    /// A channel used to communicate with the device thread.
    device: DeviceWatcherIO,

    /// A channel used to communicate with the console thread.
    console: ConsoleIO,

    /// A timerfd file descriptor that (when timed out) indicates when devices
    /// have settled (no new devices have been discovered in some amount of
    /// time).
    settle: posix.fd_t,

    settled: bool = false,

    pub const Event = enum {
        start,
        settled,
        done,
    };

    pub fn init() !@This() {
        var self = @This(){
            .epoll = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC),
            .settle = try posix.timerfd_create(posix.CLOCK.MONOTONIC, .{}),
            .device = try DeviceWatcherIO.init(),
            .console = try ConsoleIO.init(),
        };

        try posix.epoll_ctl(
            self.epoll,
            posix.system.EPOLL.CTL_ADD,
            self.settle,
            @constCast(&.{
                .data = .{ .fd = self.settle },
                // Oneshot because we only have one window of time per-boot
                // where we were once considered "unsettled".
                .events = posix.system.EPOLL.IN | posix.system.EPOLL.ONESHOT,
            }),
        );

        try posix.epoll_ctl(
            self.epoll,
            posix.system.EPOLL.CTL_ADD,
            self.device.in,
            @constCast(&.{
                .data = .{ .fd = self.device.in },
                .events = posix.system.EPOLL.IN,
            }),
        );

        try posix.epoll_ctl(
            self.epoll,
            posix.system.EPOLL.CTL_ADD,
            self.console.in,
            @constCast(&.{
                .data = .{ .fd = self.console.in },
                .events = posix.system.EPOLL.IN,
            }),
        );

        try self.notify(.start);

        try self.resetSettle();

        return self;
    }

    pub fn notify(self: *@This(), event: Event) !void {
        try self.device.write(event);
        try self.console.write(event);
    }

    pub fn handleConsole(self: *@This()) !?posix.RebootCommand {
        switch (try self.console.read()) {
            .reboot => return posix.RebootCommand.RESTART,
            .poweroff => return posix.RebootCommand.POWER_OFF,
            .kexec => return posix.RebootCommand.KEXEC,
        }

        return null;
    }

    fn resetSettle(self: *@This()) !void {
        // var ts: posix.timespec = undefined;
        // try posix.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
        try posix.timerfd_settime(self.settle, .{}, &.{
            // oneshot
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            // consider settled after 2 seconds without any new events
            .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
        }, null);
    }

    // TODO(jared): do driver probing here? This would let the device thread
    // not be blocked on any slow probes (e.g. probes that require reading and
    // mounting disks).
    pub fn handleDevice(self: *@This()) !void {
        // consume, no data actually used
        _ = try self.device.read();

        std.log.debug("new device", .{});

        if (!self.settled) {
            try self.resetSettle();
        }
    }

    fn handleSettle(self: *@This()) !void {
        try self.notify(.settled);
    }

    pub fn deinit(self: *@This()) void {
        // Notify all threads that we are done.
        self.notify(.done) catch |err| {
            std.log.err("failed to notify finished state: {}", .{err});
        };

        self.device.deinit();
        self.console.deinit();
        posix.close(self.settle);
        posix.close(self.epoll);
    }
};

fn runEventLoop(state: *State) !posix.RebootCommand {
    // main event loop
    while (true) {
        const max_events = 8;
        var events = [_]posix.system.epoll_event{undefined} ** max_events;

        const n_events = posix.epoll_wait(state.epoll, &events, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];

            if (event.data.fd == state.settle) {
                try state.handleSettle();
            } else if (event.data.fd == state.device.in) {
                try state.handleDevice();
            } else if (event.data.fd == state.console.in) {
                if (state.handleConsole()) |outcome| {
                    if (outcome) |reboot_cmd| {
                        return reboot_cmd;
                    }
                } else |err| {
                    std.log.err("failed to handle console notification: {}", .{err});
                }
            } else {
                std.log.debug("unknown event: {}", .{event});
                std.debug.assert(false);
            }
        }
    }
}

pub fn main() !void {
    defer Device.removeAll();

    try system.mountPseudoFilesystems();

    var state = try State.init();
    defer state.deinit();

    var device_watcher = try DeviceWatcher.init();
    defer device_watcher.deinit();

    try device_watcher.scanAndCreateExistingDevices();

    // We should be able to log right after we've initialized the device
    // watcher.
    try Log.init();
    defer Log.deinit();

    var device_watch_thread = try std.Thread.spawn(.{}, DeviceWatcher.watch, .{
        &device_watcher,
        state.device.invert(),
    });
    defer device_watch_thread.join();

    var console_thread = try std.Thread.spawn(
        .{},
        Console.input,
        .{state.console.invert()},
    );
    defer console_thread.join();

    std.log.info("tinyboot started", .{});

    try security.initializeSecurity();

    const reboot_cmd = try runEventLoop(&state);

    try posix.reboot(reboot_cmd);
}
