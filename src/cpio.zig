const std = @import("std");

const ASCII_CPIO_HEADER_SIZE = 110;
const TRAILER = "TRAILER!!!";

const CpioHeader = struct {
    magic: u32 = 0x070701,
    ino: u32,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u32,
    mtime: u32,
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
            .Directory => std.os.linux.S.IFDIR | perms,
            .File => std.os.linux.S.IFREG | perms,
            .Symlink => std.os.linux.S.IFLNK | 0o777, // symlinks are always 0o777
        });
    }
};

pub const CpioArchive = @This();

writer: *std.Io.Writer,
ino: u32 = 0,
total_written: usize = 0,

const Error = error{
    FileTooLarge,
    UnexpectedSource,
};

pub fn init(writer: *std.Io.Writer) !@This() {
    return @This(){ .writer = writer };
}

pub fn addEntry(
    self: *@This(),
    source: ?*std.Io.Reader,
    filesize: u32,
    path: []const u8,
    entry_type: CpioEntryType,
    perms: u32,
) !void {
    if (entry_type == .Directory and source != null) {
        return Error.UnexpectedSource;
    }

    const filepath_len = path.len + 1; // null terminator

    // Zero by default for reproducibility, plus it's probably best to not
    // meaningfully use this field. The new ascii cpio format suffers from the
    // year 2038 problem with only being able to store 32 bits of time
    // information.
    var mtime_buf = [_]u8{0} ** (@sizeOf(u32) * 8);
    var fba = std.heap.FixedBufferAllocator.init(&mtime_buf);
    const mtime = b: {
        const mtime_string = std.process.getEnvVarOwned(fba.allocator(), "SOURCE_DATE_EPOCH") catch break :b 0;
        break :b try std.fmt.parseInt(u32, mtime_string, 10);
    };

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
            .mtime = mtime,
            .namesize = @intCast(filepath_len),
        };

        try self.writer.print("{X:0>6}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}", .{
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

        try self.writer.writeAll(path);
        try self.writer.writeByte(0); // null terminator
        self.total_written += filepath_len;

        // pad the file name
        const header_padding = (4 - ((ASCII_CPIO_HEADER_SIZE + filepath_len) % 4)) % 4;
        try self.writer.splatByteAll(0, header_padding);
        self.total_written += header_padding;

        if (source) |source_| {
            var streamed_bytes: usize = 0;
            while (source_.stream(self.writer, .unlimited)) |n| {
                streamed_bytes += n;
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }

            self.total_written += streamed_bytes;

            // pad the file data
            const filedata_padding: usize = @intCast((4 - (streamed_bytes % 4)) % 4);
            try self.writer.splatByteAll(0, filedata_padding);
            self.total_written += filedata_padding;
        }
    }

    self.ino += 1;
}

pub fn addFile(self: *@This(), path: []const u8, file: std.fs.File, perms: u32) !void {
    const stat = try file.stat();
    if (stat.size > std.math.maxInt(u32)) {
        return Error.FileTooLarge;
    }

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(&buffer);

    try self.addEntry(&reader.interface, @intCast(stat.size), path, .File, perms);
}

pub fn addDirectory(self: *@This(), path: []const u8, perms: u32) !void {
    try self.addEntry(null, 0, path, .Directory, perms);
}

pub fn addSymlink(
    self: *@This(),
    dst_path: []const u8,
    src_path: []const u8,
) !void {
    var reader: std.Io.Reader = .fixed(src_path);

    try self.addEntry(
        &reader,
        @intCast(src_path.len),
        dst_path,
        .Symlink,
        0o777, // make symlinks always have 777 perms
    );
}

pub fn finalize(self: *@This()) !void {
    try self.addEntry(null, 0, TRAILER, .File, 0);

    // Maintain a block size of 512 by adding padding to the end of the
    // archive.
    try self.writer.splatByteAll(0, (512 - (self.total_written % 512)) % 512);
    try self.writer.flush();
}

fn handleFile(
    arena: *std.heap.ArenaAllocator,
    kind: std.fs.File.Kind,
    filename: []const u8,
    current_directory: []const u8,
    starting_directory: []const u8,
    archive: *CpioArchive,
    directory: *std.fs.Dir,
) anyerror!void {
    var fullpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_entry_path = try directory.realpath(filename, &fullpath_buf);
    const entry_path = try std.fs.path.relative(arena.allocator(), starting_directory, full_entry_path);

    switch (kind) {
        .directory => {
            var sub_directory = try directory.openDir(
                filename,
                .{ .iterate = true },
            );
            defer sub_directory.close();

            try walkDirectory(
                arena,
                starting_directory,
                archive,
                &sub_directory,
            );
        },
        .file => {
            var file = try directory.openFile(filename, .{});
            defer file.close();

            const stat = try file.stat();

            try archive.addFile(entry_path, file, @intCast(stat.mode));
        },
        .sym_link => {
            const resolved_path = try std.fs.path.resolve(
                arena.allocator(),
                &.{ starting_directory, entry_path },
            );

            if (std.mem.startsWith(u8, resolved_path, starting_directory)) {
                const symlink_path = try std.fs.path.join(
                    arena.allocator(),
                    &.{ current_directory, filename },
                );

                try archive.addSymlink(symlink_path, entry_path);
            } else {
                const stat = try std.fs.cwd().statFile(resolved_path);

                try handleFile(
                    arena,
                    stat.kind,
                    resolved_path,
                    current_directory,
                    starting_directory,
                    archive,
                    directory,
                );
            }
        },
        else => std.log.warn(
            "Do not know how to add file {s} of kind {} to CPIO archive",
            .{ full_entry_path, kind },
        ),
    }
}

pub fn walkDirectory(
    arena: *std.heap.ArenaAllocator,
    starting_directory: []const u8,
    archive: *CpioArchive,
    directory: *std.fs.Dir,
) anyerror!void {
    var iter = directory.iterate();

    // Before iterating through the directory, first add the directory itself.
    var fullpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_directory_path = try directory.realpath(".", &fullpath_buf);
    const directory_path = try std.fs.path.relative(arena.allocator(), starting_directory, full_directory_path);

    // We don't need to add the root directory, as it will already exist.
    if (!std.mem.eql(u8, directory_path, "")) {
        // Before iterating through the directory, add the directory itself to
        // the archive.
        try archive.addDirectory(directory_path, 0o755);
    }

    while (try iter.next()) |dir_entry| {
        try handleFile(
            arena,
            dir_entry.kind,
            dir_entry.name,
            directory_path,
            starting_directory,
            archive,
            directory,
        );
    }
}
