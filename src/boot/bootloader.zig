const std = @import("std");

const Device = @import("../device/device.zig");

const BootLoader = @This();

probe: *const fn (ctx: *anyopaque, device: *const Device) anyerror!void,

pub fn new(
    comptime T: type,
    comptime vtable: struct {
        probe: *const fn (self: *T, device: *const Device) anyerror!void,
    },
) Device.DriverType {
    const wrapper = struct {
        pub fn probe(ctx: *anyopaque, device: *const Device) !void {
            const ptr: *T = @ptrCast(@alignCast(ctx));
            try vtable.probe(ptr, device);
        }
    };

    return .{
        .bootloader = .{
            .probe = wrapper.probe,
        },
    };
}
