// all non-entrypoint files, populates @This() for below
pub const bls = @import("./boot/bls.zig");
pub const boot = @import("./boot.zig");
pub const bootspec = @import("./bootspec.zig");
pub const client = @import("./client.zig");
pub const device = @import("./device.zig");
pub const filesystem = @import("./disk/filesystem.zig");
pub const log = @import("./log.zig");
pub const message = @import("./message.zig");
pub const partition_table = @import("./disk/partition_table.zig");
pub const server = @import("./server.zig");
pub const system = @import("./system.zig");
pub const tmp = @import("./tmp.zig");
pub const xmodem = @import("./boot/xmodem.zig");

test {
    // recursively test all imported files
    @import("std").testing.refAllDeclsRecursive(@This());
}
