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
        var cpio = @This(){ .dest = dest };

        // Always start off with a root directory.
        try cpio.addEntry(null, ".", .Directory, 0o755);

        return cpio;
    }

    pub fn addEntry(
        self: *@This(),
        source: ?*std.io.StreamSource,
        comptime path: []const u8,
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
        const filepath = path ++ [_]u8{0};

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
                .namesize = @intCast(filepath.len),
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

            try self.dest.writer().writeAll(filepath);
            self.total_written += filepath.len;

            // pad the file name
            const header_padding = (4 - ((ASCII_CPIO_HEADER_SIZE + filepath.len) % 4)) % 4;
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

    pub fn addFile(self: *@This(), comptime path: []const u8, source: *std.io.StreamSource, perms: u32) !void {
        try self.addEntry(source, path, .File, perms);
    }

    pub fn addDirectory(self: *@This(), comptime path: []const u8, perms: u32) !void {
        try self.addEntry(null, path, .Directory, perms);
    }

    pub fn addSymlink(
        self: *@This(),
        comptime dstPath: []const u8,
        comptime srcPath: []const u8,
    ) !void {
        var source = std.io.StreamSource{
            .const_buffer = std.io.fixedBufferStream(srcPath),
        };

        try self.addEntry(
            &source,
            dstPath,
            .Symlink,
            0o777, // symlinks always have 777 perms
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
    var args = std.process.args();
    _ = args.next().?;
    const init = args.next().?;
    const outfile = args.next().?;

    var archive_file = try std.fs.cwd().createFile(outfile, .{});
    defer archive_file.close();

    var archive_file_source = std.io.StreamSource{ .file = archive_file };
    var archive = try CpioArchive.init(&archive_file_source);

    var init_file = try std.fs.cwd().openFile(init, .{});
    defer init_file.close();

    var init_source = std.io.StreamSource{ .file = init_file };
    try archive.addFile("./init", &init_source, 0o755);

    try archive.finalize();
}
