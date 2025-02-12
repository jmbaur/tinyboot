const std = @import("std");
const posix = std.posix;
const epoll_event = std.os.linux.epoll_event;

const Device = @import("./device.zig");
const kobject = @import("./kobject.zig");

const linux_headers = @import("linux_headers");

const DeviceWatcher = @This();

pub const Event = struct {
    action: kobject.Action,
    device: Device,
};

const Queue = std.DoublyLinkedList(Event);

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

arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),

block_dir: std.fs.Dir,
char_dir: std.fs.Dir,

/// Netlink socket fd for subscribing to new device events.
nl_fd: posix.fd_t,

/// An eventfd file descriptor used to indicate when new device events are
/// available on the device queue.
event: posix.fd_t,

mutex: std.Thread.Mutex = .{},
queue: Queue = .{},

pub fn init() !DeviceWatcher {
    var self = DeviceWatcher{
        .event = try posix.eventfd(0, 0),
        .block_dir = try std.fs.cwd().makeOpenPath("/dev/block", .{}),
        .char_dir = try std.fs.cwd().makeOpenPath("/dev/char", .{}),
        .nl_fd = try posix.socket(
            posix.system.AF.NETLINK,
            posix.system.SOCK.DGRAM,
            std.os.linux.NETLINK.KOBJECT_UEVENT,
        ),
    };

    try self.scanAndCreateExistingDevices();

    return self;
}

pub fn watch(self: *DeviceWatcher, done: posix.fd_t) !void {
    defer self.deinit();

    try posix.setsockopt(
        self.nl_fd,
        posix.SOL.SOCKET,
        posix.SO.RCVBUF,
        &std.mem.toBytes(@as(c_int, KERN_RCVBUF)),
    );

    try posix.setsockopt(
        self.nl_fd,
        posix.SOL.SOCKET,
        posix.SO.RCVBUFFORCE,
        &std.mem.toBytes(@as(c_int, KERN_RCVBUF)),
    );

    const nls = posix.sockaddr.nl{
        .groups = 1, // KOBJECT_UEVENT groups bitmask must be 1
        .pid = @bitCast(posix.system.getpid()),
    };
    try posix.bind(self.nl_fd, @ptrCast(&nls), @sizeOf(posix.sockaddr.nl));

    const epoll_fd = try posix.epoll_create1(linux_headers.EPOLL_CLOEXEC);
    defer posix.close(epoll_fd);

    var netlink_event = epoll_event{
        .data = .{ .fd = self.nl_fd },
        .events = std.os.linux.EPOLL.IN,
    };

    try posix.epoll_ctl(
        epoll_fd,
        std.os.linux.EPOLL.CTL_ADD,
        self.nl_fd,
        &netlink_event,
    );

    var done_event = epoll_event{
        .data = .{ .fd = done },
        .events = std.os.linux.EPOLL.IN,
    };

    try posix.epoll_ctl(
        epoll_fd,
        std.os.linux.EPOLL.CTL_ADD,
        done,
        &done_event,
    );

    while (true) {
        var events = [_]posix.system.epoll_event{undefined} ** (2 << 4);

        const n_events = posix.epoll_wait(epoll_fd, &events, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];

            if (event.data.fd == done) {
                std.log.debug("done watching devices", .{});
                return;
            } else if (event.data.fd == self.nl_fd) {
                self.handleNewEvent() catch |err| {
                    std.log.err("failed to handle new device: {}", .{err});
                };
            } else {
                std.debug.panic("unknown event: {}", .{event});
            }
        }
    }
}

fn handleNewEvent(self: *DeviceWatcher) !void {
    var recv_bytes: [USER_RCVBUF]u8 = undefined;

    const bytes_read = try posix.read(self.nl_fd, &recv_bytes);

    const event = kobject.parseUeventKobjectContents(
        recv_bytes[0..bytes_read],
    ) orelse return;

    switch (event.action) {
        .add => try self.addDevice(event),
        .remove => try self.removeDevice(event),
    }
}

