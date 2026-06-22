const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const epoll_event = linux.epoll_event;

const Device = @import("./device.zig");
const kobject = @import("./kobject.zig");

const DeviceWatcher = @This();

pub const Event = struct {
    action: kobject.Action,
    device: Device,
};

pub const EventNode = struct {
    event: Event,
    inner: std.DoublyLinkedList.Node = .{},
};

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

block_dir: std.Io.Dir,
char_dir: std.Io.Dir,

/// An epoll file descriptor for receiving events on other file descriptors for
/// the watcher.
epoll: posix.fd_t,

/// Netlink socket fd for subscribing to new device events.
nl: posix.fd_t,

/// An eventfd file descriptor used to indicate when new device events are
/// available on the device queue.
event: posix.fd_t,

mutex: std.Io.Mutex = .init,
queue: std.DoublyLinkedList = .{},

pub fn init(io: std.Io) !DeviceWatcher {
    var self = DeviceWatcher{
        .event = @intCast(linux.eventfd(0, 0)),
        .block_dir = try std.Io.Dir.cwd().createDirPathOpen(io, "/dev/block", .{}),
        .char_dir = try std.Io.Dir.cwd().createDirPathOpen(io, "/dev/char", .{}),
        .epoll = @intCast(linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC)),
        .nl = @intCast(linux.socket(
            linux.AF.NETLINK,
            linux.SOCK.DGRAM,
            linux.NETLINK.KOBJECT_UEVENT,
        )),
    };

    try posix.setsockopt(
        self.nl,
        posix.SOL.SOCKET,
        posix.SO.RCVBUF,
        &std.mem.toBytes(@as(c_int, KERN_RCVBUF)),
    );

    try posix.setsockopt(
        self.nl,
        posix.SOL.SOCKET,
        posix.SO.RCVBUFFORCE,
        &std.mem.toBytes(@as(c_int, KERN_RCVBUF)),
    );

    const nls = posix.sockaddr.nl{
        .groups = 1, // KOBJECT_UEVENT groups bitmask must be 1
        .pid = @bitCast(posix.system.getpid()),
    };
    _ = linux.bind(self.nl, @ptrCast(&nls), @sizeOf(posix.sockaddr.nl));

    var netlink_event = epoll_event{
        .data = .{ .fd = self.nl },
        .events = std.os.linux.EPOLL.IN,
    };

    _ = linux.epoll_ctl(
        self.epoll,
        std.os.linux.EPOLL.CTL_ADD,
        self.nl,
        &netlink_event,
    );

    try self.scanAndCreateExistingDevices(io);

    return self;
}

pub fn watch(self: *DeviceWatcher, io: std.Io, done: posix.fd_t) !void {
    defer self.deinit(io);

    var done_event = epoll_event{
        .data = .{ .fd = done },
        .events = std.os.linux.EPOLL.IN,
    };

    _ = linux.epoll_ctl(
        self.epoll,
        std.os.linux.EPOLL.CTL_ADD,
        done,
        &done_event,
    );

    while (true) {
        var events = [_]linux.epoll_event{undefined} ** (2 << 4);

        const n_events = linux.epoll_wait(self.epoll, &events, events.len, -1);

        var i_event: usize = 0;
        while (i_event < n_events) : (i_event += 1) {
            const event = events[i_event];

            if (event.data.fd == done) {
                std.log.debug("done watching devices", .{});
                return;
            } else if (event.data.fd == self.nl) {
                self.handleNewEvent(io) catch |err| {
                    std.log.err("failed to handle new device: {}", .{err});
                };
            } else {
                std.debug.panic("unknown event: {}", .{event});
            }
        }
    }
}

fn handleNewEvent(self: *DeviceWatcher, io: std.Io) !void {
    var recv_bytes: [USER_RCVBUF]u8 = undefined;

    const bytes_read = try posix.read(self.nl, &recv_bytes);

    const event = kobject.parseUeventKobjectContents(
        recv_bytes[0..bytes_read],
    ) orelse return;

    switch (event.action) {
        .add => try self.addDevice(io, event),
        .remove => try self.removeDevice(io, event),
    }
}

