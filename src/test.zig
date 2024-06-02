// all top-level files, populates @This() for below
pub const bls = @import("./boot/bls.zig");
pub const bootspec = @import("./bootspec.zig");
pub const device = @import("./device.zig");
pub const filesystem = @import("./disk/filesystem.zig");
pub const partition_table = @import("./disk/partition_table.zig");
pub const tboot_bless_boot = @import("./tboot-bless-boot.zig");
pub const tboot_bless_boot_generator = @import("./tboot-bless-boot-generator.zig");
pub const tboot_loader = @import("./tboot-loader.zig");

test {
    // recursively test all imported files
    @import("std").testing.refAllDeclsRecursive(@This());
}
