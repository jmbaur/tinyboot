const std = @import("std");
const posix = std.posix;
const system = std.posix.system;

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

pub const BootEntry = union(enum) {
    /// A directory that contains up to three files:
    /// - <dir>/linux
    /// - <dir>/initrd        (optional)
    /// - <dir>/kernel_params (optional)
    ///
    /// The directory will be cleaned up after usage. This is helpful to use
    /// when the boot files are created dynamically during boot. Do _not_ use
    /// this if boot files are coming from disk, use `BootEntry.Disk` instead.
    Dir: []const u8,

    /// A set of boot files. If these files are created dynamically during boot
    /// (e.g. loading over xmodem/network), use `BootEntry.Dir` instead.
    Disk: struct {
        /// Path to the linux kernel image.
        linux: []const u8,
        /// Optional path to the initrd.
        initrd: ?[]const u8 = null,
        /// Optional kernel parameters.
        cmdline: ?[]const u8 = null,
    },
};

pub fn kexecLoadFromDir(allocator: std.mem.Allocator, dir: []const u8) !void {
    var d = try std.fs.cwd().openDir(dir, .{});
    defer {
        std.log.info("cleaning up {s}", .{dir});
        std.fs.cwd().deleteTree(dir) catch {};
        d.close();
    }

    const linux = try d.realpathAlloc(allocator, "linux");
    defer allocator.free(linux);

    const initrd: ?[]const u8 = if (d.realpathAlloc(
        allocator,
        "initrd",
    )) |initrd| initrd else |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    defer {
        if (initrd) |_initrd| {
            allocator.free(_initrd);
        }
    }

    const cmdline: ?[]const u8 = b: {
        if (d.realpathAlloc(
            allocator,
            "kernel_params",
        )) |params_file| {
            defer allocator.free(params_file);
            break :b try std.fs.cwd().readFileAlloc(
                allocator,
                params_file,
                linux_headers.COMMAND_LINE_SIZE,
            );
        } else |err| switch (err) {
            error.FileNotFound => break :b null,
            else => return err,
        }
    };

    defer {
        if (cmdline) |_cmdline| {
            allocator.free(_cmdline);
        }
    }

    return kexecLoad(allocator, linux, initrd, cmdline);
}

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
    while (!kexec_is_loaded(f) and i > 0) : (i -= 1) {
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

    pub fn teardown(self: @This()) !void {
        std.log.debug("boot loader teardown", .{});

        switch (self) {
            inline else => |boot_loader| try boot_loader.teardown(),
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
        boot_loader.teardown() catch |err| {
            std.log.err("failed to teardown bootloader: {}", .{err});
        };
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
        std.log.info("using device \"{s}\"", .{dev.name});
        var countdown = dev.timeout;
        while (countdown > 0) : (countdown -= 1) {
            std.log.info("booting in {} second(s)", .{countdown});
            std.time.sleep(std.time.ns_per_s);
            if (try need_to_stop(stop_fd)) {
                return false;
            }
        }

        for (dev.entries) |boot_entry| {
            if (switch (boot_entry) {
                .Dir => |dir| kexecLoadFromDir(arena.allocator(), dir),
                .Disk => |entry| kexecLoad(
                    arena.allocator(),
                    entry.linux,
                    entry.initrd,
                    entry.cmdline,
                ),
            }) {
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
            .stop_fd = try posix.eventfd(@intCast(enum_to_eventfd(StopStatus.keep_going)), 0),
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
