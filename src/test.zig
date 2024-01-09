// all top-level files, populates @This() for below
pub const tboot_bless_boot = @import("./tboot-bless-boot.zig");
pub const tboot_bless_boot_generator = @import("./tboot-bless-boot-generator.zig");
pub const tboot_loader = @import("./tboot-loader.zig");
pub const tboot_nixos_install = @import("./tboot-nixos-install.zig");

// TODO(jared): remove this when imported elsewhere
pub const gpt = @import("./disk/gpt.zig");

test {
    // recursively test all imported files
    @import("std").testing.refAllDeclsRecursive(@This());
}
