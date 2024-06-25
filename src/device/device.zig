const std = @import("std");

const utils = @import("../utils.zig");

const Device = @This();

pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var m = std.Thread.Mutex{};
var all_devices = std.ArrayList(*Device).init(arena.allocator());

/// Adds a preinitialized device to the device list.
pub fn add(device: *Device) !void {
    m.lock();
    defer m.unlock();

    try all_devices.append(device);
}

/// Removes the device from the device list and deinitializes the device
/// structure.
pub fn remove(device: *Device) void {
    m.lock();
    defer m.unlock();

    for (all_devices.items, 0..) |d, index| {
        if (d == device) {
            const removed = all_devices.orderedRemove(index);
            removed.deinit();
        }
    }
}

pub fn findByNumber(want_major: u32, want_minor: u32) ?*Device {
    m.lock();
    defer m.unlock();

    for (all_devices.items) |d| {
        if (d.node) |node| {
            const major, const minor = node;
            if (major == want_major and minor == want_minor) {
                return d;
            }
        }
    }

    return null;
}

pub fn findByName(want_name: []const u8) ?*Device {
    m.lock();
    defer m.unlock();

    for (all_devices.items) |d| {
        if (std.mem.eql(u8, d.dev_name, want_name)) {
            return d;
        }
    }

    return null;
}

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

// ls -1 /sys/class
//
/// Subsystems we care about when acting as a bootloader.
pub const Subsystem = enum {
    block,
    mtd,
    net,
    rtc,
    tty,
    watchdog,

    pub fn fromStr(value: []const u8) !@This() {
        return utils.enumFromStr(@This(), value);
    }
};

subsystem: Subsystem,
dev_type: ?DevType = null,
node: ?struct { u32, u32 } = null,
dev_path: []const u8,
dev_name: []const u8,

pub fn init(subsystem: Subsystem, dev_path: []const u8, dev_name: []const u8) !*Device {
    const self = try arena.allocator().create(Device);
    self.* = .{
        .subsystem = subsystem,
        .dev_path = try arena.allocator().dupe(u8, dev_path),
        .dev_name = try arena.allocator().dupe(u8, dev_name),
    };
    return self;
}

pub fn deinit(self: *Device) void {
    arena.allocator().free(self.dev_path);
    arena.allocator().free(self.dev_name);
    arena.allocator().destroy(self);
    self.* = undefined;
}
