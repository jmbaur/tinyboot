const std = @import("std");

const Device = @import("../device.zig");
const kexec = @import("./kexec.zig").kexec;

const BootLoader = @This();

pub const Entry = struct {
    /// Will be passed to underlying boot loader after a successful kexec load.
    context: *anyopaque,
    /// Path to the linux kernel image.
    linux: []const u8,
    /// Optional path to the initrd.
    initrd: ?[]const u8 = null,
    /// Optional kernel parameters.
    cmdline: ?[]const u8 = null,
};

allocator: std.mem.Allocator,

/// Whether the bootloader can autoboot.
autoboot: bool = true,

/// Flag indicating if the underlying bootloader has been probed or not.
probed: bool = false,

/// Flag indicating if a boot has been attempted on this bootloader. This means
/// load() was called at least once.
boot_attempted: bool = false,

/// The priority of the bootloader. The lowest priority bootloader will attempt
/// to be booted first.
priority: u8,

/// The device this bootloader will operate on.
device: Device,

/// Entries obtained from the underlying bootloader on the device. Obtained
/// after a probe().
entries: std.ArrayList(Entry),

/// The underlying bootloader.
inner: *anyopaque,

/// Operations that can be ran on the underlying bootloader.
vtable: *const struct {
    name: *const fn () []const u8,
    probe: *const fn (*anyopaque, *std.ArrayList(Entry), Device) anyerror!void,
    timeout: *const fn (*anyopaque) u8,
    entryLoaded: *const fn (*anyopaque, Entry) void,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
},

pub fn init(
    comptime T: type,
    allocator: std.mem.Allocator,
    device: Device,
    opts: struct {
        priority: u8,
        autoboot: bool,
    },
) !BootLoader {
    const inner = try allocator.create(T);

    inner.* = T.init();

    const wrapper = struct {
        pub fn deinit(ctx: *anyopaque, a: std.mem.Allocator) void {
            const self: *T = @ptrCast(@alignCast(ctx));
            defer a.destroy(self);

            self.deinit();
        }

        pub fn probe(
            ctx: *anyopaque,
            entries: *std.ArrayList(Entry),
            d: Device,
        ) !void {
            const self: *T = @ptrCast(@alignCast(ctx));

            try self.probe(entries, d);
        }

        pub fn entryLoaded(ctx: *anyopaque, entry: Entry) void {
            const self: *T = @ptrCast(@alignCast(ctx));

            self.entryLoaded(entry.context);
        }

        pub fn timeout(ctx: *anyopaque) u8 {
            const self: *T = @ptrCast(@alignCast(ctx));

            return self.timeout();
        }
    };

    return .{
        .autoboot = opts.autoboot,
        .priority = opts.priority,
        .device = device,
        .allocator = allocator,
        .entries = std.ArrayList(Entry).init(allocator),
        .inner = inner,
        .vtable = &.{
            .name = T.name,
            .probe = wrapper.probe,
            .timeout = wrapper.timeout,
            .entryLoaded = wrapper.entryLoaded,
            .deinit = wrapper.deinit,
        },
    };
}

pub fn deinit(self: *BootLoader) void {
    defer self.entries.deinit();

    self.vtable.deinit(self.inner, self.allocator);
}

pub fn name(self: *BootLoader) []const u8 {
    return self.vtable.name();
}

pub fn timeout(self: *BootLoader) !u8 {
    _ = try self.probe();

    return self.vtable.timeout(self.inner);
}

pub fn probe(self: *BootLoader) ![]const Entry {
    if (!self.probed) {
        std.log.debug("bootloader not yet probed on {}", .{self.device});
        try self.vtable.probe(self.inner, &self.entries, self.device);
        self.probed = true;
        std.log.debug("bootloader probed on {}", .{self.device});
    }

    return self.entries.items;
}

pub fn load(self: *BootLoader, entry: Entry) !void {
    self.boot_attempted = true;

    try kexec(self.allocator, entry.linux, entry.initrd, entry.cmdline);

    self.vtable.entryLoaded(self.inner, entry);
}
