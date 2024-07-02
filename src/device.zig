const std = @import("std");

const utils = @import("./utils.zig");

const Device = @This();

subsystem: Subsystem,
type: union(enum) {
    ifindex: u32,
    node: struct { u32, u32 },
},

pub fn nodePath(device: *const Device, buf: []u8) ![]u8 {
    std.debug.assert(device.type == .node);

    const major, const minor = device.type.node;

    return try std.fmt.bufPrint(buf, "/dev/{s}/{d}:{d}", .{
        switch (device.subsystem) {
            .block => "block",
            else => "char",
        },
        major,
        minor,
    });
}

pub fn nodePathZ(device: *const Device, buf: []u8) ![:0]const u8 {
    std.debug.assert(device.type == .node);

    const major, const minor = device.type.node;

    return try std.fmt.bufPrintZ(buf, "/dev/{s}/{d}:{d}", .{
        switch (device.subsystem) {
            .block => "block",
            else => "char",
        },
        major,
        minor,
    });
}

pub fn nodeSysfsPath(device: *const Device, buf: []u8) ![]u8 {
    std.debug.assert(device.type == .node);

    const major, const minor = device.type.node;

    return try std.fmt.bufPrint(buf, "/sys/dev/{s}/{d}:{d}", .{
        switch (device.subsystem) {
            .block => "block",
            else => "char",
        },
        major,
        minor,
    });
}

pub fn format(
    self: Device,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;

    switch (self.type) {
        .ifindex => |ifindex| try writer.print("{s} {}", .{ "ifindex", ifindex }),
        .node => |node| {
            const major, const minor = node;
            try writer.print("node {}:{}", .{ major, minor });
        },
    }
}

// ls -1 /sys/class
//
/// Subsystems we care about when acting as a bootloader.
pub const Subsystem = enum {
    block,
    mem,
    mtd,
    net,
    rtc,
    tty,
    watchdog,

    pub fn fromStr(value: []const u8) !@This() {
        return utils.enumFromStr(@This(), value);
    }
};

// grep --no-filename DEVTYPE /sys/class/*/*/uevent  | cut -d'=' -f2 | sort | uniq
//
/// Device types we care about when acting as a bootloader.
pub const DevType = enum {
    disk,
    mtd,
    partition,

    pub fn fromStr(value: []const u8) !@This() {
        return utils.enumFromStr(@This(), value);
    }
};
