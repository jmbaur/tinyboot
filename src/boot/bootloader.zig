const std = @import("std");
const posix = std.posix;

const linux_headers = @import("linux_headers");

const Device = @import("../device.zig");

const BootLoader = @This();

pub const Entry = struct {
    /// Will be passed to underlying boot loader after a successful kexec load.
    context: *anyopaque,
    /// Path to the linux kernel image.
    linux: []const u8,
    /// Optional path to the initrd.
    initrd: ?[]const u8 = null,
    /// Optional kernel parameters.
    cmdline: ?[]const u8 = null,
};

probed: bool = false,
boot_attempted: bool = false,
priority: u8,
device: Device,
allocator: std.mem.Allocator,
entries: std.ArrayList(Entry),
inner: *anyopaque,
vtable: *const struct {
    name: *const fn () []const u8,
    probe: *const fn (*anyopaque, *std.ArrayList(Entry), Device) anyerror!void,
    timeout: *const fn (*anyopaque) u8,
    entryLoaded: *const fn (*anyopaque, Entry) void,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
},

pub fn init(
    comptime T: type,
    device: Device,
    priority: u8,
    allocator: std.mem.Allocator,
) !BootLoader {
    const inner = try allocator.create(T);

    inner.* = T.init();

    const wrapper = struct {
        pub fn deinit(ctx: *anyopaque, a: std.mem.Allocator) void {
            const self: *T = @ptrCast(@alignCast(ctx));
            defer a.destroy(self);

            self.deinit();
        }

        pub fn probe(
            ctx: *anyopaque,
            entries: *std.ArrayList(Entry),
            d: Device,
        ) !void {
            const self: *T = @ptrCast(@alignCast(ctx));

            try self.probe(entries, d);
        }

        pub fn entryLoaded(ctx: *anyopaque, entry: Entry) void {
            const self: *T = @ptrCast(@alignCast(ctx));

            self.entryLoaded(entry.context);
        }

        pub fn timeout(ctx: *anyopaque) u8 {
            const self: *T = @ptrCast(@alignCast(ctx));

            return self.timeout();
        }
    };

    return .{
        .priority = priority,
        .device = device,
        .allocator = allocator,
        .entries = std.ArrayList(Entry).init(allocator),
        .inner = inner,
        .vtable = &.{
            .name = T.name,
            .probe = wrapper.probe,
            .timeout = wrapper.timeout,
            .entryLoaded = wrapper.entryLoaded,
            .deinit = wrapper.deinit,
        },
    };
}

pub fn deinit(self: *BootLoader) void {
    defer self.entries.deinit();

    self.vtable.deinit(self.inner, self.allocator);
}

pub fn name(self: *BootLoader) []const u8 {
    return self.vtable.name();
}

pub fn timeout(self: *BootLoader) !u8 {
    _ = try self.probe();

    return self.vtable.timeout(self.inner);
}

pub fn probe(self: *BootLoader) ![]const Entry {
    if (!self.probed) {
        std.log.debug("bootloader not yet probed", .{});
        try self.vtable.probe(self.inner, &self.entries, self.device);
        self.probed = true;
        std.log.debug("bootloader probed", .{});
    }

    return self.entries.items;
}

pub fn load(self: *BootLoader, entry: Entry) !void {
    self.boot_attempted = true;

    try kexecLoad(self.allocator, entry.linux, entry.initrd, entry.cmdline);

    self.vtable.entryLoaded(self.inner, entry);
}

const KEXEC_LOADED = "/sys/kernel/kexec_loaded";

fn kexecIsLoaded(f: std.fs.File) bool {
    f.seekTo(0) catch return false;

    var is_loaded: u8 = 0;
    const bytes_read = f.read(std.mem.asBytes(&is_loaded)) catch return false;

    if (bytes_read != 1) {
        return false;
    }

    return is_loaded == '1';
}

fn kexecLoad(
    allocator: std.mem.Allocator,
    linux: []const u8,
    initrd: ?[]const u8,
    cmdline: ?[]const u8,
) !void {
    std.log.info("preparing kexec", .{});
    std.log.info("loading linux {s}", .{linux});
    std.log.info("loading initrd {s}", .{initrd orelse "<none>"});
    std.log.info("loading params {s}", .{cmdline orelse "<none>"});

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

    var flags: usize = 0;
    if (initrd == null) {
        flags |= linux_headers.KEXEC_FILE_NO_INITRAMFS;
    }

    // dupeZ() returns a null-terminated slice, however the null-terminator
    // is not included in the length of the slice, so we must add 1.
    const cmdline_z = try allocator.dupeZ(u8, cmdline orelse "");
    defer allocator.free(cmdline_z);
    const cmdline_len = cmdline_z.len + 1;

    const rc = posix.system.syscall5(
        .kexec_file_load,
        linux_fd,
        @as(usize, @bitCast(@as(isize, initrd_fd))),
        cmdline_len,
        @intFromPtr(cmdline_z.ptr),
        flags,
    );

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        // IMA appraisal failed
        .ACCES => return error.PermissionDenied,
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
