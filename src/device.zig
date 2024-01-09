const std = @import("std");
const os = std.os;
const path = std.fs.path;
const linux = std.os.linux;

const Uevent = std.StringHashMap([]const u8);

const DeviceError = error{
    CreateFailed,
    IncompleteDevice,
};

fn parseUeventFileContents(a: std.mem.Allocator, contents: []const u8) !Uevent {
    var uevent = Uevent.init(a);

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

    fn parse(action: []const u8) ?@This() {
        if (std.mem.eql(u8, action, "add")) {
            return .add;
        } else if (std.mem.eql(u8, action, "remove")) {
            return .remove;
        }

        return null;
    }
};

const Kobject = struct {
    action: Action,
    device_path: []const u8,
    uevent: Uevent,
};

fn parseUeventKobjectContents(a: std.mem.Allocator, contents: []const u8) !Kobject {
    var iter = std.mem.splitSequence(u8, contents, &.{0});

    const first_line = iter.next().?;
    var first_line_split = std.mem.splitSequence(u8, first_line, "@");
    if (Action.parse(first_line_split.next().?)) |action| {
        var uevent = Uevent.init(a);

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

    @panic("hi");
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

fn createBlkAlias(a: std.mem.Allocator, dev_path: []const u8, uevent: Uevent) !void {
    const diskseq = uevent.get("DISKSEQ") orelse return DeviceError.IncompleteDevice;

    const filename = name: {
        if (uevent.get("PARTN")) |partn| {
            break :name try std.mem.concat(a, u8, &.{ "disk", diskseq, "_part", partn });
        } else {
            break :name try std.mem.concat(a, u8, &.{ "disk", diskseq });
        }
    };
    defer a.free(filename);

    const alias_path = try path.join(a, &.{ path.sep_str, "dev", "disk", filename });
    defer a.free(alias_path);

    try std.os.symlink(dev_path, alias_path);

    std.log.info("created block device alias for {s}", .{dev_path});
}

fn createDevice(a: std.mem.Allocator, uevent: Uevent) !void {
    const major_str = uevent.get("MAJOR") orelse return DeviceError.IncompleteDevice;
    const minor_str = uevent.get("MINOR") orelse return DeviceError.IncompleteDevice;
    const devname = uevent.get("DEVNAME") orelse return DeviceError.IncompleteDevice;
    const devtype = uevent.get("DEVTYPE");

    const dev_path = path.join(a, &.{ path.sep_str, "dev", devname }) catch return;
    defer a.free(dev_path);

    const major = try std.fmt.parseInt(u32, major_str, 10);
    const minor = try std.fmt.parseInt(u32, minor_str, 10);

    const mode = special(devtype);

    const dev_path_cstr = try a.dupeZ(u8, dev_path);
    defer a.free(dev_path_cstr);

    const rc = linux.mknod(dev_path_cstr, mode, makedev(major, minor));
    switch (linux.getErrno(rc)) {
        .SUCCESS => std.log.debug("created device {s}", .{dev_path}),
        .EXIST => {}, // device already exists
        else => return DeviceError.CreateFailed,
    }

    if (mode == linux.S.IFBLK) {
        try createBlkAlias(a, dev_path, uevent);
    }
}

fn scanAndCreateDevices(a: std.mem.Allocator) !void {
    var sys_class_block = try std.fs.openIterableDirAbsolute(
        "/sys/class/block",
        .{},
    );
    defer sys_class_block.close();

    var it = sys_class_block.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .sym_link) {
            continue;
        }

        const full_path = try path.join(a, &.{
            path.sep_str,
            "sys",
            "class",
            "block",
            entry.name,
            "uevent",
        });
        defer a.free(full_path);

        var uevent_path = try std.fs.openFileAbsolute(full_path, .{});
        defer uevent_path.close();

        const max_bytes = 10 * 1024 * 1024;
        const uevent_contents = try uevent_path.readToEndAlloc(a, max_bytes);
        defer a.free(uevent_contents);

        var uevent = try parseUeventFileContents(a, uevent_contents);
        defer uevent.deinit();

        createDevice(a, uevent) catch |err| {
            std.log.err("failed to create device: {any}", .{err});
            continue;
        };
    }
}

pub const DeviceWatcher = struct {
    /// Netlink socket fd for subscribing to new device events.
    nl_fd: os.fd_t,

    /// Timer fd for determining when new events have "settled".
    settle_fd: os.fd_t,

    pub fn init() !@This() {
        try std.fs.makeDirAbsolute("/dev/disk"); // prepare disk alias directory

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        try scanAndCreateDevices(arena.allocator());

        var self = @This(){
            .nl_fd = try os.socket(
                linux.AF.NETLINK,
                linux.SOCK.RAW,
                linux.NETLINK.KOBJECT_UEVENT,
            ),
            .settle_fd = try os.timerfd_create(os.CLOCK.REALTIME, 0),
        };
        errdefer self.deinit();

        const nls = os.sockaddr.nl{
            .groups = 1, // KOBJECT_UEVENT groups bitmask must be 1
            .pid = @bitCast(os.system.getpid()),
        };
        try os.bind(self.nl_fd, @ptrCast(&nls), @sizeOf(os.sockaddr.nl));

        return self;
    }

    pub fn register(self: *@This(), epoll_fd: os.fd_t) !void {
        var device_event = os.linux.epoll_event{
            .data = .{ .fd = self.nl_fd },
            .events = os.linux.EPOLL.IN,
        };
        try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.nl_fd, &device_event);

        var timer_event = os.linux.epoll_event{
            .data = .{ .fd = self.settle_fd },
            .events = os.linux.EPOLL.IN | os.linux.EPOLL.ONESHOT,
        };
        try os.epoll_ctl(epoll_fd, os.linux.EPOLL.CTL_ADD, self.settle_fd, &timer_event);
    }

    pub fn start_settle_timer(self: *@This()) !void {
        const timerspec = os.linux.itimerspec{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 }, // oneshot
            .it_value = .{ .tv_sec = 2, .tv_nsec = 0 }, // consider settled after 2 seconds without any new events
        };
        try os.timerfd_settime(self.settle_fd, 0, &timerspec, null);
    }

    pub fn handle_new_event(self: *@This()) !void {
        std.debug.print("TODO: handle new device event\n", .{});

        // reset the timer
        try self.start_settle_timer();

        // TODO(jared): handle new event
    }

    pub fn deinit(self: *@This()) void {
        os.closeSocket(self.nl_fd);
        os.closeSocket(self.settle_fd);
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

    var kobject = try parseUeventKobjectContents(std.testing.allocator, content);
    defer kobject.uevent.deinit();
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

    var kobject = try parseUeventKobjectContents(std.testing.allocator, content);
    defer kobject.uevent.deinit();
    try std.testing.expectEqual(Action.remove, kobject.action);
    try std.testing.expectEqualStrings("/devices/platform/serial8250/tty/ttyS6", kobject.device_path);
    try std.testing.expectEqualStrings("3471", kobject.uevent.get("SEQNUM").?);
}
