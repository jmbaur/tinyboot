const std = @import("std");

const Device = @import("../device/device.zig");

const DiskBootLoader = @import("./disk.zig");

pub const ALL = .{DiskBootLoader};

const BootLoader = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
};

pub fn deinit(self: BootLoader, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
    // self.vtable.deinit(self.ptr);
    // allocator.destroy(self.ptr);
}
