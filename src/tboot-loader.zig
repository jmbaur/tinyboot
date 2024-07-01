const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const linux_headers = @import("linux_headers");

const Autoboot = @import("./autoboot.zig");
const Console = @import("./console.zig");
const Device = @import("./device.zig");
const DeviceWatcher = @import("./watch.zig");
const Log = @import("./log.zig");
const security = @import("./security.zig");
const system = @import("./system.zig");
const utils = @import("./utils.zig");

pub const std_options = .{
    .logFn = Log.logFn,
    .log_level = .debug, // let the kernel do our filtering for us
};

const TbootLoader = @This();

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var devices = std.ArrayList(Device).init(arena.allocator());

/// Master epoll file descriptor for driving the event loop.
epoll: posix.fd_t,

/// An eventfd file descriptor used to indicate to other threads the
/// program is done.
done: posix.fd_t,

/// DeviceWatcher instance used to handle events of devices being added or
/// removed from the system.
device_watcher: DeviceWatcher,

/// Console instance used to handle user input.
console: Console,

autoboot: ?Autoboot = null,

/// A timerfd file descriptor that (when timed out) indicates when devices
/// have settled (no new devices have been discovered in some amount of
/// time).
device_settle: posix.fd_t,

/// A flag to indicate whether either (1) new device events have settled for
/// some amount of time or (2) a user is present.
settled: bool = false,

pub fn init() !TbootLoader {
    var self = TbootLoader{
        .epoll = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC),
        .device_settle = try posix.timerfd_create(posix.CLOCK.MONOTONIC, .{}),
        .device_watcher = try DeviceWatcher.init(),
        .done = try posix.eventfd(0, 0),
        .console = try Console.init(),
    };

    try posix.epoll_ctl(
        self.epoll,
        posix.system.EPOLL.CTL_ADD,
        self.device_settle,
        @constCast(&.{
            .data = .{ .fd = self.device_settle },
            // Oneshot because we only have one window of time per-boot
            // where we were once considered "unsettled".
            .events = posix.system.EPOLL.IN | posix.system.EPOLL.ONESHOT,
        }),
    );

    try posix.epoll_ctl(
        self.epoll,
        posix.system.EPOLL.CTL_ADD,
        self.device_watcher.event,
        @constCast(&.{
            .data = .{ .fd = self.device_watcher.event },
            .events = posix.system.EPOLL.IN,
        }),
    );

    try posix.epoll_ctl(
        self.epoll,
        posix.system.EPOLL.CTL_ADD,
        Console.IN,
        @constCast(&.{
            .data = .{ .fd = Console.IN },
            .events = posix.system.EPOLL.IN,
        }),
    );

    try self.resetSettle();

    return self;
}

pub fn handleConsole(self: *TbootLoader) !?posix.RebootCommand {
    if (!self.settled) {
        self.settled = true;

        if (self.autoboot) |*autoboot| {
            autoboot.deinit();
        }
    }

    const outcome = try self.console.handleStdin(devices.items) orelse return null;

    switch (outcome) {
        .reboot => return posix.RebootCommand.RESTART,
        .poweroff => return posix.RebootCommand.POWER_OFF,
        .kexec => return posix.RebootCommand.KEXEC,
    }
}

fn resetSettle(self: *TbootLoader) !void {
    // var ts: posix.timespec = undefined;
    // try posix.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    try posix.timerfd_settime(self.device_settle, .{}, &.{
        // oneshot
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        // consider settled after 2 seconds without any new events
        .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
    }, null);
}

pub fn handleDevice(self: *TbootLoader) !void {
    // consume eventfd value
    {
        var uevent_val: u64 = undefined;
        _ = try posix.read(self.device_watcher.event, std.mem.asBytes(&uevent_val));
    }

    while (self.device_watcher.nextEvent()) |event| {
        switch (event.action) {
            .add => {
                std.log.debug("new device added {}", .{event.device.subsystem});
                try devices.append(event.device);
            },
            .remove => {
                for (devices.items, 0..) |device, index| {
                    if (device.subsystem == event.device.subsystem) {
                        if (std.meta.eql(device, event.device)) {
                            _ = devices.orderedRemove(index);
                        }
                    }
                }
            },
        }
    }

    if (!self.settled) {
        try self.resetSettle();
    }
}

fn handleDeviceSettle(self: *TbootLoader) !void {
    std.log.info("devices settled", .{});
    if (!self.settled and self.autoboot == null) {
        self.settled = true;

        self.autoboot = Autoboot.init();
    }
}

pub fn deinit(self: *TbootLoader) void {
    // Notify all threads that we are done.
    _ = posix.write(self.done, std.mem.asBytes(&@as(u64, 1))) catch {};

    self.console.deinit();

    self.device_watcher.deinit();

    posix.close(self.device_settle);
    posix.close(self.done);
    posix.close(self.epoll);
}

fn run(self: *TbootLoader) !posix.RebootCommand {
    while (true) {
        var events = [_]posix.system.epoll_event{undefined} ** (2 << 4);

        const n_events = posix.epoll_wait(self.epoll, &events, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];

            if (event.data.fd == Console.IN) {
                if (try self.handleConsole()) |outcome| {
                    return outcome;
                }
            } else if (event.data.fd == self.device_watcher.event) {
                try self.handleDevice();
            } else if (event.data.fd == self.device_settle) {
                try self.handleDeviceSettle();
            } else {
                std.debug.panic("unknown event: {}", .{event});
            }
        }
    }
}

pub fn main() !void {
    {
        try system.mountPseudoFilesystems();

        var tboot_loader = try TbootLoader.init();
        defer tboot_loader.deinit();

        // We should be able to log right after we've initialized the device
        // watcher.
        try Log.init();
        defer Log.deinit();

        var device_watch_thread = try std.Thread.spawn(.{}, DeviceWatcher.watch, .{
            &tboot_loader.device_watcher,
            tboot_loader.done,
        });
        defer device_watch_thread.join();

        std.log.info("tinyboot started", .{});

        try security.initializeSecurity();

        const reboot_cmd = try tboot_loader.run();

        try posix.reboot(reboot_cmd);
    }

    // Sleep forever without hammering the CPU, waiting for the kernel to
    // reboot.
    var futex = std.atomic.Value(u32).init(0);
    while (true) std.Thread.Futex.wait(&futex, 0);
    unreachable;
}
