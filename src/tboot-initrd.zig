const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const CpioArchive = @import("./cpio.zig");
const zstd = @import("./zstd.zig");

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
    arena: *std.heap.ArenaAllocator,
    output: []const u8,
    archive_file: std.fs.File,
) !void {
    try archive_file.seekTo(0);

    const archive_file_buf = try archive_file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize));
    const compressed = try zstd.compress(arena.allocator(), archive_file_buf);
    defer compressed.deinit();

    const compressed_output = try std.fmt.allocPrint(
        arena.allocator(),
        "{s}.tmp",
        .{output},
    );

    var compressed_file = try std.fs.cwd().createFile(compressed_output, .{ .mode = 0o444 });
    defer compressed_file.close();

    try compressed_file.writeAll(compressed.content());

    try std.fs.cwd().rename(compressed_output, output);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

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

    if (res.args.init == null or res.args.output == null) {
        try diag.reportToFile(.stderr(), error.InvalidArgument);
        try clap.usageToFile(.stderr(), clap.Help, &params);
        return;
    }

    const do_compress: bool = if (res.args.compress) |do_compress| do_compress.to_bool() else true;
    const init: []const u8 = res.args.init.?;
    const directories: []const []const u8 = res.args.directory;
    const output: []const u8 = res.args.output.?;

    var archive_file = try std.fs.cwd().createFile(
        output,
        .{ .read = true, .mode = 0o444 },
    );
    defer archive_file.close();

    var writer_buffer: [1024]u8 = undefined;
    var archive_file_writer = archive_file.writer(&writer_buffer);
    var archive = try CpioArchive.init(&archive_file_writer.interface);

    var init_file = try std.fs.cwd().openFile(init, .{});
    defer init_file.close();

    try archive.addFile("init", init_file, 0o755);

    for (directories) |directory_path| {
        var dir = try std.fs.cwd().openDir(
            directory_path,
            .{ .iterate = true },
        );
        defer dir.close();
        try CpioArchive.walkDirectory(&arena, directory_path, &archive, &dir);
    }

    try archive.finalize();

    if (do_compress) {
        try compress(&arena, output, archive_file);
    }
}
