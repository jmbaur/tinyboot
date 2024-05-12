const std = @import("std");
const os = std.os;
const posix = std.posix;
const E = std.os.linux.E;

const linux_headers = @import("linux_headers");

const BootLoaderSpec = @import("./boot/bls.zig").BootLoaderSpec;

const KEXEC_LOADED = "/sys/kernel/kexec_loaded";

// In eventfd, zero has special meaning (notably it will block reads), so we
// ensure our enum values aren't zero.
fn enum_to_eventfd(_enum: anytype) u64 {
    return @as(u64, @intFromEnum(_enum)) + 1;
}

fn eventfd_read(fd: posix.fd_t) !u64 {
    var ev: u64 = 0;
    _ = try posix.read(fd, std.mem.asBytes(&ev));
    return ev;
}

fn eventfd_write(fd: posix.fd_t, val: u64) !void {
    _ = try posix.write(fd, std.mem.asBytes(&val));
}

fn kexec_is_loaded(f: std.fs.File) bool {
    f.seekTo(0) catch return false;

    var is_loaded: u8 = 0;
    const bytes_read = f.read(std.mem.asBytes(&is_loaded)) catch return false;

    if (bytes_read != 1) {
        return false;
    }

    return is_loaded == '1';
}

pub const BootEntry = struct {
    /// Path to the linux kernel image.
    linux: []const u8,
    /// Optional path to the initrd.
    initrd: ?[]const u8 = null,
    /// Optional kernel parameters.
    cmdline: ?[]const u8 = null,
};

