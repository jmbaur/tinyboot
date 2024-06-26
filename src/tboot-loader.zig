const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = std.posix.system;

const linux_headers = @import("linux_headers");

const Console = @import("./console.zig");
const Device = @import("./device/device.zig");
const DeviceWatcher = @import("./device/watch.zig");
const Log = @import("./log.zig");
const security = @import("./security.zig");
const setupSystem = @import("./system.zig").setupSystem;
const utils = @import("./utils.zig");

pub const std_options = .{
    .logFn = Log.logFn,
    .log_level = .debug, // let the kernel do our filtering for us
};

const State = struct {
    /// Master epoll file descriptor for driving the event loop.
    epoll: posix.fd_t,

    /// An eventfd file descriptor that will be written to when all work is
    /// done.
    done: posix.fd_t,

    /// An eventfd file descriptor that will be written to each time a new
    /// device is found.
    device: posix.fd_t,

    /// An eventfd file descriptor that will be written to each time a new user
    /// input event occurs.
    console: posix.fd_t,

    /// A timerfd file descriptor that (when timed out) indicates when devices
    /// have settled (no new devices have been discovered in some amount of
    /// time).
    settle: posix.fd_t,

    settled: bool = false,

    user_presence: bool = false,

    pub fn init() !@This() {
        var self = @This(){
            .epoll = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC),
            .done = try posix.eventfd(0, 0),
            .device = try posix.eventfd(0, 0),
            .console = try posix.eventfd(0, 0),
            .settle = try posix.timerfd_create(posix.CLOCK.REALTIME, .{}),
        };

        try posix.epoll_ctl(self.epoll, system.EPOLL.CTL_ADD, self.device, @constCast(&.{
            .data = .{ .fd = self.device },
            .events = system.EPOLL.IN,
        }));

        try posix.epoll_ctl(self.epoll, system.EPOLL.CTL_ADD, self.settle, @constCast(&.{
            .data = .{ .fd = self.settle },
            .events = system.EPOLL.IN | system.EPOLL.ONESHOT,
        }));

        try posix.epoll_ctl(self.epoll, system.EPOLL.CTL_ADD, self.console, @constCast(&.{
            .data = .{ .fd = self.console },
            .events = system.EPOLL.IN,
        }));

        try self.resetSettle();

        return self;
    }

    pub fn handleConsole(self: *@This()) !?posix.RebootCommand {
        switch (try utils.eventfdReadEnum(Console.Notification, self.console)) {
            .presence => {
                if (!self.user_presence) {
                    // autoboot.stop();
                    self.user_presence = true;
                    std.log.info("user presence detected", .{});
                }
            },
            .reboot => return posix.RebootCommand.RESTART,
            .poweroff => return posix.RebootCommand.POWER_OFF,
            .kexec => return posix.RebootCommand.KEXEC,
        }

        return null;
    }

    fn resetSettle(self: *@This()) !void {
        try posix.timerfd_settime(self.settle, .{}, @constCast(&.{
            // oneshot
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            // consider settled after 2 seconds without any new events
            .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
        }), null);
    }

    pub fn handleDevice(self: *@This()) !void {
        _ = try posix.read(self.device, std.mem.asBytes(&1)); // consume

        if (!self.settled) {
            try self.resetSettle();
        }
    }

    fn handleSettle(self: *@This()) void {
        std.log.info("devices settled", .{});
        self.settled = true;
    }

    pub fn deinit(self: *@This()) void {
        posix.close(self.done);
        posix.close(self.device);
        posix.close(self.console);
        posix.close(self.settle);
        posix.close(self.epoll);
    }
};

fn runEventLoop(state: *State) !posix.RebootCommand {
    // var autoboot = try Autoboot.init();
    // try autoboot.register(state.epoll);
    // defer autoboot.deinit();

    // main event loop
    while (true) {
        const max_events = 8;
        var events = [_]system.epoll_event{undefined} ** max_events;

        const n_events = posix.epoll_wait(state.epoll, &events, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];

            if (event.data.fd == state.device) {
                try state.handleDevice();
            } else if (event.data.fd == state.settle) {
                state.handleSettle();
                // if (!state.user_presence) {
                //         try autoboot.start();
                //     }
                // } else if (event.data.fd == autoboot.ready_fd) {
                //     try autoboot.deregister(state.epoll);
                //     if (try autoboot.finish()) |outcome| {
                //         return outcome;
                //     } else {
                //         std.log.info("nothing to boot", .{});
                //     }
            } else if (event.data.fd == state.console) {
                if (state.handleConsole()) |outcome| {
                    if (outcome) |reboot_cmd| {
                        return reboot_cmd;
                    }
                } else |err| {
                    std.log.err("failed to handle console notification: {}", .{err});
                }
            }
        }
    }
}

pub fn main() !void {
    try setupSystem();

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
        state.device,
        state.done,
    });
    defer device_watch_thread.join();

    var console_thread = try std.Thread.spawn(
        .{},
        Console.input,
        .{ state.console, state.done },
    );
    defer console_thread.join();

    std.log.info("tinyboot started", .{});

    try security.initializeSecurity();

    const reboot_cmd = try runEventLoop(&state);

    try posix.reboot(reboot_cmd);
}
