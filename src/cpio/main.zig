const std = @import("std");
const clap = @import("clap");

const ASCII_CPIO_HEADER_SIZE = 110;
const TRAILER = "TRAILER!!!";

const CpioHeader = struct {
    magic: u32 = 0x070701,
    ino: u32,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u32,
    // Zero by default for reproducibility, plus it's probably best to not
    // meaningfully use this field. The new ascii cpio format suffers from the
    // year 2038 problem with only being able to store 32 bits of time
    // information.
    mtime: u32 = 0,
    filesize: u32 = 0,
    devmajor: u32 = 0,
    devminor: u32 = 0,
    rdevmajor: u32 = 0,
    rdevminor: u32 = 0,
    namesize: u32,
    check: u32 = 0,
};

const CpioEntryType = enum {
    Directory,
    File,
    Symlink,

    fn toMode(self: @This(), perms: u32) u32 {
        return @as(u32, switch (self) {
            .Directory => std.posix.S.IFDIR | perms,
            .File => std.posix.S.IFREG | perms,
            .Symlink => std.posix.S.IFLNK | 0o777, // symlinks are always 0o777
        });
    }
};

pub const CpioArchive = struct {
    dest: *std.io.StreamSource,
    ino: u32 = 0,
    total_written: usize = 0,

    const Error = error{
        FileTooLarge,
        UnexpectedSource,
    };

    pub fn init(dest: *std.io.StreamSource) !@This() {
        return @This(){ .dest = dest };
    }

    pub fn addEntry(
        self: *@This(),
        source: ?*std.io.StreamSource,
        path: []const u8,
        entry_type: CpioEntryType,
        perms: u32,
    ) !void {
        if (entry_type == .Directory and source != null) {
            return Error.UnexpectedSource;
        }

        const filesize = b: {
            if (source) |s| {
                const pos = try s.getEndPos();
                if (pos >= 1 << 32) {
                    return Error.FileTooLarge;
                } else {
                    break :b @as(u32, @intCast(pos));
                }
            } else {
                break :b 0;
            }
        };

        // add null terminator
        // const filepath = path ++ [_]u8{0};
        const filepath_len = path.len + 1; // null terminator

        // write entry to archive
        {
            const header = CpioHeader{
                .ino = self.ino,
                .mode = entry_type.toMode(perms),
                .uid = 0,
                .gid = 0,
                .nlink = if (entry_type == .Directory) 2 else 1,
                .filesize = filesize,
                .devmajor = 0,
                .devminor = 0,
                .rdevmajor = 0,
                .rdevminor = 0,
                .namesize = @intCast(filepath_len),
            };

            try self.dest.writer().print("{X:0>6}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}", .{
                header.magic,
                header.ino,
                header.mode,
                header.uid,
                header.gid,
                header.nlink,
                header.mtime,
                header.filesize,
                header.devmajor,
                header.devminor,
                header.rdevmajor,
                header.rdevminor,
                header.namesize,
                header.check,
            });
            self.total_written += ASCII_CPIO_HEADER_SIZE;

            try self.dest.writer().writeAll(path);
            try self.dest.writer().writeByte(0); // null terminator
            self.total_written += filepath_len;

            // pad the file name
            const header_padding = (4 - ((ASCII_CPIO_HEADER_SIZE + filepath_len) % 4)) % 4;
            try self.dest.writer().writeByteNTimes(0, header_padding);
            self.total_written += header_padding;

            if (source) |_source| {
                var pos: usize = 0;
                const end = try _source.getEndPos();

                var buf = [_]u8{0} ** 4096;

                while (pos < end) {
                    try _source.seekTo(pos);
                    const bytes_read = try _source.read(&buf);
                    try self.dest.writer().writeAll(buf[0..bytes_read]);
                    self.total_written += bytes_read;
                    pos += bytes_read;
                }

                // pad the file data
                const filedata_padding = (4 - (end % 4)) % 4;
                try self.dest.writer().writeByteNTimes(0, filedata_padding);
                self.total_written += filedata_padding;
            }
        }

        self.ino += 1;
    }

    pub fn addFile(self: *@This(), path: []const u8, source: *std.io.StreamSource, perms: u32) !void {
        try self.addEntry(source, path, .File, perms);
    }

    pub fn addDirectory(self: *@This(), path: []const u8, perms: u32) !void {
        try self.addEntry(null, path, .Directory, perms);
    }

    pub fn addSymlink(
        self: *@This(),
        dstPath: []const u8,
        srcPath: []const u8,
    ) !void {
        var source = std.io.StreamSource{
            .const_buffer = std.io.fixedBufferStream(srcPath),
        };

        try self.addEntry(
            &source,
            dstPath,
            .Symlink,
            0o777, // make symlinks always have 777 perms
        );
    }

    pub fn finalize(self: *@This()) !void {
        try self.addEntry(null, TRAILER, .File, 0);

        // Maintain a block size of 512 by adding padding to the end of the
        // archive.
        try self.dest.writer().writeByteNTimes(0, (512 - (self.total_written % 512)) % 512);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit.
        \\-i, --init <FILE>             File to add to archive as /init.
        \\-d, --directory <DIR>...      Directory to add to archive (as-is).
        \\-o, --output <FILE>           Archive output filepath.
        \\
    );

    const parsers = comptime .{
        .FILE = clap.parsers.string,
        .DIR = clap.parsers.string,
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

    const init: []const u8 = res.args.init.?;
    const directories: []const []const u8 = res.args.directory;
    const output: []const u8 = res.args.output.?;

    var archive_file = try std.fs.cwd().createFile(output, .{});
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
        try walkDirectory(&arena, directory_path, &archive, dir);
    }

    try archive.finalize();
}