pub const Entry = struct {
    allocator: std.mem.Allocator,

    inner: BootEntry,

    // TODO(jared): This is bad that we end up allocating these things twice,
    // it is most definitely unecessary.
    pub fn init(
        allocator: std.mem.Allocator,
        entry: BootEntry,
    ) !@This() {
        return .{
            .allocator = allocator,
            .inner = .{
                .linux = try allocator.dupe(u8, entry.linux),
                .initrd = if (entry.initrd) |initrd|
                    try allocator.dupe(u8, initrd)
                else
                    null,
                .cmdline = if (entry.cmdline) |cmdline|
                    try allocator.dupe(u8, cmdline)
                else
                    null,
            },
        };
    }

    const LoadError = error{
        PermissionDenied,
        UnknownError,
    };

    pub fn load(self: *const @This()) !void {
        std.log.info("preparing kexec", .{});

        std.log.debug("loading kernel {s}", .{self.inner.linux});
        const linux = try std.fs.cwd().openFile(self.inner.linux, .{});
        defer linux.close();

        const linux_fd = @as(usize, @bitCast(@as(isize, linux.handle)));

        const initrd_fd = b: {
            if (self.inner.initrd) |initrd| {
                std.log.debug("loading initrd {s}", .{initrd});
                const file = try std.fs.cwd().openFile(initrd, .{});
                break :b file.handle;
            } else {
                break :b 0;
            }
        };

        defer {
            if (initrd_fd != 0) {
                posix.close(initrd_fd);
            }
        }

        // dupeZ() returns a null-terminated slice, however the null-terminator
        // is not included in the length of the slice, so we must add 1.
        std.log.debug("loading kernel params '{s}'", .{self.inner.cmdline orelse ""});
        const cmdline = try self.allocator.dupeZ(u8, self.inner.cmdline orelse "");
        defer self.allocator.free(cmdline);
        const cmdline_len = cmdline.len + 1;

        const rc = os.linux.syscall5(
            .kexec_file_load,
            linux_fd,
            @as(usize, @bitCast(@as(isize, initrd_fd))),
            cmdline_len,
            @intFromPtr(cmdline.ptr),
            if (initrd_fd == 0) linux_headers.KEXEC_FILE_NO_INITRAMFS else 0,
        );

        switch (os.linux.E.init(rc)) {
            E.SUCCESS => {
                // Wait for up to a second for kernel to report for kexec to be
                // loaded.
                var i: u8 = 10;
                var f = try std.fs.cwd().openFile(KEXEC_LOADED, .{});
                defer f.close();
                while (!kexec_is_loaded(f) and i > 0) : (i -= 1) {
                    std.time.sleep(100 * std.time.ns_per_ms);
                }

                std.log.info("kexec loaded", .{});
                return;
            },
            // IMA appraisal failed
            E.PERM => return LoadError.PermissionDenied,
            else => {
                std.log.err("kexec load failed: {}", .{os.linux.E.init(rc)});
                return LoadError.UnknownError;
            },
        }
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.inner.linux);
        if (self.inner.initrd) |initrd| {
            self.allocator.free(initrd);
        }
        if (self.inner.cmdline) |cmdline| {
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
    entries: []const Entry,
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

fn need_to_stop(stop_fd: posix.fd_t) !bool {
    defer {
        eventfd_write(stop_fd, enum_to_eventfd(Autoboot.StopStatus.keep_going)) catch {};
    }
    return try eventfd_read(stop_fd) == enum_to_eventfd(Autoboot.StopStatus.stop);
}

fn autoboot_wrapper(ready_fd: posix.fd_t, stop_fd: posix.fd_t) void {
    const success = autoboot(stop_fd) catch |err| b: {
        std.log.err("autoboot failed: {}", .{err});
        break :b false;
    };

    if (success) {
        eventfd_write(ready_fd, enum_to_eventfd(Autoboot.ReadyStatus.ready)) catch {};
    } else {
        // We must write something to ready_fd to ensure reads don't block.
        eventfd_write(ready_fd, enum_to_eventfd(Autoboot.ReadyStatus.not_ready)) catch {};
    }
}

/// Returns true if kexec has been successfully loaded.
fn autoboot(stop_fd: posix.fd_t) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    std.log.debug("autoboot started", .{});

    var bls = BootLoaderSpec.init();
    var boot_loader: BootLoader = .{ .bls = &bls };
    defer {
        boot_loader.teardown();
        std.log.debug("autoboot stopped", .{});
    }

    try boot_loader.setup();
    if (try need_to_stop(stop_fd)) {
        return false;
    }

    const boot_devices = try boot_loader.probe(arena.allocator());
    if (try need_to_stop(stop_fd)) {
        return false;
    }

    for (boot_devices) |dev| {
        std.log.info("using device '{s}'", .{dev.name});
        var countdown = dev.timeout;
        while (countdown > 0) : (countdown -= 1) {
            std.log.info("booting in {} seconds", .{countdown});
            std.time.sleep(std.time.ns_per_s);
            if (try need_to_stop(stop_fd)) {
                return false;
            }
        }

        for (dev.entries) |entry| {
            entry.load() catch |err| {
                std.log.err("failed to load boot entry: {}", .{err});
                continue;
            };

            return true;
        }
    }

    return false;
}

pub const Autoboot = struct {
    ready_fd: posix.fd_t,
    stop_fd: posix.fd_t,
    thread: ?std.Thread,

    pub const ReadyStatus = enum {
        ready,
        not_ready,
    };

    pub const StopStatus = enum {
        stop,
        keep_going,
    };

    pub fn init() !@This() {
        return .{
            .ready_fd = try posix.eventfd(0, 0),
            // Ensure that stop_fd can be read from right away without
            // blocking.
            .stop_fd = try posix.eventfd(@intCast(enum_to_eventfd(StopStatus.keep_going)), 0),
            .thread = null,
        };
    }

    pub fn register(self: *@This(), epoll_fd: posix.fd_t) !void {
        var ready_event = os.linux.epoll_event{
            .data = .{ .fd = self.ready_fd },
            // we will only be ready to boot once
            .events = os.linux.EPOLL.IN | os.linux.EPOLL.ONESHOT,
        };
        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.ready_fd, &ready_event);
    }

    pub fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, autoboot_wrapper, .{ self.ready_fd, self.stop_fd });
    }

    pub fn stop(self: *@This()) !void {
        if (self.thread) |thread| {
            try eventfd_write(self.stop_fd, enum_to_eventfd(StopStatus.stop));
            thread.join();
        }
    }

    pub fn finish(self: *@This()) !?posix.RebootCommand {
        const rc = try eventfd_read(self.ready_fd);
        if (rc == enum_to_eventfd(ReadyStatus.ready)) {
            return posix.RebootCommand.KEXEC;
        } else {
            return null;
        }
    }

    pub fn deinit(self: *@This()) void {
        posix.close(self.ready_fd);
        posix.close(self.stop_fd);
        self.stop() catch {};
        self.thread = null;
    }
};
