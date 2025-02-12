const std = @import("std");
const clap = @import("clap");
const CpioArchive = @import("./cpio.zig");

const C = @cImport({
    @cInclude("lzma.h");
});

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

    const stderr = std.io.getStdErr().writer();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, &parsers, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        try diag.report(stderr, err);
        try clap.usage(stderr, clap.Help, &params);
        return;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }

    if (res.args.init == null or res.args.output == null) {
        try diag.report(stderr, error.InvalidArgument);
        try clap.usage(std.io.getStdErr().writer(), clap.Help, &params);
        return;
    }

    const compress: bool = if (res.args.compress) |compress| compress.to_bool() else true;
    const init: []const u8 = res.args.init.?;
    const directories: []const []const u8 = res.args.directory;
    const output: []const u8 = res.args.output.?;

    var archive_file = try std.fs.cwd().createFile(
        output,
        .{ .read = true, .mode = 0o444 },
    );
    defer archive_file.close();

    var archive_file_source = std.io.StreamSource{ .file = archive_file };
    var archive = try CpioArchive.init(&archive_file_source);

    var init_file = try std.fs.cwd().openFile(init, .{});
    defer init_file.close();

    var init_source = std.io.StreamSource{ .file = init_file };
    try archive.addFile("init", &init_source, 0o755);

    for (directories) |directory_path| {
        var dir = try std.fs.cwd().openDir(
            directory_path,
            .{ .iterate = true },
        );
        defer dir.close();
        try CpioArchive.walkDirectory(&arena, directory_path, &archive, dir);
    }

    try archive.finalize();

    // TODO(jared): factor out into function
    if (compress) {
        const compressed_output = try std.fmt.allocPrint(
            arena.allocator(),
            "{s}.xz",
            .{output},
        );

        var compressed_file = try std.fs.cwd().createFile(
            compressed_output,
            .{ .read = true, .mode = 0o444 },
        );
        defer compressed_file.close();

        var stream: C.lzma_stream = .{};
        defer C.lzma_end(&stream);

        var lzma_opts: C.lzma_options_lzma = .{};
        if (C.lzma_lzma_preset(&lzma_opts, C.LZMA_PRESET_DEFAULT) != C.LZMA_OK) {
            return error.CompressFail;
        }

        var filters = [_]C.lzma_filter{.{}} ** (C.LZMA_FILTERS_MAX + 1);
        filters[0].id = C.LZMA_FILTER_LZMA2;
        filters[0].options = &lzma_opts;
        filters[1].id = C.LZMA_VLI_UNKNOWN;

        if (C.lzma_stream_encoder(
            &stream,
            &filters,
            C.LZMA_CHECK_CRC32, // linux kernel expects CRC32 check
        ) != C.LZMA_OK) {
            return error.CompressFail;
        }

        var input_buffer = [_]u8{0} ** 4096;
        var output_buffer = [_]u8{0} ** 4096;

        stream.next_in = null;
        stream.avail_in = 0;
        stream.next_out = &output_buffer;
        stream.avail_out = @sizeOf(@TypeOf(output_buffer));

        try archive_file.seekTo(0);

        var action: C.lzma_action = C.LZMA_RUN;
        while (true) {
            if (stream.avail_in == 0 and action != C.LZMA_FINISH) {
                stream.next_in = &input_buffer;
                stream.avail_in = try archive_file.readAll(&input_buffer);
                if (stream.avail_in == 0) {
                    action = C.LZMA_FINISH;
                }
            }

            const ret = C.lzma_code(&stream, action);

            if (stream.avail_out == 0 or ret == C.LZMA_STREAM_END) {
                // write to output file
                try compressed_file.writer().writeAll(output_buffer[0 .. output_buffer.len - stream.avail_out]);

                // reset next_out and avail_out
                stream.next_out = &output_buffer;
                stream.avail_out = @sizeOf(@TypeOf(output_buffer));
            }

            if (ret != C.LZMA_OK) {
                if (ret == C.LZMA_STREAM_END) {
                    break;
                }

                return error.CompressFail;
            }
        }

        try std.fs.cwd().rename(compressed_output, output);
    }
}
