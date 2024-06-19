const std = @import("std");
const posix = std.posix;

const BootEntry = @import("../boot.zig").BootEntry;
const BootDevice = @import("../boot.zig").BootDevice;
const tmp = @import("../tmp.zig");
const Tty = @import("../system.zig").Tty;
const xmodemRecv = @import("../xmodem.zig").xmodemRecv;
const setupTty = @import("../system.zig").setupTty;
const linux_headers = @import("linux_headers");

pub const Xmodem = struct {
    allocator: std.mem.Allocator,
    tmp_dir: tmp.TmpDir,
    original_serial: ?Tty = null,
    serial_fd: posix.fd_t,
    serial_name: []const u8,
    skip_initrd: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: struct {
        /// A human-friendly name of the serial console
        serial_name: []const u8,
        /// The file descriptor associated with this serial console
        serial_fd: posix.fd_t,
        /// Indicates whether the initrd should be fetched in addition to the
        /// kernel and cmdline parameters.
        skip_initrd: bool,
    }) !@This() {
        return .{
            .serial_name = opts.serial_name,
            .serial_fd = opts.serial_fd,
            .skip_initrd = opts.skip_initrd,
            .allocator = allocator,
            .tmp_dir = try tmp.tmpDir(.{}),
        };
    }

    pub fn setup(self: *@This()) !void {
        self.original_serial = try setupTty(self.serial_fd, .file_transfer_recv);
    }

    pub fn probe(self: *@This()) ![]const BootDevice {
        errdefer {
            if (self.original_serial) |tty| {
                tty.reset();
            }
            self.original_serial = null;
        }

        var linux = try self.tmp_dir.dir.createFile("linux", .{});
        defer linux.close();

        try xmodemRecv(self.serial_fd, linux.writer());

        if (!self.skip_initrd) {
            var initrd = try self.tmp_dir.dir.createFile("initrd", .{});
            defer initrd.close();

            try xmodemRecv(self.serial_fd, initrd.writer());
        }

        var params_file = try self.tmp_dir.dir.createFile("params", .{
            .read = true,
        });
        defer params_file.close();

        try xmodemRecv(
            self.serial_fd,
            params_file.writer(),
        );

        if (self.original_serial) |tty| {
            tty.reset();
        }
        self.original_serial = null;

        try params_file.seekTo(0);
        const kernel_params_bytes = try params_file.readToEndAlloc(
            self.allocator,
            linux_headers.COMMAND_LINE_SIZE,
        );

        // trim out whitespace characters
        const kernel_params = std.mem.trim(u8, kernel_params_bytes, " \t\n");

        var devices = std.ArrayList(BootDevice).init(self.allocator);
        var entries = std.ArrayList(BootEntry).init(self.allocator);

        try entries.append(.{
            .context = try self.allocator.create(struct {}),
            .cmdline = if (kernel_params.len > 0) kernel_params else null,
            .initrd = if (!self.skip_initrd) try self.tmp_dir.dir.realpathAlloc(
                self.allocator,
                "initrd",
            ) else null,
            .linux = try self.tmp_dir.dir.realpathAlloc(
                self.allocator,
                "linux",
            ),
        });

        try devices.append(.{
            .timeout = 0,
            .entries = try entries.toOwnedSlice(),
            .name = self.serial_name,
        });
        return devices.toOwnedSlice();
    }

    pub fn entryLoaded(self: *@This(), ctx: *anyopaque) void {
        _ = self;
        _ = ctx;
    }

    pub fn teardown(self: *@This()) !void {
        self.tmp_dir.cleanup();
        if (self.original_serial) |tty| {
            tty.reset();
        }
    }
};
