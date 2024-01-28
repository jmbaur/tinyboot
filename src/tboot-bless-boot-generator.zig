const std = @import("std");

const GeneratorError = error{
    MissingNormalDir,
    MissingEarlyDir,
    MissingLateDir,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();

    _ = args.next().?; // skip argv[0]
    const normal_dir = args.next() orelse return GeneratorError.MissingNormalDir;
    const early_dir = args.next() orelse return GeneratorError.MissingEarlyDir;
    const late_dir = args.next() orelse return GeneratorError.MissingLateDir;

    _ = normal_dir;
    _ = late_dir;

    var env_map = try std.process.getEnvMap(allocator);
    const in_initrd = b: {
        const env_value = env_map.get("SYSTEMD_IN_INITRD") orelse break :b false;
        break :b std.mem.eql(u8, env_value, "1");
    };

    if (in_initrd) {
        std.log.debug("skipping tboot-bless-boot-generator, running in the initrd", .{});
        return;
    }

    var kernel_cmdline_file = try std.fs.openFileAbsolute("/proc/cmdline", .{});
    defer kernel_cmdline_file.close();

    const kernel_cmdline = try kernel_cmdline_file.readToEndAlloc(allocator, 1024);

    if (std.mem.count(u8, kernel_cmdline, "tboot.bls-entry=") > 0) {
        const basic_target_path = try std.fs.path.join(
            allocator,
            &.{ early_dir, "basic.target.wants" },
        );

        std.fs.makeDirAbsolute(basic_target_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var basic_target_dir = try std.fs.openDirAbsolute(basic_target_path, .{});
        defer basic_target_dir.close();

        try basic_target_dir.symLink(
            "/etc/systemd/system/tboot-bless-boot.service",
            "tboot-bless-boot.service",
            .{},
        );
    }
}
