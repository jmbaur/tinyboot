// all non-entrypoint files, populates @This() for below
pub const boot = @import("./boot.zig");
pub const bootspec = @import("./bootspec.zig");
pub const client = @import("./console.zig");
pub const device = @import("./device.zig");
pub const filesystem = @import("./disk/filesystem.zig");
pub const kobject = @import("./kobject.zig");
pub const log = @import("./log.zig");
pub const partition_table = @import("./disk/partition_table.zig");
pub const system = @import("./system.zig");
pub const tmp = @import("./tmpdir.zig");
pub const xmodem = @import("./boot/xmodem.zig");

test {
    // recursively test all imported files
    @import("std").testing.refAllDeclsRecursive(@This());
}
