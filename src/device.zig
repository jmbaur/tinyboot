const std = @import("std");
const posix = std.posix;
const path = std.fs.path;
const system = posix.system;

const linux_headers = @import("linux_headers");

const Uevent = std.StringHashMap([]const u8);

const DeviceError = error{
    CreateFailed,
    IncompleteDevice,
};

pub fn parseUeventFileContents(allocator: std.mem.Allocator, contents: []const u8) !Uevent {
    var uevent = Uevent.init(allocator);

    var iter = std.mem.splitSequence(u8, contents, "\n");

    while (iter.next()) |line| {
        var split = std.mem.splitSequence(u8, line, "=");
        const key = split.next() orelse continue;
        const value = split.next() orelse continue;
        try uevent.put(key, value);
    }

    return uevent;
}

const Action = enum {
    add,
    remove,
    bind,

    fn parse(action: []const u8) ?@This() {
        if (std.mem.eql(u8, action, "add")) {
            return .add;
        } else if (std.mem.eql(u8, action, "remove")) {
            return .remove;
        } else if (std.mem.eql(u8, action, "bind")) {
            return .bind;
        }

        return null;
    }
};

const Kobject = struct {
    action: Action,
    device_path: []const u8,
    uevent: Uevent,

    pub fn deinit(self: *@This()) void {
        self.uevent.deinit();
    }
};

fn parseUeventKobjectContents(allocator: std.mem.Allocator, contents: []const u8) !?Kobject {
    var iter = std.mem.splitSequence(u8, contents, &.{0});

    const first_line = iter.next().?;
    var first_line_split = std.mem.splitSequence(u8, first_line, "@");
    if (Action.parse(first_line_split.next().?)) |action| {
        var uevent = Uevent.init(allocator);

        const device_path = first_line_split.next().?;

        while (iter.next()) |line| {
            var split = std.mem.splitSequence(u8, line, "=");
            const key = split.next() orelse continue;
            const value = split.next() orelse continue;
            try uevent.put(key, value);
        }

        return .{
            .action = action,
            .device_path = device_path,
            .uevent = uevent,
        };
    }

    return null;
}

fn makedev(major: u32, minor: u32) u32 {
    return std.math.shl(u32, major & 0xfffff000, 32) |
        std.math.shl(u32, major & 0x00000fff, 8) |
        std.math.shl(u32, minor & 0xffffff00, 12) |
        std.math.shl(u32, minor & 0x000000ff, 0);
}

fn special(devtype: ?[]const u8) u32 {
    if (devtype) |dtype| {
        if (std.mem.eql(u8, dtype, "disk") or std.mem.eql(u8, dtype, "partition")) {
            return system.S.IFBLK;
        }
    }

    return system.S.IFCHR;
}

/// Caller owns return value
fn diskAliasFilename(allocator: std.mem.Allocator, uevent: Uevent) ![]const u8 {
    const diskseq = uevent.get("DISKSEQ") orelse return DeviceError.IncompleteDevice;

    if (uevent.get("PARTN")) |partn| {
        return try std.fmt.allocPrint(allocator, "disk{s}_part{s}", .{ diskseq, partn });
    } else {
        return try std.fmt.allocPrint(allocator, "disk{s}", .{diskseq});
    }
}

