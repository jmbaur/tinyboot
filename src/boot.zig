const std = @import("std");
const os = std.os;

const BootLoaderSpec = @import("./boot/bls.zig").BootLoaderSpec;

pub const BootLoader = union(enum) {
    bls: *BootLoaderSpec,

    pub fn setup(self: @This()) !void {
        std.log.debug("boot loader setup", .{});

        switch (self) {
            inline else => |boot_loader| try boot_loader.setup(),
        }
    }

    pub fn probe(self: @This()) void {
        std.log.debug("boot loader probe", .{});

        switch (self) {
            inline else => |boot_loader| boot_loader.probe(),
        }
    }

    pub fn teardown(self: @This()) void {
        std.log.debug("boot loader teardown", .{});

        switch (self) {
            inline else => |boot_loader| boot_loader.teardown(),
        }
    }
};

fn autoboot(ready_fd: os.fd_t, stop_fd: os.fd_t) !void {
    std.log.debug("autoboot started", .{});

    var boot_loader: BootLoader = .{ .bls = &.{} };
    defer {
        boot_loader.teardown();
        std.log.debug("autoboot stopped", .{});

        // write to ready_fd to ensure reads on it don't block
        var ev: u64 = 0x1;
        _ = os.write(ready_fd, std.mem.asBytes(&ev)) catch {};
    }

    try boot_loader.setup();
    {
        std.log.debug("post setup, checking if we need to stop", .{});
        // check if we need to stop
        var ev: u64 = 0;
        _ = try os.read(stop_fd, std.mem.asBytes(&ev));
        if (ev > 0xff) {
            std.log.debug("HERE 1", .{});
            return;
        }
        std.log.debug("post setup, we don't need to stop", .{});
    }

    boot_loader.probe();
    {
        std.log.debug("post probe, checking if we need to stop", .{});
        // check if we need to stop
        var ev: u64 = 0;
        _ = try os.read(stop_fd, std.mem.asBytes(&ev));
        if (ev > 0xff) {
            std.log.debug("HERE 2", .{});
            return;
        }
        std.log.debug("post probe, we don't need to stop", .{});
    }

    const kexec_load_done = false;
    if (kexec_load_done) {
        var ev: u64 = 0xff1;
        _ = try os.write(ready_fd, std.mem.asBytes(&ev));
    }
}

pub const Autoboot = struct {
    ready_fd: os.fd_t,
    stop_fd: os.fd_t,
    thread: ?std.Thread,

    pub fn init() !@This() {
        return @This(){
            .ready_fd = try os.eventfd(0, os.linux.EFD.SEMAPHORE),
            .stop_fd = try os.eventfd(0xff, os.linux.EFD.SEMAPHORE),
            .thread = null,
        };
    }

    pub fn register(self: *@This(), epoll_fd: os.fd_t) !void {
        var ready_event = os.linux.epoll_event{
            .data = .{ .fd = self.ready_fd },
            // we will only be ready to boot once
            .events = os.linux.EPOLL.IN | os.linux.EPOLL.ONESHOT,
        };
        try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.ready_fd, &ready_event);
    }

    pub fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, autoboot, .{ self.ready_fd, self.stop_fd });
    }

    pub fn stop(self: *@This()) !void {
        if (self.thread != null) {
            var ev: u64 = 0xff1;
            _ = try os.write(self.stop_fd, std.mem.asBytes(&ev));
            self.thread.?.join();
        }
    }

    pub fn finish(self: *@This()) !?os.RebootCommand {
        var ev: u64 = 0;
        _ = try os.read(self.ready_fd, std.mem.asBytes(&ev));

        if (ev > 0xff) {
            return os.RebootCommand.KEXEC;
        } else {
            return null;
        }
    }

    pub fn deinit(self: *@This()) void {
        os.close(self.ready_fd);
        os.close(self.stop_fd);
        self.thread = null;
    }
};
