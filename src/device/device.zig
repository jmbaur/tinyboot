const std = @import("std");

const utils = @import("../utils.zig");

const BootLoader = @import("../boot/bootloader.zig");
const DiskBootLoader = @import("../boot/disk.zig");

const Device = @This();

pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const arena_allocator = arena.allocator();

var mutex = std.Thread.Mutex{};
var ALL_DEVICES = std.ArrayList(*Device).init(arena_allocator);

pub fn forEach(ctx: *anyopaque, callback: *const fn (ctx: *anyopaque, *const Device) utils.IterResult) void {
    mutex.lock();
    defer mutex.unlock();

    for (ALL_DEVICES.items) |device| {
        switch (callback(ctx, device)) {
            .@"break" => break,
            .@"continue" => continue,
        }
    }
}

const ALL_DRIVERS = .{DiskBootLoader};

/// Adds a preinitialized device to the device list.
pub fn add(device: *Device) !void {
    inline for (ALL_DRIVERS) |driver| {
        var driver_instance = driver.driver();
        if (driver_instance.match(device)) {
            device.driver = driver_instance;
            break;
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
            return removed.deinit();
        }
    }
}

/// Deinitializes all devices. Should only _ever_ be called once at the end of
/// the program.
pub fn removeAll() void {
    mutex.lock();
    defer mutex.unlock();

    for (ALL_DEVICES.items, 0..) |_, index| {
        const removed = ALL_DEVICES.orderedRemove(index);
        removed.deinit();
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

pub const DriverType = union(enum) { bootloader: BootLoader };

pub const Driver = struct {
    /// Opaque pointer is null when unitialized
    ptr: ?*anyopaque = null,

    mutex: std.Thread.Mutex = .{},

    driver_type: DriverType,

    vtable: *const struct {
        match: *const fn (device: *const Device) bool,
        init: *const fn () anyerror!*anyopaque,
        deinit: *const fn (ctx: *anyopaque) void,
    },

    pub fn new(
        comptime T: type,
        comptime driver_type: DriverType,
        comptime vtable: struct {
            match: *const fn (device: *const Device) bool,
            init: *const fn (self: *T) anyerror!void,
            deinit: *const fn (self: *T) void,
        },
    ) Driver {
        const wrapper = struct {
            pub fn init() !*anyopaque {
                const ptr = try arena_allocator.create(T);
                try vtable.init(ptr);
                return ptr;
            }

            pub fn deinit(ctx: *anyopaque) void {
                const ptr: *T = @ptrCast(@alignCast(ctx));
                defer arena_allocator.destroy(ptr);
                vtable.deinit(ptr);
            }
        };

        return .{
            .driver_type = driver_type,
            .vtable = &.{
                .match = vtable.match,
                .init = wrapper.init,
                .deinit = wrapper.deinit,
            },
        };
    }

    pub fn match(self: *const @This(), device: *const Device) bool {
        return self.vtable.match(device);
    }

    pub fn init(self: *@This()) !void {
        if (self.ptr == null) {
            self.ptr = try self.vtable.init();
        }
    }

    pub fn deinit(self: *@This()) void {
        if (self.ptr) |ptr| {
            self.vtable.deinit(ptr);
        }
    }
};

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

    if (self.driver) |*driver| {
        driver.mutex.lock();
        defer driver.mutex.unlock();
        driver.deinit();
    }

    arena_allocator.destroy(self);

    self.* = undefined;
}
