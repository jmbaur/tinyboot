const std = @import("std");

const utils = @import("./utils.zig");

const Device = @This();

subsystem: Subsystem,
type: union(enum) {
    ifindex: u32,
    node: struct { u32, u32 },
},

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

// pub const DriverType = union(enum) { bootloader: BootLoader };

// pub var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
// const arena_allocator = arena.allocator();

// var mutex = std.Thread.Mutex{};
// var ALL_DEVICES = std.ArrayList(*Device).init(arena_allocator);

// pub fn forEach(ctx: *anyopaque, callback: *const fn (ctx: *anyopaque, *const Device) utils.IterResult) void {
//     mutex.lock();
//     defer mutex.unlock();
//
//     for (ALL_DEVICES.items) |device| {
//         switch (callback(ctx, device)) {
//             .@"break" => break,
//             .@"continue" => continue,
//         }
//     }
// }

// const ALL_DRIVERS = .{DiskBootLoader};
//
// /// Adds a preinitialized device to the device list.
// pub fn add(device: *Device) !void {
//     inline for (ALL_DRIVERS) |driver| {
//         var driver_instance = driver.driver();
//         if (driver_instance.match(device)) {
//             device.driver = driver_instance;
//             break;
//         }
//     }
//
//     mutex.lock();
//     defer mutex.unlock();
//
//     try ALL_DEVICES.append(device);
// }
//
// /// Removes the device from the device list and deinitializes the device
// /// structure.
// pub fn remove(device: *Device) void {
//     mutex.lock();
//     defer mutex.unlock();
//
//     for (ALL_DEVICES.items, 0..) |d, index| {
//         if (d == device) {
//             const removed = ALL_DEVICES.orderedRemove(index);
//             return removed.deinit();
//         }
//     }
// }
//
// /// Deinitializes all devices. Should only _ever_ be called once at the end of
// /// the program.
// pub fn removeAll() void {
//     mutex.lock();
//     defer mutex.unlock();
//
//     for (ALL_DEVICES.items, 0..) |_, index| {
//         const removed = ALL_DEVICES.orderedRemove(index);
//         removed.deinit();
//     }
// }
//
// pub fn findByNumber(want_major: u32, want_minor: u32) ?*Device {
//     mutex.lock();
//     defer mutex.unlock();
//
//     for (ALL_DEVICES.items) |d| {
//         if (d.node) |node| {
//             const major, const minor = node;
//             if (major == want_major and minor == want_minor) {
//                 return d;
//             }
//         }
//     }
//
//     return null;
// }
//
// pub fn findByName(want_name: []const u8) ?*Device {
//     mutex.lock();
//     defer mutex.unlock();
//
//     for (ALL_DEVICES.items) |d| {
//         if (std.mem.eql(u8, d.dev_name, want_name)) {
//             return d;
//         }
//     }
//
//     return null;
// }
