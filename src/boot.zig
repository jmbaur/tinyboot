const std = @import("std");
const os = std.os;
const E = std.os.linux.E;

const linux_headers = @import("linux_headers");

const BootLoaderSpec = @import("./boot/bls.zig").BootLoaderSpec;

const kexec_loaded_path = "/sys/kernel/kexec_loaded";

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
    allocator: std.mem.Allocator,

    /// Path to the linux kernel image.
    linux: []const u8,
    /// Optional path to the initrd.
    initrd: ?[]const u8 = null,
    /// Optional kernel parameters.
    cmdline: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        mountpoint: []const u8,
        linux: []const u8,
        initrd: ?[]const u8,
        cmdline: ?[]const u8,
    ) !@This() {
        return .{
            .allocator = allocator,
            .linux = try std.fs.path.join(allocator, &.{ mountpoint, linux }),
            .initrd = if (initrd) |_initrd|
                try std.fs.path.join(allocator, &.{ mountpoint, _initrd })
            else
                null,
            .cmdline = if (cmdline) |_cmdline|
                try allocator.dupe(u8, _cmdline)
            else
                null,
        };
    }

    const LoadError = error{
        PermissionDenied,
        UnknownError,
    };

    pub fn load(self: *const @This()) !void {
        const linux = try std.fs.openFileAbsolute(self.linux, .{});
        defer linux.close();

        const linux_fd = @as(usize, @bitCast(@as(isize, linux.handle)));

        // dupeZ() returns a null-terminated slice, however the null-terminator
        // is not included in the length of the slice, so we must add 1.
        const cmdline = try self.allocator.dupeZ(u8, self.cmdline orelse "");
        const cmdline_len = cmdline.len + 1;

        const rc = b: {
            if (self.initrd) |i| {
                const initrd = try std.fs.openFileAbsolute(i, .{});
                defer initrd.close();

                const initrd_fd = @as(usize, @bitCast(@as(isize, initrd.handle)));

                break :b os.linux.syscall5(
                    .kexec_file_load,
                    linux_fd,
                    initrd_fd,
                    cmdline_len,
                    @intFromPtr(cmdline.ptr),
                    0,
                );
            } else {
                const initrd_fd = @as(usize, @bitCast(@as(isize, 0)));

                break :b os.linux.syscall5(
                    .kexec_file_load,
                    linux_fd,
                    initrd_fd,
                    cmdline_len,
                    @intFromPtr(cmdline.ptr),
                    linux_headers.KEXEC_FILE_NO_INITRAMFS,
                );
            }
        };

        switch (os.linux.getErrno(rc)) {
            E.SUCCESS => {
                // Wait for up to a second for kernel to report for kexec to be
                // loaded.
                var i: u8 = 10;
                var f = try std.fs.openFileAbsolute(kexec_loaded_path, .{});
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
                std.log.err("ERROR: {} {}", .{ rc, os.linux.getErrno(rc) });
                return LoadError.UnknownError;
            },
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
    defer {
        const reset: u64 = 0x1;
        _ = os.write(stop_fd, std.mem.asBytes(&reset)) catch {};
    }
    var ev: u64 = 0;
    _ = try os.read(stop_fd, std.mem.asBytes(&ev));
    return ev > 0x1;
}

fn autoboot_wrapper(ready_fd: os.fd_t, stop_fd: os.fd_t) void {
    const success = autoboot(stop_fd) catch |err| b: {
        std.log.err("autoboot failed: {}", .{err});
        break :b false;
    };

    if (success) {
        const autoboot_success: u64 = 0x2;
        _ = os.write(ready_fd, std.mem.asBytes(&autoboot_success)) catch {};
    } else {
        // We must write something to ready_fd to ensure reads on it don't
        // block.
        const autoboot_fail: u64 = 0x1;
        _ = os.write(ready_fd, std.mem.asBytes(&autoboot_fail)) catch {};
    }
}

/// Returns true if kexec has been successfully loaded.
fn autoboot(stop_fd: os.fd_t) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    std.log.debug("autoboot started", .{});

    var bls = BootLoaderSpec.init(std.heap.page_allocator);
    var boot_loader: BootLoader = .{ .bls = &bls };
    defer {
        boot_loader.teardown();
        std.log.debug("autoboot stopped", .{});
    }

    try boot_loader.setup();
    if (try need_to_stop(stop_fd)) {
        return false;
    }

    const boot_devices = try boot_loader.probe(allocator);
    if (try need_to_stop(stop_fd)) {
        return false;
    }

    for (boot_devices) |dev| {
        var countdown = @as(u64, dev.timeout);
        while (countdown > 0) : (countdown -= 1) {
            std.time.sleep(1 * std.time.ns_per_s);
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
    ready_fd: os.fd_t,
    stop_fd: os.fd_t,
    thread: ?std.Thread,

    pub fn init() !@This() {
        return .{
            .ready_fd = try os.eventfd(0x0, 0),
            // Ensure that stop_fd can be read() from right away without
            // blocking.
            .stop_fd = try os.eventfd(0x1, 0),
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
        self.thread = try std.Thread.spawn(.{}, autoboot_wrapper, .{ self.ready_fd, self.stop_fd });
    }

    pub fn stop(self: *@This()) !void {
        if (self.thread != null) {
            const stop_indicator: u64 = 0x2;
            _ = try os.write(self.stop_fd, std.mem.asBytes(&stop_indicator));
            self.thread.?.join();
        }
    }

    pub fn finish(self: *@This()) !?os.RebootCommand {
        var ev: u64 = 0;
        _ = try os.read(self.ready_fd, std.mem.asBytes(&ev));

        if (ev > 0x1) {
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
