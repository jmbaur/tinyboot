const std = @import("std");
const os = std.os;
const E = std.os.linux.E;

const linux_headers = @import("linux_headers");

const BootLoaderSpec = @import("./boot/bls.zig").BootLoaderSpec;

pub const BootEntry = struct {
    allocator: std.mem.Allocator,

    /// Path to the linux kernel image.
    linux: []const u8,
    /// Optional path to the initrd.
    initrd: ?[]const u8 = null,
    /// Optional kernel parameters.
    cmdline: ?[]const []const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        mountpoint: []const u8,
        linux: []const u8,
        initrd: ?[]const u8,
        cmdline: ?[]const []const u8,
    ) !@This() {
        var self = @This(){
            .allocator = allocator,
            .linux = try std.fs.path.join(allocator, &.{ mountpoint, linux }),
        };
        if (initrd) |i| {
            self.initrd = try std.fs.path.join(allocator, &.{ mountpoint, i });
        }
        if (cmdline) |_cmdline| {
            self.cmdline = try allocator.dupe([]const u8, _cmdline);
        }
        return self;
    }

    const LoadError = error{
        PermissionDenied,
        UnknownError,
    };

    pub fn load(self: *const @This()) !void {
        const linux = try std.fs.openFileAbsolute(self.linux, .{});
        defer linux.close();

        const cmdline: [:0]const u8 = b: {
            if (self.cmdline) |cmdline| {
                break :b try std.mem.joinZ(self.allocator, " ", cmdline);
            } else {
                break :b try self.allocator.dupeZ(u8, "");
            }
        };
        defer self.allocator.free(cmdline);

        const rc = b: {
            if (self.initrd) |i| {
                const initrd = try std.fs.openFileAbsolute(i, .{});
                defer initrd.close();

                break :b os.linux.syscall5(
                    .kexec_file_load,
                    @intCast(linux.handle),
                    @intCast(initrd.handle),
                    cmdline.len,
                    @intFromPtr(cmdline.ptr),
                    0,
                );
            } else {
                break :b os.linux.syscall5(
                    .kexec_file_load,
                    @intCast(linux.handle),
                    0,
                    cmdline.len,
                    @intFromPtr(cmdline.ptr),
                    linux_headers.KEXEC_FILE_NO_INITRAMFS,
                );
            }
        };

        switch (os.linux.getErrno(rc)) {
            E.SUCCESS => return,
            // IMA appraisal failed
            E.PERM => return LoadError.PermissionDenied,
            else => return LoadError.UnknownError,
        }
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.linux);
        if (self.initrd) |initrd| {
            self.allocator.free(initrd);
        }
        if (self.cmdline) |cmdline| {
            self.allocator.free(cmdline);
        }
    }
};

pub const BootDevice = struct {
    name: []const u8,
    /// Timeout in seconds which will be used to determine when a boot entry
    /// should be selected automatically by the bootloader.
    timeout: u8,
    /// Boot entries found on this device. The entry at the first index will
    /// serve as the default entry.
    entries: []const BootEntry,
};

pub const BootLoader = union(enum) {
    bls: *BootLoaderSpec,

    pub fn setup(self: @This()) !void {
        std.log.debug("boot loader setup", .{});

        switch (self) {
            inline else => |boot_loader| try boot_loader.setup(),
        }
    }

    pub fn probe(self: @This(), allocator: std.mem.Allocator) ![]const BootDevice {
        std.log.debug("boot loader probe", .{});

        return switch (self) {
            inline else => |boot_loader| boot_loader.probe(allocator),
        };
    }

    pub fn teardown(self: @This()) void {
        std.log.debug("boot loader teardown", .{});

        switch (self) {
            inline else => |boot_loader| boot_loader.teardown(),
        }
    }
};

// TODO(jared): don't use magic numbers
fn need_to_stop(stop_fd: os.fd_t) !bool {
    var ev: u64 = 0;
    _ = try os.read(stop_fd, std.mem.asBytes(&ev));
    return ev > 0xff;
}

fn autoboot(ready_fd: os.fd_t, stop_fd: os.fd_t) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    std.log.debug("autoboot started", .{});

    var bls = BootLoaderSpec.init(std.heap.page_allocator);
    var boot_loader: BootLoader = .{ .bls = &bls };
    defer {
        boot_loader.teardown();
        std.log.debug("autoboot stopped", .{});

        // write to ready_fd to ensure reads on it don't block
        var ev: u64 = 0x1;
        _ = os.write(ready_fd, std.mem.asBytes(&ev)) catch {};
    }

    try boot_loader.setup();
    {
        if (try need_to_stop(stop_fd)) {
            std.log.debug("stopping autoboot", .{});
            return;
        }
        std.log.debug("post setup, we don't need to stop", .{});
    }

    const boot_devices = try boot_loader.probe(allocator);
    {
        if (try need_to_stop(stop_fd)) {
            std.log.debug("stopping autoboot", .{});
            return;
        }
        std.log.debug("post probe, we don't need to stop", .{});
    }

    for (boot_devices) |dev| {
        var countdown = @as(u64, dev.timeout);
        while (countdown > 0) : (countdown -= 1) {
            std.time.sleep(1 * dev.timeout);
            if (try need_to_stop(stop_fd)) {
                std.log.debug("stopping autoboot", .{});
                return;
            }
        }

        for (dev.entries) |entry| {
            entry.load() catch |err| {
                std.log.err("failed to load boot entry: {}", .{err});
                continue;
            };

            // we are done, ready to kexec
            var ev: u64 = 0xff1;
            _ = try os.write(ready_fd, std.mem.asBytes(&ev));
            return;
        }
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
