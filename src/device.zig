const std = @import("std");
const os = std.os;
const posix = std.posix;
const path = std.fs.path;
const linux = os.linux;

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
            return linux.S.IFBLK;
        }
    }

    return linux.S.IFCHR;
}

fn diskAliasPath(allocator: std.mem.Allocator, uevent: Uevent) ![]const u8 {
    const diskseq = uevent.get("DISKSEQ") orelse return DeviceError.IncompleteDevice;

    var buf: [32]u8 = undefined;
    const diskseq_partn_filename = name: {
        if (uevent.get("PARTN")) |partn| {
            break :name try std.fmt.bufPrint(&buf, "disk{d}_part{d}", .{ diskseq, partn });
        } else {
            break :name try std.fmt.bufPrint(&buf, "disk{d}", .{diskseq});
        }
    };

    return try path.join(allocator, &.{ path.sep_str, "dev", "disk", diskseq_partn_filename });
}

fn createBlkAlias(
    allocator: std.mem.Allocator,
    dev_path: []const u8,
    major: u32,
    minor: u32,
    uevent: Uevent,
) !void {
    const alias_path = try diskAliasPath(allocator, uevent);
    defer allocator.free(alias_path);

    std.fs.symLinkAbsolute(dev_path, alias_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var buf: [32]u8 = undefined;
    const major_minor_filename = try std.fmt.bufPrint(&buf, "{d}:{d}", .{ major, minor });

    const major_minor_alias_path = try path.join(allocator, &.{ path.sep_str, "dev", "block", major_minor_filename });
    defer allocator.free(major_minor_alias_path);

    std.fs.symLinkAbsolute(dev_path, major_minor_alias_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    std.log.info("created block device aliases for {s}", .{dev_path});
}

fn removeBlkAlias(
    allocator: std.mem.Allocator,
    dev_path: []const u8,
    major: u32,
    minor: u32,
    uevent: Uevent,
) !void {
    const alias_path = try diskAliasPath(allocator, uevent);
    defer allocator.free(alias_path);

    std.fs.symLinkAbsolute(dev_path, alias_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var buf: [32]u8 = undefined;
    const major_minor_filename = try std.fmt.bufPrint(&buf, "{d}:{d}", .{ major, minor });

    const major_minor_alias_path = try path.join(allocator, &.{ path.sep_str, "dev", "block", major_minor_filename });
    defer allocator.free(major_minor_alias_path);

    std.fs.deleteFileAbsolute(major_minor_alias_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    std.log.info("removed block device aliases for {s}", .{dev_path});
}

fn createCharAlias(
    allocator: std.mem.Allocator,
    dev_path: []const u8,
    major: u32,
    minor: u32,
) !void {
    var buf: [32]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{d}:{d}", .{ major, minor });

    const alias_path = try path.join(allocator, &.{ path.sep_str, "dev", "char", filename });
    defer allocator.free(alias_path);

    std.fs.symLinkAbsolute(dev_path, alias_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn removeCharAlias(
    allocator: std.mem.Allocator,
    major: u32,
    minor: u32,
) !void {
    var buf: [32]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{d}:{d}", .{ major, minor });

    const alias_path = try path.join(allocator, &.{ path.sep_str, "dev", "char", filename });
    defer allocator.free(alias_path);

    std.fs.deleteFileAbsolute(alias_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn createDevice(allocator: std.mem.Allocator, uevent: Uevent) !void {
    // Nothing to do if we don't have major or minor.
    const major_str = uevent.get("MAJOR") orelse return;
    const minor_str = uevent.get("MINOR") orelse return;

    const major = try std.fmt.parseInt(u32, major_str, 10);
    const minor = try std.fmt.parseInt(u32, minor_str, 10);

    const mode = special(uevent.get("DEVTYPE"));

    const devname = uevent.get("DEVNAME") orelse return DeviceError.IncompleteDevice;

    const dev_path = path.join(allocator, &.{ path.sep_str, "dev", devname }) catch return;
    defer allocator.free(dev_path);

    if (path.dirname(dev_path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const dev_path_cstr = try allocator.dupeZ(u8, dev_path);
    defer allocator.free(dev_path_cstr);

    const rc = linux.mknod(dev_path_cstr, mode, makedev(major, minor));
    switch (linux.E.init(rc)) {
        .SUCCESS => std.log.debug("created device {s}", .{dev_path}),
        .EXIST => {}, // device already exists
        else => return DeviceError.CreateFailed,
    }

    switch (mode) {
        linux.S.IFBLK => try createBlkAlias(allocator, dev_path, major, minor, uevent),
        linux.S.IFCHR => try createCharAlias(allocator, dev_path, major, minor),
        else => {},
    }
}

fn removeDevice(allocator: std.mem.Allocator, uevent: Uevent) !void {
    // Nothing to do if we don't have major or minor.
    const major_str = uevent.get("MAJOR") orelse return;
    const minor_str = uevent.get("MINOR") orelse return;
    const major = try std.fmt.parseInt(u32, major_str, 10);
    const minor = try std.fmt.parseInt(u32, minor_str, 10);
    const mode = special(uevent.get("DEVTYPE"));

    const devname = uevent.get("DEVNAME") orelse return DeviceError.IncompleteDevice;
    const dev_path = path.join(allocator, &.{ path.sep_str, "dev", devname }) catch return;
    defer allocator.free(dev_path);

    std.fs.deleteFileAbsolute(dev_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    switch (mode) {
        linux.S.IFBLK => try removeBlkAlias(allocator, dev_path, major, minor, uevent),
        linux.S.IFCHR => try removeCharAlias(allocator, major, minor),
        else => {},
    }
}

fn scanAndCreateDevices(arena: *std.heap.ArenaAllocator) !void {
    const allocator = arena.allocator();

    {
        try std.fs.makeDirAbsolute("/dev/disk"); // prepare disk alias directory
        try std.fs.makeDirAbsolute("/dev/block"); // prepare block alias directory

        var sys_class_block = try std.fs.openDirAbsolute(
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

            createDevice(allocator, uevent) catch |err| {
                std.log.err("failed to create device: {any}", .{err});
                continue;
            };
        }
    }

    {
        try std.fs.makeDirAbsolute("/dev/char"); // prepare char alias directory

        var sys_class_tty = try std.fs.openDirAbsolute(
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

            createDevice(allocator, uevent) catch |err| {
                std.log.err("failed to create device: {any}", .{err});
                continue;
            };
        }
    }
}

pub const DeviceWatcher = struct {
    // busybox uses these buffer sizes
    const USER_RCVBUF = 3 * 1024;
    const KERN_RCVBUF = 128 * 1024 * 1024;

    arena: std.heap.ArenaAllocator,

    /// Netlink socket fd for subscribing to new device events.
    nl_fd: posix.fd_t,

    /// Timer fd for determining when new events have "settled".
    settle_fd: posix.fd_t,

    pub fn init() !@This() {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        try scanAndCreateDevices(&arena);

        var self = @This(){
            .arena = arena,
            .nl_fd = try posix.socket(
                linux.AF.NETLINK,
                linux.SOCK.DGRAM,
                linux.NETLINK.KOBJECT_UEVENT,
            ),
            .settle_fd = try posix.timerfd_create(posix.CLOCK.REALTIME, .{}),
        };
        errdefer self.deinit();

        try posix.setsockopt(self.nl_fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, KERN_RCVBUF)));
        try posix.setsockopt(self.nl_fd, posix.SOL.SOCKET, posix.SO.RCVBUFFORCE, &std.mem.toBytes(@as(c_int, KERN_RCVBUF)));

        const nls = posix.sockaddr.nl{
            .groups = 1, // KOBJECT_UEVENT groups bitmask must be 1
            .pid = @bitCast(os.linux.getpid()),
        };
        try posix.bind(self.nl_fd, @ptrCast(&nls), @sizeOf(posix.sockaddr.nl));

        return self;
    }

    pub fn register(self: *@This(), epoll_fd: posix.fd_t) !void {
        var device_event = os.linux.epoll_event{
            .data = .{ .fd = self.nl_fd },
            .events = os.linux.EPOLL.IN,
        };
        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.nl_fd, &device_event);

        var timer_event = os.linux.epoll_event{
            .data = .{ .fd = self.settle_fd },
            .events = os.linux.EPOLL.IN | os.linux.EPOLL.ONESHOT,
        };
        try posix.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.settle_fd, &timer_event);
    }

    pub fn start_settle_timer(self: *@This()) !void {
        const timerspec = os.linux.itimerspec{
            // oneshot
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            // consider settled after 2 seconds without any new events
            .it_value = .{ .tv_sec = 2, .tv_nsec = 0 },
        };
        try posix.timerfd_settime(self.settle_fd, .{}, &timerspec, null);
    }

    pub fn handle_new_event(self: *@This()) !void {
        // reset the timer
        try self.start_settle_timer();

        var recv_bytes: [USER_RCVBUF]u8 = undefined;

        const bytes_read = try posix.read(self.nl_fd, &recv_bytes);

        const allocator = self.arena.allocator();

        var kobject = try parseUeventKobjectContents(allocator, recv_bytes[0..bytes_read]) orelse return;
        defer kobject.deinit();

        switch (kobject.action) {
            .add => try createDevice(allocator, kobject.uevent),
            .remove => try removeDevice(allocator, kobject.uevent),
            else => {},
        }
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        posix.close(self.nl_fd);
        posix.close(self.settle_fd);
    }
};

test "device mode" {
    try std.testing.expectEqual(@as(u32, linux.S.IFCHR), special(null));
    try std.testing.expectEqual(@as(u32, linux.S.IFCHR), special("foo"));
    try std.testing.expectEqual(@as(u32, linux.S.IFBLK), special("disk"));
    try std.testing.expectEqual(@as(u32, linux.S.IFBLK), special("partition"));
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

    var char_devices_dir = try std.fs.openDirAbsolute(
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

    if (os.linux.ioctl(fd, linux_headers.TIOCMGET, @intFromPtr(&serial)) != 0) {
        return false;
    }

    return serial & linux_headers.TIOCM_DTR == linux_headers.TIOCM_DTR;
}