pub fn nextEvent(self: *DeviceWatcher) ?Event {
    self.mutex.lock();
    defer self.mutex.unlock();

    const node = self.queue.pop() orelse return null;
    defer self.arena.allocator().destroy(node);

    return node.data;
}

pub fn deinit(self: *DeviceWatcher) void {
    defer self.arena.deinit();

    self.block_dir.close();
    self.char_dir.close();

    posix.close(self.nl_fd);
}

fn mknod(self: *DeviceWatcher, node_type: NodeType, major: u32, minor: u32) !void {
    var buf: [10]u8 = undefined;
    const device = try std.fmt.bufPrintZ(&buf, "{}:{}", .{ major, minor });

    const rc = std.os.linux.mknodat(
        switch (node_type) {
            .block => self.block_dir.fd,
            .char => self.char_dir.fd,
        },
        device,
        switch (node_type) {
            .block => posix.system.S.IFBLK,
            .char => posix.system.S.IFCHR,
        },
        makedev(major, minor),
    );

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .EXIST => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

// stat() on any uevent file always returns 4096
const UEVENT_FILE_SIZE = 4096;

/// Scan sysfs and create all nodes of interest that currently exist on the
/// system.
pub fn scanAndCreateExistingDevices(self: *DeviceWatcher) !void {
    inline for (std.meta.fields(Device.Subsystem)) |field| {
        try self.scanAndCreateExistingDevicesForSubsystem(field.name);
    }
}

pub fn scanAndCreateExistingDevicesForSubsystem(
    self: *DeviceWatcher,
    comptime subsystem: []const u8,
) !void {
    var subsystem_dir = std.fs.cwd().openDir(
        "/sys/class/" ++ subsystem,
        .{ .iterate = true },
    ) catch return; // don't hard fail if the subsystem does not exist
    defer subsystem_dir.close();

    var iter = subsystem_dir.iterate();

    while (try iter.next()) |entry| {
        // We expect all files in every directory under /sys/class to be a
        // symlink.
        if (entry.kind != .sym_link) {
            continue;
        }

        var device_dir = subsystem_dir.openDir(entry.name, .{}) catch continue;
        defer device_dir.close();

        var device_uevent = device_dir.openFile("uevent", .{}) catch continue;
        defer device_uevent.close();

        var buf: [UEVENT_FILE_SIZE]u8 = undefined;
        const n_read = device_uevent.readAll(&buf) catch continue;

        const device = kobject.parseUeventFileContents(
            @field(Device.Subsystem, subsystem),
            buf[0..n_read],
        ) orelse continue;

        try self.addDevice(.{ .action = .add, .device = device });
    }
}

fn addDevice(self: *DeviceWatcher, event: Event) !void {
    switch (event.device.type) {
        .node => |node| {
            const major, const minor = node;
            try self.mknod(switch (event.device.subsystem) {
                .block => .block,
                else => .char,
            }, major, minor);
        },
        else => {},
    }

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        const node = try self.arena.allocator().create(Queue.Node);
        node.* = .{ .data = event };

        self.queue.append(node);

        _ = try posix.write(self.event, std.mem.asBytes(&@as(u64, 1)));
    }
}

fn removeDevice(self: *DeviceWatcher, event: Event) !void {
    switch (event.device.type) {
        .node => |node| {
            const major, const minor = node;
            try self.removeNode(switch (event.device.subsystem) {
                .block => .block,
                else => .char,
            }, major, minor);
        },
        else => {},
    }

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        const node = try self.arena.allocator().create(Queue.Node);

        node.* = .{ .data = event };
        self.queue.append(node);

        _ = try posix.write(self.event, std.mem.asBytes(&@as(u64, 1)));
    }
}

fn removeNode(self: *DeviceWatcher, node_type: NodeType, major: u32, minor: u32) !void {
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
