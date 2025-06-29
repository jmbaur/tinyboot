const std = @import("std");
const posix = std.posix;

const BootLoader = @import("./bootloader.zig");
const Device = @import("../device.zig");
const TmpDir = @import("../tmpdir.zig");
const system = @import("../system.zig");
const ymodem = @import("../ymodem.zig");
const utils = @import("../utils.zig");

const linux_headers = @import("linux_headers");

const YmodemBootLoader = @This();

pub const autoboot = false;

arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
tmpdir: ?TmpDir = null,

fn serialDeviceIsConnected(fd: posix.fd_t) bool {
    var serial: c_int = 0;

    if (posix.system.ioctl(
        fd,
        linux_headers.TIOCMGET,
        @intFromPtr(&serial),
    ) != 0) {
        return false;
    }

    return serial & linux_headers.TIOCM_DTR == linux_headers.TIOCM_DTR;
}

pub fn match(device: *const Device) ?u8 {
    if (device.subsystem != .tty) {
        return null;
    }

    switch (device.type) {
        .node => |node| {
            const major, const minor = node;

            // https://www.kernel.org/doc/Documentation/admin-guide/devices.txt
            const nodeMatch = switch (major) {
                4 => minor >= 64,
                204 => minor >= 64,
                229 => true,
                else => false,
            };

            if (!nodeMatch) {
                return null;
            }
        },
        else => return null,
    }

    var serial_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const serial_path = device.nodePath(&serial_path_buf) catch return null;
    var serial = std.fs.cwd().openFile(
        serial_path,
        .{ .mode = .read_write },
    ) catch |err| {
        std.log.err("failed to open {}: {}", .{ device, err });
        return null;
    };
    defer serial.close();

    // Prioritize serial devices that are already connected.
    if (!serialDeviceIsConnected(serial.handle)) {
        return 105;
    }

    return 100;
}

pub fn init() YmodemBootLoader {
    return .{};
}

pub fn name() []const u8 {
    return "ymodem";
}

pub fn timeout(self: *YmodemBootLoader) u8 {
    _ = self;

    return 0;
}

pub fn probe(self: *YmodemBootLoader, entries: *std.ArrayList(BootLoader.Entry), device: Device) !void {
    const allocator = self.arena.allocator();

    var serial_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const serial_path = try device.nodePath(&serial_path_buf);

    var serial = try std.fs.cwd().openFile(serial_path, .{ .mode = .read_write });
    defer serial.close();

    var tty = system.Tty.init(serial.handle);
    defer {
        tty.deinit();

        // If the TTY is being used for user input, this will allow for the
        // next message printed to the TTY to be legible.
        tty.writer().writeByte('\n') catch {};
    }

    try tty.setMode(.file_transfer);

    self.tmpdir = try TmpDir.create(.{});

    var tmpdir = self.tmpdir.?;

    {
        // Temporarily turn off the system console so that no kernel logs are
        // printed during the file transfer process.
        system.setConsole(.off) catch {};
        defer system.setConsole(.on) catch {};

        try ymodem.recv(&tty, tmpdir.dir);
    }

    const linux = try utils.realpathAllocMany(
        tmpdir.dir,
        allocator,
        &.{ "linux", "kernel" },
    );

    const initrd: ?[]const u8 = b: {
        break :b utils.realpathAllocMany(
            tmpdir.dir,
            allocator,
            &.{ "initrd", "initramfs" },
        ) catch |err| switch (err) {
            error.FileNotFound => break :b null,
            else => return err,
        };
    };

    const cmdline: ?[]const u8 = b: {
        const fullpath = utils.realpathAllocMany(
            tmpdir.dir,
            allocator,
            &.{ "kernel-params", "params", "options" },
        ) catch |err| switch (err) {
            error.FileNotFound => break :b null,
            else => return err,
        };

        const cmdline_file = try tmpdir.dir.openFile(fullpath, .{});
        defer cmdline_file.close();

        const cmdline_bytes = try cmdline_file.readToEndAlloc(allocator, linux_headers.COMMAND_LINE_SIZE);
        break :b std.mem.trim(u8, cmdline_bytes, &std.ascii.whitespace);
    };

    try entries.append(.{
        .context = try allocator.create(struct {}),
        .linux = linux,
        .initrd = initrd,
        .cmdline = cmdline,
    });
}

pub fn entryLoaded(self: *YmodemBootLoader, ctx: *anyopaque) void {
    _ = self;
    _ = ctx;
}

pub fn deinit(self: *YmodemBootLoader) void {
    self.arena.deinit();

    if (self.tmpdir) |*tmpdir| {
        tmpdir.cleanup();
        self.tmpdir = null;
    }
}