fn walkDirectory(arena: *std.heap.ArenaAllocator, starting_directory: []const u8, archive: *CpioArchive, directory: std.fs.Dir) !void {
    var iter = directory.iterate();

    // This buffer is reused across multiple paths.
    var fullpath_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    // Before iterating through the directory, first add the directory itself.
    const full_directory_path = try directory.realpath(".", &fullpath_buf);
    const directory_path = try std.fs.path.relative(arena.allocator(), starting_directory, full_directory_path);

    // We don't need to add the root directory, as it will already exist.
    if (!std.mem.eql(u8, directory_path, "")) {
        try archive.addDirectory(directory_path, 0o755);
    }

    while (try iter.next()) |dir_entry| {
        const full_entry_path = try directory.realpath(dir_entry.name, &fullpath_buf);
        const entry_path = try std.fs.path.relative(arena.allocator(), starting_directory, full_entry_path);

        switch (dir_entry.kind) {
            .directory => {
                var sub_directory = try directory.openDir(
                    dir_entry.name,
                    .{ .iterate = true },
                );
                defer sub_directory.close();
                try walkDirectory(arena, starting_directory, archive, sub_directory);
            },
            .file => {
                var file = try directory.openFile(dir_entry.name, .{});
                defer file.close();

                const stat = try file.stat();
                var source = std.io.StreamSource{ .file = file };
                try archive.addFile(entry_path, &source, @intCast(stat.mode));
            },
            .sym_link => {
                const resolved_path = try std.fs.path.resolve(arena.allocator(), &.{ starting_directory, entry_path });
                if (std.mem.startsWith(u8, resolved_path, starting_directory)) {
                    const symlink_path = try std.fs.path.join(arena.allocator(), &.{ directory_path, dir_entry.name });
                    try archive.addSymlink(symlink_path, entry_path);
                } else {
                    std.log.warn(
                        "Resolved symlink {s} is outside of {s}, refusing to add to CPIO archive",
                        .{ resolved_path, starting_directory },
                    );
                }
            },
            else => |kind| {
                std.log.warn(
                    "Do not know how to add file {s} of kind {} to CPIO archive",
                    .{ full_entry_path, kind },
                );
            },
        }
    }
}
