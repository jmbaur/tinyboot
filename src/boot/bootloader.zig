const Device = @import("../device/device.zig");

const DiskBootLoader = @import("./disk.zig");

pub const ALL = .{DiskBootLoader};

const BootLoader = @This();

ptr: *anyopaque,
vtable: Vtable,

pub const Vtable = struct {};
