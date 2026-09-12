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
    writer: *std.Io.Writer,
) !void {
    switch (self.type) {
        .ifindex => |ifindex| try writer.print("ifindex {}", .{ifindex}),
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
    // The hardware RNG that seeds the next kernel's KASLR lives here.
    misc,
    mtd,
    net,
    rtc,
    tpm,
    tty,
    watchdog,

    pub fn fromStr(value: []const u8) !@This() {
        return utils.enumFromStr(@This(), value);
    }
};
