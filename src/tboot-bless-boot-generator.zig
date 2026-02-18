const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const LiveUpdate = @import("./liveupdate.zig");

pub const std_options = std.Options{ .log_level = if (builtin.mode == .Debug) .debug else .info };

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help and exit.
        \\<DIR>         The normal generator directory.
        \\<DIR>         The early generator directory.
        \\<DIR>         The late generator directory.
        \\
    );

    const parsers = comptime .{ .DIR = clap.parsers.string };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(.stderr(), clap.Help, &params, .{});
    }

    if (res.positionals[0] == null or
        res.positionals[1] == null or
        res.positionals[2] == null)
    {
        try diag.reportToFile(.stderr(), error.InvalidArgument);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    }

    const normal_dir = res.positionals[0].?;
    const early_dir = res.positionals[1].?;
    const late_dir = res.positionals[2].?;

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

    if (std.fs.cwd().access(LiveUpdate.liveupdate_chardev, .{})) {} else |_| {
        return;
    }

    const basic_target_path = try std.fs.path.join(
        allocator,
        &.{ early_dir, "basic.target.wants" },
    );

    std.fs.cwd().makeDir(basic_target_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var basic_target_dir = try std.fs.cwd().openDir(basic_target_path, .{});
    defer basic_target_dir.close();

    try basic_target_dir.symLink(
        "/etc/systemd/system/tboot-bless-boot.service",
        "tboot-bless-boot.service",
        .{},
    );
}
