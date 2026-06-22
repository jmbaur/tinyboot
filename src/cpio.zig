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
            .mtime = 0,
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

pub fn addFile(
    self: *@This(),
    io: std.Io,
    path: []const u8,
    file: std.Io.File,
    size: u32,
    permissions: std.Io.File.Permissions,
) !void {
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);

    try self.addEntry(&reader.interface, size, path, .File, @intFromEnum(permissions));
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
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    kind: std.Io.File.Kind,
    filename: []const u8,
    current_directory: []const u8,
    starting_directory: []const u8,
    archive: *CpioArchive,
    directory: *std.Io.Dir,
) anyerror!void {
    var fullpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_entry_path_len = try directory.realPathFile(io, filename, &fullpath_buf);
    const entry_path = try std.fs.path.relative(
        arena.allocator(),
        ".",
        null,
        starting_directory,
        fullpath_buf[0..full_entry_path_len],
    );

    switch (kind) {
        .directory => {
            var sub_directory = try directory.openDir(
                io,
                filename,
                .{ .iterate = true },
            );
            defer sub_directory.close(io);

            try walkDirectory(
                io,
                arena,
                starting_directory,
                archive,
                &sub_directory,
            );
        },
        .file => {
            var file = try directory.openFile(io, filename, .{});
            defer file.close(io);

            const stat = try file.stat(io);

            if (stat.size > std.math.maxInt(u32)) {
                return Error.FileTooLarge;
            }

            try archive.addFile(
                io,
                entry_path,
                file,
                @intCast(stat.size),
                stat.permissions,
            );
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
                const stat = try std.Io.Dir.cwd().statFile(io, resolved_path, .{});

                try handleFile(
                    io,
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
            .{ fullpath_buf[0..full_entry_path_len], kind },
        ),
    }
}

pub fn walkDirectory(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    starting_directory: []const u8,
    archive: *CpioArchive,
    directory: *std.Io.Dir,
) anyerror!void {
    var iter = directory.iterate();

    // Before iterating through the directory, first add the directory itself.
    var fullpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fullpath_len = try directory.realPathFile(io, ".", &fullpath_buf);
    const directory_path = try std.fs.path.relative(
        arena.allocator(),
        ".",
        null,
        starting_directory,
        fullpath_buf[0..fullpath_len],
    );

    // We don't need to add the root directory, as it will already exist.
    if (!std.mem.eql(u8, directory_path, "")) {
        // Before iterating through the directory, add the directory itself to
        // the archive.
        try archive.addDirectory(directory_path, 0o755);
    }

    while (try iter.next(io)) |dir_entry| {
        try handleFile(
            io,
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
