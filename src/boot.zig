const std = @import("std");
const posix = std.posix;
const system = std.posix.system;

const linux_headers = @import("linux_headers");

const BootLoaderSpec = @import("./boot/bls.zig").BootLoaderSpec;

const KEXEC_LOADED = "/sys/kernel/kexec_loaded";

// In eventfd, zero has special meaning (notably it will block reads), so we
// ensure our enum values aren't zero.
fn enumToEventfd(_enum: anytype) u64 {
    return @as(u64, @intFromEnum(_enum)) + 1;
}

fn eventfdRead(fd: posix.fd_t) !u64 {
    var ev: u64 = 0;
    _ = try posix.read(fd, std.mem.asBytes(&ev));
    return ev;
}

fn eventfdWrite(fd: posix.fd_t, val: u64) !void {
    _ = try posix.write(fd, std.mem.asBytes(&val));
}

fn kexecIsLoaded(f: std.fs.File) bool {
    f.seekTo(0) catch return false;

    var is_loaded: u8 = 0;
    const bytes_read = f.read(std.mem.asBytes(&is_loaded)) catch return false;

    if (bytes_read != 1) {
        return false;
    }

    return is_loaded == '1';
}

pub const BootEntry = struct {
    /// Will be passed to entryLoaded() after a successful kexec load.
    context: *anyopaque,
    /// Path to the linux kernel image.
    linux: []const u8,
    /// Optional path to the initrd.
    initrd: ?[]const u8 = null,
    /// Optional kernel parameters.
    cmdline: ?[]const u8 = null,
};

pub fn kexecLoad(
    allocator: std.mem.Allocator,
    linux: []const u8,
    initrd: ?[]const u8,
    params: ?[]const u8,
) !void {
    std.log.info("preparing kexec", .{});
    std.log.info("loading linux {s}", .{linux});
    std.log.info("loading initrd {s}", .{initrd orelse "<none>"});
    std.log.info("loading params {s}", .{params orelse "<none>"});

    const _linux = try std.fs.cwd().openFile(linux, .{});
    defer _linux.close();

    const linux_fd = @as(usize, @bitCast(@as(isize, _linux.handle)));

    const initrd_fd = b: {
        if (initrd) |_initrd| {
            const file = try std.fs.cwd().openFile(_initrd, .{});
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
    const cmdline = try allocator.dupeZ(u8, params orelse "");
    defer allocator.free(cmdline);
    const cmdline_len = cmdline.len + 1;

    const rc = system.syscall5(
        .kexec_file_load,
        linux_fd,
        @as(usize, @bitCast(@as(isize, initrd_fd))),
        cmdline_len,
        @intFromPtr(cmdline.ptr),
        if (initrd_fd == 0) linux_headers.KEXEC_FILE_NO_INITRAMFS else 0,
    );

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        // IMA appraisal failed
        .PERM => return error.PermissionDenied,
        // Invalid kernel image (CONFIG_RELOCATABLE not enabled?)
        .NOEXEC => return error.InvalidExe,
        // Another image is already loaded
        .BUSY => return error.FilesAlreadyRegistered,
        .NOMEM => return error.SystemResources,
        .BADF => return error.InvalidFileDescriptor,
        else => |err| {
            std.log.err("kexec load failed for unknown reason: {}", .{err});
            return posix.unexpectedErrno(err);
        },
    }

    // Wait for up to a second for kernel to report for kexec to be loaded.
    var i: u8 = 10;
    var f = try std.fs.cwd().openFile(KEXEC_LOADED, .{});
    defer f.close();
    while (!kexecIsLoaded(f) and i > 0) : (i -= 1) {
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    std.log.info("kexec loaded", .{});
}

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

    /// Caller is responsible for all memory corresponding to return value.
    pub fn probe(self: @This(), allocator: std.mem.Allocator) ![]const BootDevice {
        std.log.debug("boot loader probe", .{});

        return switch (self) {
            inline else => |boot_loader| try boot_loader.probe(allocator),
        };
    }

    /// An infallible function that provides a way to hook into the stage of
    /// the boot process after a successful kexec load has been performed
    /// and before the reboot occurs.
    pub fn entryLoaded(self: @This(), ctx: *anyopaque) void {
        switch (self) {
            inline else => |boot_loader| boot_loader.entryLoaded(ctx),
        }
    }

    pub fn teardown(self: @This()) !void {
        std.log.debug("boot loader teardown", .{});

        switch (self) {
            inline else => |boot_loader| try boot_loader.teardown(),
        }
    }
};

fn needToStop(stop_fd: posix.fd_t) !bool {
    defer {
        eventfdWrite(stop_fd, enumToEventfd(Autoboot.StopStatus.keep_going)) catch {};
    }
    return try eventfdRead(stop_fd) == enumToEventfd(Autoboot.StopStatus.stop);
}

fn autobootWrapper(ready_fd: posix.fd_t, stop_fd: posix.fd_t) void {
    const success = autoboot(stop_fd) catch |err| b: {
        std.log.err("autoboot failed: {}", .{err});
        break :b false;
    };

    if (success) {
        eventfdWrite(ready_fd, enumToEventfd(Autoboot.ReadyStatus.ready)) catch {};
    } else {
        // We must write something to ready_fd to ensure reads don't block.
        eventfdWrite(ready_fd, enumToEventfd(Autoboot.ReadyStatus.not_ready)) catch {};
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
        boot_loader.teardown() catch |err| {
            std.log.err("failed to teardown bootloader: {}", .{err});
        };
        std.log.debug("autoboot stopped", .{});
    }

    try boot_loader.setup();
    if (try needToStop(stop_fd)) {
        return false;
    }

    const boot_devices = try boot_loader.probe(arena.allocator());
    if (try needToStop(stop_fd)) {
        return false;
    }

    for (boot_devices) |dev| {
        std.log.info("using device \"{s}\"", .{dev.name});
        var countdown = dev.timeout;
        while (countdown > 0) : (countdown -= 1) {
            std.log.info("booting in {} second(s)", .{countdown});
            std.time.sleep(std.time.ns_per_s);
            if (try needToStop(stop_fd)) {
                return false;
            }
        }

        for (dev.entries) |entry| {
            if (kexecLoad(
                arena.allocator(),
                entry.linux,
                entry.initrd,
                entry.cmdline,
            )) {
                boot_loader.entryLoaded(entry.context);
                return true;
            } else |err| {
                std.log.err("failed to load boot entry: {}", .{err});
            }
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
            .stop_fd = try posix.eventfd(@intCast(enumToEventfd(StopStatus.keep_going)), 0),
            .thread = null,
        };
    }

    pub fn register(self: *@This(), epoll_fd: posix.fd_t) !void {
        var ready_event = system.epoll_event{
            .data = .{ .fd = self.ready_fd },
            // we will only be ready to boot once
            .events = system.EPOLL.IN | system.EPOLL.ONESHOT,
        };
        try posix.epoll_ctl(epoll_fd, system.EPOLL.CTL_ADD, self.ready_fd, &ready_event);
    }

    pub fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, autobootWrapper, .{ self.ready_fd, self.stop_fd });
    }

    pub fn stop(self: *@This()) !void {
        if (self.thread) |thread| {
            try eventfdWrite(self.stop_fd, enumToEventfd(StopStatus.stop));
            thread.join();
        }
    }

    pub fn finish(self: *@This()) !?posix.RebootCommand {
        const rc = try eventfdRead(self.ready_fd);
        if (rc == enumToEventfd(ReadyStatus.ready)) {
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
