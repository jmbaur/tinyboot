const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const linux_headers = @import("linux_headers");

const Autoboot = @import("./autoboot.zig");
const BootLoader = @import("./boot/bootloader.zig");
const Console = @import("./console.zig");
const Device = @import("./device.zig");
const DeviceWatcher = @import("./watch.zig");
const DiskBootLoader = @import("./boot/disk.zig");
const Log = @import("./log.zig");
const YmodemBootLoader = @import("./boot/ymodem.zig");
const security = @import("./security.zig");
const system = @import("./system.zig");
const utils = @import("./utils.zig");

pub const std_options = .{
    .logFn = Log.logFn,
    .log_level = .debug, // let the kernel do our filtering for us
};

const TbootLoader = @This();

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var boot_loaders = std.ArrayList(*BootLoader).init(arena.allocator());

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

autoboot: Autoboot = Autoboot.init(),

/// A timerfd file descriptor that is re-used for a few different purposes (of
/// which these purposes do not have overlapping time windows):
/// 1. Indication that some period of time has elapsed and we have not seen any
///    new devices show up.
/// 2. A bootloader-configured timeout, usually to allow the user to interfere
///    with the boot process.
timer: posix.fd_t,

/// General state of the program
state: enum { init, autobooting, user_input } = .init,

fn init() !TbootLoader {
    var self = TbootLoader{
        .epoll = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC),
        .timer = try posix.timerfd_create(posix.CLOCK.MONOTONIC, .{}),
        .device_watcher = try DeviceWatcher.init(),
        .done = try posix.eventfd(0, 0),
        .console = try Console.init(),
    };

    try posix.epoll_ctl(
        self.epoll,
        posix.system.EPOLL.CTL_ADD,
        self.timer,
        @constCast(&.{
            .data = .{ .fd = self.timer },
            .events = posix.system.EPOLL.IN,
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

    try self.newDeviceArmTimer();

    return self;
}

// Since the timer is used entirely for autobooting purposes, if we ever disarm
// the timer, we go immediately into user input mode.
fn disarmTimer(self: *TbootLoader) !void {
    try posix.epoll_ctl(self.epoll, posix.system.EPOLL.CTL_DEL, self.timer, null);
    self.state = .user_input;
}

fn handleConsole(self: *TbootLoader) !?posix.RebootCommand {
    if (self.state != .user_input) {
        // disarm the timer to prevent autoboot from taking over
        try self.disarmTimer();
    }

    const outcome = try self.console.handleStdin(boot_loaders.items) orelse return null;

    switch (outcome) {
        .reboot => return posix.RebootCommand.RESTART,
        .poweroff => return posix.RebootCommand.POWER_OFF,
        .kexec => return posix.RebootCommand.KEXEC,
    }
}

fn newDeviceArmTimer(self: *TbootLoader) !void {
    try posix.timerfd_settime(self.timer, .{}, &.{
        // oneshot
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        // consider settled after 2 seconds without any new events
        .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
    }, null);
}

const all_bootloaders = .{ DiskBootLoader, YmodemBootLoader };
fn handleDevice(self: *TbootLoader) !void {
    // consume eventfd value
    {
        var uevent_val: u64 = undefined;
        _ = try posix.read(self.device_watcher.event, std.mem.asBytes(&uevent_val));
    }

    o: while (self.device_watcher.nextEvent()) |event| {
        const device = event.device;

        switch (event.action) {
            .add => {
                inline for (all_bootloaders) |bootloader_type| {
                    // If match() returns null, the device is not a match for
                    // that specific boot loader. If match() returns a non-null
                    // value, the device is a match with that values priority,
                    // where a lower number is a higher priority.
                    const priority: ?u8 = bootloader_type.match(&device);

                    if (priority) |new_priority| {
                        std.log.debug(
                            "new {s} device matched bootloader {s}",
                            .{ @tagName(event.device.subsystem), bootloader_type.name() },
                        );

                        const new_bootloader = try arena.allocator().create(BootLoader);
                        new_bootloader.* = try BootLoader.init(
                            bootloader_type,
                            arena.allocator(),
                            device,
                            .{
                                .autoboot = bootloader_type.autoboot,
                                .priority = new_priority,
                            },
                        );

                        for (boot_loaders.items, 0..) |boot_loader, index| {
                            if (new_bootloader.priority < boot_loader.priority) {
                                try boot_loaders.insert(index, new_bootloader);
                                continue :o;
                            }
                        }

                        // Append to the end if we did not find an appropriate
                        // place to insert the bootloader prior to the end.
                        try boot_loaders.append(new_bootloader);
                    }
                }
            },
            .remove => {
                for (boot_loaders.items, 0..) |boot_loader, index| {
                    if (std.meta.eql(boot_loader.device, event.device)) {
                        var removed_boot_loader = boot_loaders.orderedRemove(index);
                        removed_boot_loader.deinit();
                    }
                }
            },
        }
    }

    if (self.state == .init) {
        try self.newDeviceArmTimer();
    }
}

fn handleTimer(self: *TbootLoader) ?posix.RebootCommand {
    if (self.state == .init) {
        std.log.info("devices settled", .{});

        self.state = .autobooting;
    } else {
        std.debug.assert(self.state == .autobooting);

        std.log.debug("autoboot timeout", .{});
    }

    if (self.autoboot.run(&boot_loaders, self.timer)) |maybe_event| {
        if (maybe_event) |outcome| {
            switch (outcome) {
                .reboot => return posix.RebootCommand.RESTART,
                .poweroff => return posix.RebootCommand.POWER_OFF,
                .kexec => return posix.RebootCommand.KEXEC,
            }
        }
    } else |err| {
        std.log.err("failed to run autoboot: {}", .{err});
        self.disarmTimer() catch {};
    }

    return null;
}

fn deinit(self: *TbootLoader) void {
    // Notify all threads that we are done.
    _ = posix.write(self.done, std.mem.asBytes(&@as(u64, 1))) catch {};

    self.console.deinit();

    self.device_watcher.deinit();

    posix.close(self.timer);
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
            } else if (event.data.fd == self.timer) {
                if (self.handleTimer()) |outcome| {
                    return outcome;
                }
            } else {
                std.debug.panic("unknown event: {}", .{event});
            }
        }
    }
}

pub fn main() !void {
    defer {
        for (boot_loaders.items) |boot_loader| {
            boot_loader.deinit();
        }
        arena.deinit();
    }

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