pub fn nextEvent(self: *DeviceWatcher, io: std.Io) !?Event {
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);

    const node = self.queue.pop() orelse return null;
    const event_node: *EventNode = @fieldParentPtr("inner", node);
    defer self.arena.allocator().destroy(event_node);

    return event_node.event;
}

pub fn deinit(self: *DeviceWatcher, io: std.Io) void {
    defer self.arena.deinit();

    self.block_dir.close(io);
    self.char_dir.close(io);

    _ = linux.close(self.nl);
    _ = linux.close(self.event);
    _ = linux.close(self.epoll);
}

fn mknod(self: *DeviceWatcher, node_type: NodeType, major: u32, minor: u32) !void {
    var buf: [10]u8 = undefined;
    const device = try std.fmt.bufPrintZ(&buf, "{}:{}", .{ major, minor });

    const rc = std.os.linux.mknodat(
        switch (node_type) {
            .block => self.block_dir.handle,
            .char => self.char_dir.handle,
        },
        device,
        switch (node_type) {
            .block => posix.system.S.IFBLK,
            .char => posix.system.S.IFCHR,
        },
        makedev(major, minor),
    );

    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .EXIST => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

// stat() on any uevent file always returns 4096
const UEVENT_FILE_SIZE = 4096;

/// Scan sysfs and create all nodes of interest that currently exist on the
/// system.
pub fn scanAndCreateExistingDevices(self: *DeviceWatcher, io: std.Io) !void {
    inline for (std.meta.fields(Device.Subsystem)) |field| {
        try self.scanAndCreateExistingDevicesForSubsystem(io, field.name);
    }
}

pub fn scanAndCreateExistingDevicesForSubsystem(
    self: *DeviceWatcher,
    io: std.Io,
    comptime subsystem: []const u8,
) !void {
    var subsystem_dir = std.Io.Dir.cwd().openDir(
        io,
        "/sys/class/" ++ subsystem,
        .{ .iterate = true },
    ) catch return; // don't hard fail if the subsystem does not exist
    defer subsystem_dir.close(io);

    var iter = subsystem_dir.iterate();

    while (try iter.next(io)) |entry| {
        // We expect all files in every directory under /sys/class to be a
        // symlink.
        if (entry.kind != .sym_link) {
            continue;
        }

        var device_dir = subsystem_dir.openDir(io, entry.name, .{}) catch continue;
        defer device_dir.close(io);

        var device_uevent = device_dir.openFile(io, "uevent", .{}) catch continue;
        defer device_uevent.close(io);

        var buf: [UEVENT_FILE_SIZE]u8 = undefined;
        var reader = device_uevent.reader(io, &.{});
        const n_read = reader.interface.readSliceShort(&buf) catch continue;

        const device = kobject.parseUeventFileContents(
            @field(Device.Subsystem, subsystem),
            buf[0..n_read],
        ) orelse continue;

        try self.addDevice(io, .{ .action = .add, .device = device });
    }
}

fn addDevice(self: *DeviceWatcher, io: std.Io, event: Event) !void {
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
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const node = try self.arena.allocator().create(EventNode);
        node.* = .{ .event = event };

        self.queue.append(&node.inner);

        _ = linux.write(self.event, std.mem.asBytes(&@as(u64, 1)), @sizeOf(u64));
    }
}

fn removeDevice(self: *DeviceWatcher, io: std.Io, event: Event) !void {
    switch (event.device.type) {
        .node => |node| {
            const major, const minor = node;
            try self.removeNode(io, switch (event.device.subsystem) {
                .block => .block,
                else => .char,
            }, major, minor);
        },
        else => {},
    }

    {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const node = try self.arena.allocator().create(EventNode);

        node.* = .{ .event = event };
        self.queue.append(&node.inner);

        _ = linux.write(self.event, std.mem.asBytes(&@as(u64, 1)), @sizeOf(u64));
    }
}

fn removeNode(self: *DeviceWatcher, io: std.Io, node_type: NodeType, major: u32, minor: u32) !void {
    var buf: [10]u8 = undefined;
    const device = try std.fmt.bufPrint(&buf, "{}:{}", .{ major, minor });

    var dir = switch (node_type) {
        .block => self.block_dir,
        .char => self.char_dir,
    };

    dir.deleteFile(io, device) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
