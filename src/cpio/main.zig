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

const CpioEntry = struct {
    header: CpioHeader,
    filename: []const u8,
    source: ?*std.io.StreamSource,
};

const CpioEntryType = enum {
    Directory,
    File,

    fn to_mode(self: @This()) u32 {
        return @as(u32, switch (self) {
            .Directory => std.os.S.IFDIR,
            .File => std.os.S.IFREG,
        });
    }
};

pub const CpioArchive = struct {
    ino: u32 = 0,
    entries: std.ArrayList(CpioEntry),

    const Error = error{
        FileTooLarge,
    };

    pub fn init(allocator: std.mem.Allocator) !@This() {
        var cpio = @This(){
            .entries = std.ArrayList(CpioEntry).init(allocator),
        };

        errdefer cpio.entries.deinit();

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

        const mode = entry_type.to_mode() | perms;

        // add null terminator
        const filepath = path ++ [_]u8{0};

        try self.entries.append(.{
            .header = .{
                .ino = self.ino,
                .mode = mode,
                .uid = 0,
                .gid = 0,
                .nlink = if (entry_type == .File) 1 else 2,
                .filesize = filesize,
                .devmajor = 0,
                .devminor = 0,
                .rdevmajor = 0,
                .rdevminor = 0,
                .namesize = @intCast(filepath.len),
            },
            .source = source,
            .filename = filepath,
        });

        self.ino += 1;
    }

    pub fn finalize(self: *@This(), dest: *std.io.StreamSource) !void {
        try self.addEntry(null, TRAILER, .File, 0);

        var total_written: usize = 0;

        for (self.entries.items) |entry| {
            try dest.writer().print("{X:0>6}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}{X:0>8}", .{
                entry.header.magic,
                entry.header.ino,
                entry.header.mode,
                entry.header.uid,
                entry.header.gid,
                entry.header.nlink,
                entry.header.mtime,
                entry.header.filesize,
                entry.header.devmajor,
                entry.header.devminor,
                entry.header.rdevmajor,
                entry.header.rdevminor,
                entry.header.namesize,
                entry.header.check,
            });
            total_written += ASCII_CPIO_HEADER_SIZE;

            try dest.writer().writeAll(entry.filename);
            total_written += entry.filename.len;

            // pad the filename
            const header_missing = (ASCII_CPIO_HEADER_SIZE + entry.filename.len) % 4;
            if (header_missing > 0) {
                const header_padding = 4 - header_missing;
                try dest.writer().writeByteNTimes(0, header_padding);
                total_written += header_padding;
            }

            if (entry.source) |source| {
                var pos: usize = 0;
                const end = try source.getEndPos();

                var buf = [_]u8{0} ** 4096;

                while (pos < end) {
                    try source.seekTo(pos);
                    const bytes_read = try source.read(&buf);
                    try dest.writer().writeAll(buf[0..bytes_read]);
                    total_written += bytes_read;
                    pos += bytes_read;
                }

                // pad the data
                const filedata_missing = end % 4;
                if (filedata_missing > 0) {
                    const filedata_padding = 4 - filedata_missing;
                    try dest.writer().writeByteNTimes(0, filedata_padding);
                    total_written += filedata_padding;
                }
            }
        }

        // We finish off the archive with an even multiple of 16. This is how
        // GNU cpio does it, don't ask questions.
        const end_missing = total_written % 16;
        if (end_missing > 0) {
            try dest.writer().writeByteNTimes(0, 16 - end_missing);
        }
    }

    pub fn deinit(self: *@This()) void {
        self.entries.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = std.process.ArgIterator.init();
    _ = args.next().?;
    const init = args.next().?;
    const outfile = args.next().?;

    var archive = try CpioArchive.init(allocator);
    defer archive.deinit();

    var init_file = try std.fs.openFileAbsolute(init, .{});
    defer init_file.close();

    var init_source = std.io.StreamSource{ .file = init_file };
    try archive.addEntry(&init_source, "init", .File, 0o755);

    var archive_file = try std.fs.createFileAbsolute(outfile, .{});
    defer archive_file.close();

    var archive_file_source = std.io.StreamSource{ .file = archive_file };
    try archive.finalize(&archive_file_source);
}
