const std = @import("std");

pub fn pathExists(io: std.Io, d: std.Io.Dir, p: []const u8) bool {
    d.access(io, p, .{}) catch {
        return false;
    };

    return true;
}

pub fn absolutePathExists(io: std.Io, p: []const u8) bool {
    return pathExists(io, std.Io.Dir.cwd(), p);
}

pub fn enumFromStr(T: anytype, value: []const u8) !T {
    inline for (comptime std.meta.fieldNames(T)) |field| {
        if (std.mem.eql(u8, field, value)) {
            return @field(T, field);
        }
    }

    return error.NotFound;
}

pub fn dumpFile(io: std.Io, dir: std.Io.Dir, writer: *std.Io.Writer, path: []const u8) !void {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    // Use readerStreaming() on files in proc, since reader() uses stat()
    // information to determine how much we can stream, which is not useful for
    // files in /proc.
    var buffer: [1024]u8 = undefined;
    var file_reader = if (std.mem.startsWith(
        u8,
        path,
        std.fs.path.sep_str ++ "proc",
    )) file.readerStreaming(io, &buffer) else file.reader(io, &buffer);
    while (file_reader.interface.stream(writer, .unlimited)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}

pub fn realpathAllocMany(
    io: std.Io,
    dir: std.Io.Dir,
    allocator: std.mem.Allocator,
    path_options: []const []const u8,
) ![]u8 {
    for (path_options) |path| {
        const fullpath = dir.realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        return fullpath;
    }

    return error.FileNotFound;
}
