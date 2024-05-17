const std = @import("std");
const posix = std.posix;

const BootEntry = @import("../boot.zig").BootEntry;
const BootDevice = @import("../boot.zig").BootDevice;
const tmp = @import("../tmp.zig");
const Tty = @import("../system.zig").Tty;
const xmodemRecv = @import("../xmodem.zig").xmodemRecv;
const setupTty = @import("../system.zig").setupTty;

pub const Xmodem = struct {
    allocator: std.mem.Allocator,
    tmp_dir: tmp.TmpDir,
    original_tty: ?Tty = null,
    tty_fd: posix.fd_t,
    tty_name: []const u8,
    skip_initrd: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: struct {
        tty_name: []const u8,
        tty_fd: posix.fd_t,
        skip_initrd: bool,
    }) !@This() {
        return .{
            .tty_name = opts.tty_name,
            .tty_fd = opts.tty_fd,
            .skip_initrd = opts.skip_initrd,
            .allocator = allocator,
            .tmp_dir = try tmp.tmpDir(.{}),
        };
    }

    pub fn setup(self: *@This()) !void {
        self.original_tty = try setupTty(posix.STDIN_FILENO, .file_transfer_recv);
    }

    pub fn probe(self: *@This(), final_allocator: std.mem.Allocator) ![]const BootDevice {
        defer {
            if (self.original_tty) |tty| {
                tty.reset();
            }
            self.original_tty = null;
        }

        const kernel_bytes = try xmodemRecv(self.allocator, posix.STDIN_FILENO);
        // Free up the kernel bytes since this is large.
        // TODO(jared): Make xmodemRecv accept a std.io.Writer.
        defer self.allocator.free(kernel_bytes);

        var linux = try self.tmp_dir.dir.createFile("linux", .{});
        defer linux.close();
        try linux.writeAll(kernel_bytes);

        const initrd_bytes = try xmodemRecv(self.allocator, posix.STDIN_FILENO);
        // Free up the initrd bytes since this is large.
        // TODO(jared): Make xmodemRecv accept a std.io.Writer.
        defer self.allocator.free(initrd_bytes);

        if (!self.skip_initrd) {
            var initrd = try self.tmp_dir.dir.createFile("initrd", .{});
            defer initrd.close();
            try initrd.writeAll(initrd_bytes);
        }

        const kernel_params_bytes = try xmodemRecv(final_allocator, posix.STDIN_FILENO);

        // trim out the xmodem filler character (0xff) and newlines (0x0a)
        const kernel_params = std.mem.trimRight(
            u8,
            kernel_params_bytes,
            &.{ 0xff, 0x0a },
        );

        var devices = std.ArrayList(BootDevice).init(final_allocator);
        var entries = std.ArrayList(BootEntry).init(final_allocator);

        try entries.append(.{
            .context = try final_allocator.create(struct {}),
            .cmdline = kernel_params,
            .initrd = if (!self.skip_initrd) try self.tmp_dir.dir.realpathAlloc(
                final_allocator,
                "initrd",
            ) else null,
            .linux = try self.tmp_dir.dir.realpathAlloc(
                final_allocator,
                "linux",
            ),
        });

        try devices.append(.{
            .timeout = 0,
            .entries = try entries.toOwnedSlice(),
            .name = self.tty_name,
        });
        return devices.toOwnedSlice();
    }

    pub fn entryLoaded(self: *@This(), ctx: *anyopaque) void {
        _ = self;
        _ = ctx;
    }

    pub fn teardown(self: *@This()) !void {
        self.tmp_dir.cleanup();
        if (self.original_tty) |tty| {
            tty.reset();
        }
    }
};
