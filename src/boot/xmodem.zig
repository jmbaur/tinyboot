const std = @import("std");
const posix = std.posix;

const linux_headers = @import("linux_headers");

const BootLoader = @import("./bootloader.zig");
const Device = @import("../device.zig");
const TmpDir = @import("../tmpdir.zig");
const system = @import("../system.zig");
const xmodemRecv = @import("../xmodem.zig").xmodemRecv;

const XmodemBootLoader = @This();

arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
tmpdir: ?TmpDir = null,

pub fn match(device: *const Device) ?u8 {
    if (device.subsystem != .tty) {
        return null;
    }

    switch (device.type) {
        .node => |node| {
            // https://www.kernel.org/doc/Documentation/admin-guide/devices.txt
            const major, const minor = node;
            if (major == 4 and minor >= 64) {
                return 100;
            } else {
                return null;
            }
        },
        else => return null,
    }
}

pub fn init() XmodemBootLoader {
    return .{};
}

pub fn name() []const u8 {
    return "xmodem";
}

pub fn timeout(self: *XmodemBootLoader) u8 {
    _ = self;
    return 0;
}

pub fn probe(self: *XmodemBootLoader, entries: *std.ArrayList(BootLoader.Entry), device: Device) !void {
    const allocator = self.arena.allocator();

    var serial_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const serial_path = try device.nodePath(&serial_path_buf);

    var serial = try std.fs.cwd().openFile(serial_path, .{ .mode = .read_write });
    defer serial.close();

    var original_serial = try system.setupTty(serial.handle, .file_transfer_recv);
    defer original_serial.reset();

    self.tmpdir = try TmpDir.create(.{});

    var tmpdir = self.tmpdir.?;

    var linux = try tmpdir.dir.createFile("linux", .{});
    defer linux.close();

    try xmodemRecv(serial.handle, linux.writer());

    var initrd = try tmpdir.dir.createFile("initrd", .{});
    defer initrd.close();

    try xmodemRecv(serial.handle, initrd.writer());

    var params_file = try tmpdir.dir.createFile("params", .{
        .read = true,
    });
    defer params_file.close();

    try xmodemRecv(
        serial.handle,
        params_file.writer(),
    );

    try params_file.seekTo(0);
    const kernel_params_bytes = try params_file.readToEndAlloc(
        allocator,
        linux_headers.COMMAND_LINE_SIZE,
    );

    // trim out whitespace characters
    const kernel_params = std.mem.trim(u8, kernel_params_bytes, " \t\n");

    try entries.append(.{
        .context = try allocator.create(struct {}),
        .cmdline = if (kernel_params.len > 0) kernel_params else null,
        .initrd = try tmpdir.dir.realpathAlloc(
            allocator,
            "initrd",
        ),
        .linux = try tmpdir.dir.realpathAlloc(
            allocator,
            "linux",
        ),
    });
}

pub fn entryLoaded(self: *XmodemBootLoader, ctx: *anyopaque) void {
    _ = self;
    _ = ctx;
}

pub fn deinit(self: *XmodemBootLoader) void {
    self.arena.deinit();

    if (self.tmpdir) |*tmpdir| {
        tmpdir.cleanup();
        self.tmpdir = null;
    }
}
