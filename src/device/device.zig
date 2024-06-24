const std = @import("std");

const utils = @import("../utils.zig");

pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

var m = std.Thread.Mutex{};
var all_devices = std.ArrayList(*@This()).init(arena.allocator());

pub fn add(device: *@This()) !void {
    m.lock();
    defer m.unlock();

    try all_devices.append(device);
}

pub fn remove(dev_name: []const u8) !void {
    m.lock();
    defer m.unlock();

    for (all_devices.items, 0..) |d, index| {
        if (std.mem.eql(u8, d.dev_name, dev_name)) {
            const removed = all_devices.orderedRemove(index);
            removed.deinit();
        }
    }
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
dev_name: []const u8,

pub fn init(subsystem: Subsystem, dev_name: []const u8) !*@This() {
    const self = try arena.allocator().create(@This());
    self.* = .{
        .subsystem = subsystem,
        .dev_name = try arena.allocator().dupe(u8, dev_name),
    };
    return self;
}

pub fn deinit(self: *@This()) void {
    arena.allocator().free(self.dev_name);
    arena.allocator().destroy(self);
    self.* = undefined;
}
