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
    boot_loaders: *std.array_list.Managed(*BootLoader),
    timerfd: posix.fd_t,
) !?Console.Event {
    if (self.boot_loader) |boot_loader| {
        // After we attempt to boot with this boot loader, we unset it from the
        // autoboot structure so re-entry into this function does not attempt
        // to use it again.
        defer {
            boot_loader.boot_attempted = true;
            self.boot_loader = null;
        }

        std.log.info("autobooting {f}", .{boot_loader.device});

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

        // If we've already tried this boot loader, this means we've gone full
        // circle back to the first bootloader, so we are done. We insert it
        // back to the beginning to not mess with the original order.
        if (head.boot_attempted) {
            try boot_loaders.insert(0, head);

            return error.NoBootloaders;
        }

        try boot_loaders.append(head);

        if (!head.autoboot) {
            head.boot_attempted = true;

            return null;
        }

        self.boot_loader = head;

        std.debug.assert(self.boot_loader != null);
        const timeout = try self.boot_loader.?.timeout();

        if (timeout == 0) {
            return self.run(boot_loaders, timerfd);
        } else {
            try posix.timerfd_settime(timerfd, .{}, &.{
                // oneshot
                .it_interval = .{ .sec = 0, .nsec = 0 },
                // wait for `timeout` seconds before continuing to boot
                .it_value = .{ .sec = timeout, .nsec = 0 },
            }, null);

            std.log.info(
                "will boot in {} seconds without any user input",
                .{timeout},
            );
        }
    }

    return null;
}
