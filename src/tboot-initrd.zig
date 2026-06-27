const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const zstd = @import("zstd");
const CpioArchive = @import("./cpio.zig");

pub const std_options = std.Options{ .log_level = if (builtin.mode == .Debug) .debug else .info };

const BoolArgument = enum {
    yes,
    no,
    true,
    false,

    pub fn to_bool(self: @This()) bool {
        return switch (self) {
            .yes, .true => true,
            else => false,
        };
    }
};

fn compress(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    output: []const u8,
    archive_file: std.Io.File,
) !void {
    var file_reader = archive_file.reader(io, &.{});
    try file_reader.seekTo(0);

    const archive_file_buf = try file_reader.interface.allocRemaining(arena.allocator(), .unlimited);
    const compressed = try zstd.compress(arena.allocator(), archive_file_buf);
    defer compressed.deinit();

    const compressed_output = try std.fmt.allocPrint(
        arena.allocator(),
        "{s}.tmp",
        .{output},
    );

    var compressed_file = try std.Io.Dir.cwd().createFile(io, compressed_output, .{ .permissions = .fromMode(0o444) });
    defer compressed_file.close(io);

    var buf: [1024]u8 = undefined;
    var writer = compressed_file.writer(io, &buf);
    try writer.interface.writeAll(compressed.content());

    try std.Io.Dir.cwd().rename(compressed_output, std.Io.Dir.cwd(), output, io);
}

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit.
        \\-c, --compress <BOOL>         Specify whether archive should be compressed.
        \\-i, --init <FILE>             File to add to archive as /init.
        \\-d, --directory <DIR>...      Directory to add to archive (as-is).
        \\-o, --output <FILE>           Archive output filepath.
        \\
    );

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .DIR = clap.parsers.string,
        .BOOL = clap.parsers.enumeration(BoolArgument),
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.arena.allocator(),
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        try clap.usageToFile(init.io, .stderr(), clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
    }

    if (res.args.init == null or res.args.output == null) {
        try diag.reportToFile(init.io, .stderr(), error.InvalidArgument);
        try clap.usageToFile(init.io, .stderr(), clap.Help, &params);
        return;
    }

    const do_compress: bool = if (res.args.compress) |do_compress| do_compress.to_bool() else true;
    const init_: []const u8 = res.args.init.?;
    const directories: []const []const u8 = res.args.directory;
    const output: []const u8 = res.args.output.?;

    var archive_file = try std.Io.Dir.cwd().createFile(
        init.io,
        output,
        .{ .read = true, .permissions = .fromMode(0o444) },
    );
    defer archive_file.close(init.io);

    var writer_buffer: [1024]u8 = undefined;
    var archive_file_writer = archive_file.writer(init.io, &writer_buffer);
    var archive = try CpioArchive.init(&archive_file_writer.interface);

    var init_file = try std.Io.Dir.cwd().openFile(init.io, init_, .{});
    defer init_file.close(init.io);

    const init_file_stat = try init_file.stat(init.io);
    if (init_file_stat.size > std.math.maxInt(u32)) {
        return error.FileTooLarge;
    }

    try archive.addFile(
        init.io,
        "init",
        init_file,
        @intCast(init_file_stat.size),
        .fromMode(0o755),
    );

    for (directories) |directory_path| {
        var dir = try std.Io.Dir.cwd().openDir(
            init.io,
            directory_path,
            .{ .iterate = true },
        );
        defer dir.close(init.io);
        try CpioArchive.walkDirectory(init.io, init.arena, directory_path, &archive, &dir);
    }

    try archive.finalize();

    if (do_compress) {
        try compress(init.io, init.arena, output, archive_file);
    }
}
