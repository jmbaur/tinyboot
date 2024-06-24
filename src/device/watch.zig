const std = @import("std");
const posix = std.posix;
const path = std.fs.path;
const system = posix.system;

const Device = @import("./device.zig");
const kobject = @import("./kobject.zig");

const linux_headers = @import("linux_headers");

fn makedev(major: u32, minor: u32) u32 {
    return std.math.shl(u32, major & 0xfffff000, 32) |
        std.math.shl(u32, major & 0x00000fff, 8) |
        std.math.shl(u32, minor & 0xffffff00, 12) |
        std.math.shl(u32, minor & 0x000000ff, 0);
}

const NodeType = enum { block, char };

// busybox uses these buffer sizes
const USER_RCVBUF = 3 * 1024;
const KERN_RCVBUF = 128 * 1024 * 1024;

block_dir: std.fs.Dir,
char_dir: std.fs.Dir,

/// Netlink socket fd for subscribing to new device events.
nl_fd: posix.fd_t,

pub fn init() !@This() {
    var self = @This(){
        .block_dir = try std.fs.cwd().makeOpenPath("/dev/block", .{}),
        .char_dir = try std.fs.cwd().makeOpenPath("/dev/char", .{}),
        .nl_fd = try posix.socket(
            system.AF.NETLINK,
            system.SOCK.DGRAM,
            system.NETLINK.KOBJECT_UEVENT,
        ),
    };
    errdefer self.deinit();

    try self.makeInitialNodes(.block);
    try self.makeInitialNodes(.char);

    return self;
}

// Does not exit until end of program
pub fn watch(self: *@This(), new_device_notify: posix.fd_t, done: posix.fd_t) !void {
    defer Device.arena.deinit();

    defer self.deinit();

    try posix.setsockopt(self.nl_fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, KERN_RCVBUF)));
    try posix.setsockopt(self.nl_fd, posix.SOL.SOCKET, posix.SO.RCVBUFFORCE, &std.mem.toBytes(@as(c_int, KERN_RCVBUF)));

    const nls = posix.sockaddr.nl{
        .groups = 1, // KOBJECT_UEVENT groups bitmask must be 1
        .pid = @bitCast(system.getpid()),
    };
    try posix.bind(self.nl_fd, @ptrCast(&nls), @sizeOf(posix.sockaddr.nl));

    const epoll_fd = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC);
    defer posix.close(epoll_fd);

    try posix.epoll_ctl(epoll_fd, system.EPOLL.CTL_ADD, self.nl_fd, @constCast(&.{
        .data = .{ .fd = self.nl_fd },
        .events = system.EPOLL.IN,
    }));

    try posix.epoll_ctl(epoll_fd, system.EPOLL.CTL_ADD, done, @constCast(&.{
        .data = .{ .fd = done },
        .events = system.EPOLL.IN | system.EPOLL.ONESHOT,
    }));

    std.log.debug("watching devices", .{});

    while (true) {
        const max_events = 8;
        var events = [_]system.epoll_event{undefined} ** max_events;

        const n_events = posix.epoll_wait(epoll_fd, &events, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];
            if (event.data.fd == done) {
                std.log.debug("done watching devices", .{});
                break;
            } else if (event.data.fd == self.nl_fd) {
                _ = try posix.write(new_device_notify, std.mem.asBytes(&1));
                self.handleNewEvent() catch |err| {
                    std.log.err("failed to handle new device: {}", .{err});
                };
            }
        }
    }
}

fn handleNewEvent(self: *@This()) !void {
    var recv_bytes: [USER_RCVBUF]u8 = undefined;

    const bytes_read = try posix.read(self.nl_fd, &recv_bytes);

    const kobj = try kobject.parseUeventKobjectContents(
        recv_bytes[0..bytes_read],
    ) orelse return;

    if (kobj.action == .add) {
        try self.addDevice(kobj.device);
    } else {
        if (kobj.action == .remove) {
            try self.removeDevice(kobj.device);
        }
    }
}

fn deinit(self: *@This()) void {
    self.block_dir.close();
    self.char_dir.close();
    posix.close(self.nl_fd);
}

fn mknod(self: *@This(), node_type: NodeType, major: u32, minor: u32) !void {
    var buf: [10]u8 = undefined;
    const device = try std.fmt.bufPrintZ(&buf, "{}:{}", .{ major, minor });

    const rc = system.mknodat(
        switch (node_type) {
            .block => self.block_dir.fd,
            .char => self.char_dir.fd,
        },
        device,
        switch (node_type) {
            .block => system.S.IFBLK,
            .char => system.S.IFCHR,
        },
        makedev(major, minor),
    );

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .EXIST => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Scan sysfs and create all nodes that currently exist on the system.
fn makeInitialNodes(self: *@This(), node_type: NodeType) !void {
    var dir = try std.fs.cwd().openDir(switch (node_type) {
        .block => "/sys/dev/block",
        .char => "/sys/dev/char",
    }, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        // we expect all entries to be a symlink
        if (entry.kind != .sym_link) {
            continue;
        }

        var split = std.mem.split(u8, entry.name, ":");

        const major = std.fmt.parseInt(u32, split.next() orelse continue, 10) catch continue;
        const minor = std.fmt.parseInt(u32, split.next() orelse continue, 10) catch continue;

        // // add device
        // var buf: [posix.PATH_MAX]u8 = undefined;
        // const device = dir.realpath(entry.name, &buf) catch continue;
        // try DEVICES.append(Device.init(device));

        try self.mknod(node_type, major, minor);
    }
}

fn addDevice(self: *@This(), device: *Device) !void {
    if (device.node) |node| {
        const major, const minor = node;
        try self.mknod(switch (device.subsystem) {
            .block => .block,
            else => .char,
        }, major, minor);
    }

    try Device.add(device);
}

fn removeDevice(self: *@This(), device: *Device) !void {
    defer device.deinit();

    if (device.node) |node| {
        const major, const minor = node;
        try self.removeNode(switch (device.subsystem) {
            .block => .block,
            else => .char,
        }, major, minor);
    }

    try Device.remove(device.dev_name);
}

fn removeNode(self: *@This(), node_type: NodeType, major: u32, minor: u32) !void {
    var buf: [10]u8 = undefined;
    const device = try std.fmt.bufPrint(&buf, "{}:{}", .{ major, minor });

    var dir = switch (node_type) {
        .block => self.block_dir,
        .char => self.char_dir,
    };

    dir.deleteFile(device) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "device mode" {
    try std.testing.expectEqual(NodeType.char, NodeType.fromStr("foo"));
    try std.testing.expectEqual(NodeType.char, NodeType.fromStr("disk"));
    try std.testing.expectEqual(NodeType.block, NodeType.fromStr("partition"));
}
