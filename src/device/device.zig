const std = @import("std");

const utils = @import("../utils.zig");

const BootLoader = @import("../boot/bootloader.zig");
const DiskBootLoader = @import("../boot/disk.zig");

const Device = @This();

pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const arena_allocator = arena.allocator();

var mutex = std.Thread.Mutex{};
var ALL_DEVICES = std.ArrayList(*Device).init(arena_allocator);

pub fn forEach(callback: *const fn (*const Device) void) void {
    mutex.lock();
    defer mutex.unlock();

    for (ALL_DEVICES.items) |device| {
        callback(device);
    }
}

const ALL_DRIVERS = .{DiskBootLoader};

/// Adds a preinitialized device to the device list.
pub fn add(device: *Device) !void {
    inline for (ALL_DRIVERS) |driver| {
        if (driver.match(device)) {
            device.driver = try Driver.init(driver);
        }
    }

    mutex.lock();
    defer mutex.unlock();

    try ALL_DEVICES.append(device);
}

/// Removes the device from the device list and deinitializes the device
/// structure.
pub fn remove(device: *Device) void {
    mutex.lock();
    defer mutex.unlock();

    for (ALL_DEVICES.items, 0..) |d, index| {
        if (d == device) {
            const removed = ALL_DEVICES.orderedRemove(index);
            removed.deinit();
        }
    }
}

pub fn findByNumber(want_major: u32, want_minor: u32) ?*Device {
    mutex.lock();
    defer mutex.unlock();

    for (ALL_DEVICES.items) |d| {
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
    mutex.lock();
    defer mutex.unlock();

    for (ALL_DEVICES.items) |d| {
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

pub const Driver = struct {
    ptr: *anyopaque,
    driver_type: enum { bootloader },
    vtable: *const struct {
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    },

    fn init(driver: anytype) !@This() {
        return .{
            .ptr = try driver.init(arena_allocator),
            .driver_type = driver.driver_type,
            .vtable = &.{
                .deinit = driver.deinit,
            },
        };
    }

    fn deinit(self: *@This()) void {
        self.vtable.deinit(self.ptr, arena_allocator);
    }
};

mutex: std.Thread.Mutex = .{},
driver: ?Driver = null,
subsystem: Subsystem,
dev_type: ?DevType = null,
node: ?struct { u32, u32 } = null,
dev_path: []const u8,
dev_name: []const u8,

pub fn init(
    subsystem: Subsystem,
    dev_path: []const u8,
    dev_name: []const u8,
) !*Device {
    const self = try arena_allocator.create(Device);
    self.* = .{
        .subsystem = subsystem,
        .dev_path = try arena_allocator.dupe(u8, dev_path),
        .dev_name = try arena_allocator.dupe(u8, dev_name),
    };
    return self;
}

pub fn deinit(self: *Device) void {
    arena_allocator.free(self.dev_path);
    arena_allocator.free(self.dev_name);
    arena_allocator.destroy(self);
    if (self.driver) |*driver| {
        driver.deinit();
    }
    self.* = undefined;
}
