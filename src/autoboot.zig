const std = @import("std");
const posix = std.posix;

const BootLoader = @import("./boot/bootloader.zig");
const Console = @import("./console.zig");

const Autoboot = @This();

boot_loader: ?*BootLoader = null,

pub fn init() Autoboot {
    return .{};
}

pub fn run(
    self: *Autoboot,
    boot_loaders: *std.ArrayList(*BootLoader),
    timerfd: posix.fd_t,
) !?Console.Event {
    if (self.boot_loader) |boot_loader| {
        defer {
            self.boot_loader = null;
        }

        std.log.info("autobooting {s}", .{boot_loader.device});

        const entries = try boot_loader.probe();

        for (entries) |entry| {
            boot_loader.load(entry) catch |err| {
                std.log.err(
                    "failed to load entry {s}: {}",
                    .{ entry.linux, err },
                );
                continue;
            };
            return .kexec;
        }
    } else {
        if (boot_loaders.items.len == 0) {
            return error.NoBootloaders;
        }

        const head = boot_loaders.orderedRemove(0);
        try boot_loaders.append(head);

        // If we've already tried this boot loader, this means we've gone full
        // circle back to the first bootloader, so we are done.
        if (head.boot_attempted) {
            return error.NoBootloaders;
        }

        if (!head.autoboot) {
            head.boot_attempted = true;
            return null;
        }

        self.boot_loader = head;

        const timeout = try self.boot_loader.?.timeout();
        if (timeout == 0) {
            return self.run(boot_loaders, timerfd);
        } else {
            try posix.timerfd_settime(timerfd, .{}, &.{
                // oneshot
                .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
                // consider settled after N seconds without any new events
                .it_value = .{ .tv_sec = timeout, .tv_nsec = 0 },
            }, null);

            std.log.info(
                "will boot in {} seconds without any user input",
                .{timeout},
            );
        }
    }

    return null;
}