pub const DeviceWatcher = struct {
    // busybox uses these buffer sizes
    const USER_RCVBUF = 3 * 1024;
    const KERN_RCVBUF = 128 * 1024 * 1024;

    arena: std.heap.ArenaAllocator,

    disk_dir: std.fs.Dir,
    block_dir: std.fs.Dir,
    char_dir: std.fs.Dir,

    /// Netlink socket fd for subscribing to new device events.
    nl_fd: posix.fd_t,

    /// Timer fd for determining when new events have "settled".
    settle_fd: posix.fd_t,

    pub fn init() !@This() {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        try std.fs.cwd().makePath("/dev/disk");
        try std.fs.cwd().makePath("/dev/block");
        try std.fs.cwd().makePath("/dev/char");

        var self = @This(){
            .arena = arena,
            .disk_dir = try std.fs.cwd().openDir("/dev/disk", .{}),
            .block_dir = try std.fs.cwd().openDir("/dev/block", .{}),
            .char_dir = try std.fs.cwd().openDir("/dev/char", .{}),
            .nl_fd = try posix.socket(
                system.AF.NETLINK,
                system.SOCK.DGRAM,
                system.NETLINK.KOBJECT_UEVENT,
            ),
            .settle_fd = try posix.timerfd_create(posix.CLOCK.REALTIME, .{}),
        };
        errdefer self.deinit();

        try self.scanAndCreateDevices();
        _ = self.arena.reset(.retain_capacity);

        try posix.setsockopt(self.nl_fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, KERN_RCVBUF)));
        try posix.setsockopt(self.nl_fd, posix.SOL.SOCKET, posix.SO.RCVBUFFORCE, &std.mem.toBytes(@as(c_int, KERN_RCVBUF)));

        const nls = posix.sockaddr.nl{
            .groups = 1, // KOBJECT_UEVENT groups bitmask must be 1
            .pid = @bitCast(system.getpid()),
        };
        try posix.bind(self.nl_fd, @ptrCast(&nls), @sizeOf(posix.sockaddr.nl));

        return self;
    }

    pub fn register(self: *@This(), epoll_fd: posix.fd_t) !void {
        var device_event = system.epoll_event{
            .data = .{ .fd = self.nl_fd },
            .events = system.EPOLL.IN,
        };
        try posix.epoll_ctl(epoll_fd, system.EPOLL.CTL_ADD, self.nl_fd, &device_event);

        var timer_event = system.epoll_event{
            .data = .{ .fd = self.settle_fd },
            .events = system.EPOLL.IN | system.EPOLL.ONESHOT,
        };
        try posix.epoll_ctl(epoll_fd, system.EPOLL.CTL_ADD, self.settle_fd, &timer_event);
    }

    pub fn startSettleTimer(self: *@This()) !void {
        const timerspec = system.itimerspec{
            // oneshot
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            // consider settled after 2 seconds without any new events
            .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
        };
        try posix.timerfd_settime(self.settle_fd, .{}, &timerspec, null);
    }

    pub fn handleNewEvent(self: *@This()) !void {
        defer _ = self.arena.reset(.retain_capacity);

        // reset the timer
        try self.startSettleTimer();

        var recv_bytes: [USER_RCVBUF]u8 = undefined;

        const bytes_read = try posix.read(self.nl_fd, &recv_bytes);

        const kobject = try parseUeventKobjectContents(
            self.arena.allocator(),
            recv_bytes[0..bytes_read],
        ) orelse return;

        switch (kobject.action) {
            .add => try self.createDevice(kobject.uevent),
            .remove => try self.removeDevice(kobject.uevent),
            else => {},
        }
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.disk_dir.close();
        self.block_dir.close();
        self.char_dir.close();
        posix.close(self.nl_fd);
        posix.close(self.settle_fd);
    }

    fn scanAndCreateDevices(self: *@This()) !void {
        const allocator = self.arena.allocator();

        {
            var sys_class_block = try std.fs.cwd().openDir(
                "/sys/class/block",
                .{ .iterate = true },
            );
            defer sys_class_block.close();

            var it = sys_class_block.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .sym_link) {
                    continue;
                }

                const uevent_path = try path.join(allocator, &.{
                    entry.name,
                    "uevent",
                });

                var uevent_file = try sys_class_block.openFile(uevent_path, .{});
                defer uevent_file.close();

                const max_bytes = 10 * 1024 * 1024;
                const uevent_contents = try uevent_file.readToEndAlloc(
                    allocator,
                    max_bytes,
                );

                const uevent = try parseUeventFileContents(allocator, uevent_contents);

                self.createDevice(uevent) catch |err| {
                    std.log.err("failed to create device: {any}", .{err});
                    continue;
                };
            }
        }

        {
            var sys_class_tty = try std.fs.cwd().openDir(
                "/sys/class/tty",
                .{ .iterate = true },
            );
            defer sys_class_tty.close();

            var it = sys_class_tty.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .sym_link) {
                    continue;
                }

                // skip known non-serial devices
                if (std.mem.eql(u8, entry.name, "tty") or
                    std.mem.eql(u8, entry.name, "console") or
                    std.mem.eql(u8, entry.name, "ptmx") or
                    std.mem.eql(u8, entry.name, "ttynull"))
                {
                    continue;
                }

                const tty_uevent_path = try path.join(allocator, &.{
                    entry.name,
                    "uevent",
                });

                var uevent_file = try sys_class_tty.openFile(tty_uevent_path, .{});
                defer uevent_file.close();

                const max_bytes = 10 * 1024 * 1024;
                const uevent_contents = try uevent_file.readToEndAlloc(allocator, max_bytes);

                const uevent = try parseUeventFileContents(allocator, uevent_contents);

                self.createDevice(uevent) catch |err| {
                    std.log.err("failed to create device: {any}", .{err});
                    continue;
                };
            }
        }
    }

    fn createDevice(self: *@This(), uevent: Uevent) !void {
        // Nothing to do if we don't have major or minor.
        const major_str = uevent.get("MAJOR") orelse return;
        const minor_str = uevent.get("MINOR") orelse return;

        const major = try std.fmt.parseInt(u32, major_str, 10);
        const minor = try std.fmt.parseInt(u32, minor_str, 10);

        const mode = special(uevent.get("DEVTYPE"));

        const devname = uevent.get("DEVNAME") orelse return DeviceError.IncompleteDevice;

        const dev_path = path.join(self.arena.allocator(), &.{ path.sep_str, "dev", devname }) catch return;

        if (path.dirname(dev_path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }

        const dev_path_cstr = try self.arena.allocator().dupeZ(u8, dev_path);

        const rc = system.mknod(dev_path_cstr, mode, makedev(major, minor));
        switch (posix.errno(rc)) {
            .SUCCESS => std.log.debug("created device {s}", .{dev_path}),
            .EXIST => {}, // device already exists
            else => return DeviceError.CreateFailed,
        }

        switch (mode) {
            system.S.IFBLK => try self.createBlkAlias(dev_path, major, minor, uevent),
            system.S.IFCHR => try self.createCharAlias(dev_path, major, minor),
            else => {},
        }
    }

    fn createBlkAlias(
        self: *@This(),
        dev_path: []const u8,
        major: u32,
        minor: u32,
        uevent: Uevent,
    ) !void {
        const alias_filename = try diskAliasFilename(self.arena.allocator(), uevent);

        self.disk_dir.symLink(dev_path, alias_filename, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const major_minor_filename = try std.fmt.allocPrint(
            self.arena.allocator(),
            "{d}:{d}",
            .{ major, minor },
        );

        self.block_dir.symLink(dev_path, major_minor_filename, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        std.log.info("created block device alias for block device {s}", .{dev_path});
    }

    fn createCharAlias(
        self: *@This(),
        dev_path: []const u8,
        major: u32,
        minor: u32,
    ) !void {
        const filename = try std.fmt.allocPrint(
            self.arena.allocator(),
            "{d}:{d}",
            .{ major, minor },
        );

        self.char_dir.symLink(dev_path, filename, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    fn removeDevice(self: *@This(), uevent: Uevent) !void {
        // Nothing to do if we don't have major or minor.
        const major_str = uevent.get("MAJOR") orelse return;
        const minor_str = uevent.get("MINOR") orelse return;
        const major = try std.fmt.parseInt(u32, major_str, 10);
        const minor = try std.fmt.parseInt(u32, minor_str, 10);
        const mode = special(uevent.get("DEVTYPE"));

        const devname = uevent.get("DEVNAME") orelse return DeviceError.IncompleteDevice;
        const dev_path = path.join(self.arena.allocator(), &.{ path.sep_str, "dev", devname }) catch return;

        std.fs.cwd().deleteFile(dev_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        switch (mode) {
            system.S.IFBLK => try self.removeBlkAlias(dev_path, major, minor, uevent),
            system.S.IFCHR => try self.removeCharAlias(major, minor),
            else => {},
        }
    }

    fn removeBlkAlias(
        self: *@This(),
        dev_path: []const u8,
        major: u32,
        minor: u32,
        uevent: Uevent,
    ) !void {
        const alias_filename = try diskAliasFilename(self.arena.allocator(), uevent);

        self.disk_dir.deleteFile(alias_filename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const major_minor_filename = try std.fmt.allocPrint(self.arena.allocator(), "{d}:{d}", .{ major, minor });

        self.block_dir.deleteFile(major_minor_filename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        std.log.info("removed block device aliases for block device {s}", .{dev_path});
    }

    fn removeCharAlias(
        self: *@This(),
        major: u32,
        minor: u32,
    ) !void {
        var buf: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "{d}:{d}", .{ major, minor });

        const alias_path = try path.join(self.arena.allocator(), &.{ path.sep_str, "dev", "char", filename });

        std.fs.cwd().deleteFile(alias_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

test "device mode" {
    try std.testing.expectEqual(@as(u32, system.S.IFCHR), special(null));
    try std.testing.expectEqual(@as(u32, system.S.IFCHR), special("foo"));
    try std.testing.expectEqual(@as(u32, system.S.IFBLK), special("disk"));
    try std.testing.expectEqual(@as(u32, system.S.IFBLK), special("partition"));
}

test "uevent file content parsing" {
    const test_partition =
        \\MAJOR=259
        \\MINOR=1
        \\DEVNAME=nvme0n1p1
        \\DEVTYPE=partition
        \\DISKSEQ=1
        \\PARTN=1
    ;

    var partition_uevent = try parseUeventFileContents(std.testing.allocator, test_partition);
    defer partition_uevent.deinit();

    try std.testing.expectEqualStrings("259", partition_uevent.get("MAJOR").?);
    try std.testing.expectEqualStrings("partition", partition_uevent.get("DEVTYPE").?);
    try std.testing.expectEqualStrings("1", partition_uevent.get("DISKSEQ").?);
    try std.testing.expectEqualStrings("1", partition_uevent.get("PARTN").?);

    const test_disk =
        \\MAJOR=259
        \\MINOR=0
        \\DEVNAME=nvme0n1
        \\DEVTYPE=disk
        \\DISKSEQ=1
    ;

    var disk_uevent = try parseUeventFileContents(std.testing.allocator, test_disk);
    defer disk_uevent.deinit();

    try std.testing.expectEqualStrings("259", disk_uevent.get("MAJOR").?);
    try std.testing.expectEqualStrings("disk", disk_uevent.get("DEVTYPE").?);
    try std.testing.expectEqualStrings("1", disk_uevent.get("DISKSEQ").?);

    const test_tpm =
        \\MAJOR=10
        \\MINOR=224
        \\DEVNAME=tpm0
    ;

    var tpm_uevent = try parseUeventFileContents(std.testing.allocator, test_tpm);
    defer tpm_uevent.deinit();

    try std.testing.expectEqualStrings("10", tpm_uevent.get("MAJOR").?);
    try std.testing.expectEqualStrings("224", tpm_uevent.get("MINOR").?);
    try std.testing.expectEqualStrings("tpm0", tpm_uevent.get("DEVNAME").?);
}

test "uevent kobject add chardev parsing" {
    const content = try std.mem.join(std.testing.allocator, &.{0}, &.{
        "add@/devices/platform/serial8250/tty/ttyS6",
        "ACTION=add",
        "DEVPATH=/devices/platform/serial8250/tty/ttyS6",
        "SUBSYSTEM=tty",
        "SYNTH_UUID=0",
        "MAJOR=4",
        "MINOR=70",
        "DEVNAME=ttyS6",
        "SEQNUM=3469",
    });
    defer std.testing.allocator.free(content);

    var kobject = try parseUeventKobjectContents(std.testing.allocator, content) orelse unreachable;
    defer kobject.deinit();

    try std.testing.expectEqual(Action.add, kobject.action);
    try std.testing.expectEqualStrings("/devices/platform/serial8250/tty/ttyS6", kobject.device_path);
    try std.testing.expectEqualStrings("0", kobject.uevent.get("SYNTH_UUID").?);
}

test "uevent kobject remove chardev parsing" {
    const content = try std.mem.join(std.testing.allocator, &.{0}, &.{
        "remove@/devices/platform/serial8250/tty/ttyS6",
        "ACTION=remove",
        "DEVPATH=/devices/platform/serial8250/tty/ttyS6",
        "SUBSYSTEM=tty",
        "SYNTH_UUID=0",
        "MAJOR=4",
        "MINOR=70",
        "DEVNAME=ttyS6",
        "SEQNUM=3471",
    });
    defer std.testing.allocator.free(content);

    var kobject = try parseUeventKobjectContents(std.testing.allocator, content) orelse unreachable;
    defer kobject.deinit();

    try std.testing.expectEqual(Action.remove, kobject.action);
    try std.testing.expectEqualStrings("/devices/platform/serial8250/tty/ttyS6", kobject.device_path);
    try std.testing.expectEqualStrings("3471", kobject.uevent.get("SEQNUM").?);
}

/// Find all active serial and virtual terminals where we can spawn a console.
/// Caller is responsible for the returned list.
pub fn findActiveConsoles(allocator: std.mem.Allocator) ![]posix.fd_t {
    var devs = std.ArrayList(posix.fd_t).init(allocator);
    errdefer devs.deinit();

    // TODO(jared): don't assume a monitor is connected
    const tty0_fd = try posix.open("/dev/tty0", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    try devs.append(tty0_fd);

    var char_devices_dir = try std.fs.cwd().openDir(
        "/dev/char",
        .{ .iterate = true },
    );
    defer char_devices_dir.close();

    var walker = try char_devices_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .sym_link) {
            continue;
        }

        var split = std.mem.splitScalar(u8, entry.basename, ':');
        const major_str = split.next() orelse continue;
        const minor_str = split.next() orelse continue;
        if (split.next() != null) {
            continue;
        }

        const major = std.fmt.parseInt(u32, major_str, 10) catch continue;
        const minor = std.fmt.parseInt(u32, minor_str, 10) catch continue;

        // TODO(jared): handle major number 204
        switch (major) {
            linux_headers.TTY_MAJOR => {
                // First serial device is at minor number 64. See
                // https://github.com/torvalds/linux/blob/841c35169323cd833294798e58b9bf63fa4fa1de/Documentation/admin-guide/devices.txt#L137
                if (minor < 64) {
                    continue;
                }

                var fullpath_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const fullpath = char_devices_dir.realpath(entry.path, &fullpath_buf) catch continue;

                const fd = try posix.open(fullpath, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

                if (serialDeviceIsConnected(fd)) {
                    std.log.info("found active serial device at {s}", .{fullpath});
                    try devs.append(fd);
                } else {
                    posix.close(fd);
                }
            },
            else => {},
        }
    }

    return devs.toOwnedSlice();
}

fn serialDeviceIsConnected(fd: posix.fd_t) bool {
    var serial: c_int = 0;

    if (system.ioctl(fd, linux_headers.TIOCMGET, @intFromPtr(&serial)) != 0) {
        return false;
    }

    return serial & linux_headers.TIOCM_DTR == linux_headers.TIOCM_DTR;
}
