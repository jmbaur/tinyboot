const std = @import("std");
const posix = std.posix;

const BootLoader = @import("./bootloader.zig");
const Device = @import("../device.zig");
const TmpDir = @import("../tmpdir.zig");
const system = @import("../system.zig");
const ymodem = @import("../ymodem.zig");

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
            // https://www.kernel.org/doc/Documentation/admin-guide/devices.txt
            const major, const minor = node;
            if (major != 4 or minor < 64) {
                return null;
            }
        },
        else => return null,
    }

    var serial_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const serial_path = device.nodePath(&serial_path_buf) catch return null;
    var serial = std.fs.cwd().openFile(
        serial_path,
        .{ .mode = .read_write },
    ) catch return null;
    defer serial.close();

    if (!serialDeviceIsConnected(serial.handle)) {
        return null;
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

    var serial_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const serial_path = try device.nodePath(&serial_path_buf);

    var serial = try std.fs.cwd().openFile(serial_path, .{ .mode = .read_write });
    defer serial.close();

    var tty = try system.setupTty(serial.handle, .file_transfer);
    defer {
        tty.reset();

        // If the TTY is being used for user input, this will allow for the
        // next message printed to the TTY to be legible.
        tty.writer().writeByte('\n') catch {};
    }

    self.tmpdir = try TmpDir.create(.{});

    var tmpdir = self.tmpdir.?;

    {
        // Temporarily turn off the system console so that no kernel logs are
        // printed during the file transfer process.
        system.toggleConsole(.off) catch {};
        defer system.toggleConsole(.on) catch {};

        try ymodem.recv(&tty, tmpdir.dir);
    }

    var params_file = try tmpdir.dir.openFile("params", .{});
    defer params_file.close();

    const kernel_params_bytes = try params_file.readToEndAlloc(
        allocator,
        linux_headers.COMMAND_LINE_SIZE,
    );

    const kernel_params = std.mem.trim(u8, kernel_params_bytes, &std.ascii.whitespace);

    const linux = try tmpdir.dir.realpathAlloc(allocator, "linux");
    const initrd = b: {
        if (tmpdir.dir.realpathAlloc(allocator, "initrd")) |initrd| {
            break :b initrd;
        } else |err| {
            if (err == error.FileNotFound) {
                break :b null;
            } else {
                return err;
            }
        }
    };

    try entries.append(.{
        .context = try allocator.create(struct {}),
        .linux = linux,
        .initrd = initrd,
        .cmdline = if (kernel_params.len > 0) kernel_params else null,
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
