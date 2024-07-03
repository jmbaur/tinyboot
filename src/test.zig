test {
    _ = @import("./autoboot.zig");
    _ = @import("./boot/bootloader.zig");
    _ = @import("./boot/disk.zig");
    _ = @import("./boot/xmodem.zig");
    _ = @import("./bootspec.zig");
    _ = @import("./console.zig");
    _ = @import("./cpio/main.zig");
    _ = @import("./device.zig");
    _ = @import("./disk/filesystem.zig");
    _ = @import("./disk/partition_table.zig");
    _ = @import("./kobject.zig");
    _ = @import("./log.zig");
    _ = @import("./runner.zig");
    _ = @import("./security.zig");
    _ = @import("./system.zig");
    _ = @import("./tboot-bless-boot-generator.zig");
    _ = @import("./tboot-bless-boot.zig");
    _ = @import("./tboot-loader.zig");
    _ = @import("./tboot-nixos-install.zig");
    _ = @import("./tboot-sign.zig");
    _ = @import("./test.zig");
    _ = @import("./tmpdir.zig");
    _ = @import("./utils.zig");
    _ = @import("./watch.zig");
    _ = @import("./xmodem.zig");
}
