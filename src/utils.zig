const std = @import("std");

pub fn pathExists(d: *const std.fs.Dir, p: []const u8) bool {
    d.access(p, .{}) catch {
        return false;
    };

    return true;
}

pub fn absolutePathExists(p: []const u8) bool {
    return pathExists(&std.fs.cwd(), p);
}

pub fn enumFromStr(T: anytype, value: []const u8) !T {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, value)) {
            return @field(T, field.name);
        }
    }

    return error.NotFound;
}

pub fn dumpFile(writer: std.io.AnyWriter, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    while (true) {
        file.reader().streamUntilDelimiter(writer, '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try writer.writeByte('\n');
    }
}

pub fn realpathAllocMany(
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    path_options: []const []const u8,
) ![]u8 {
    for (path_options) |path| {
        const fullpath = dir.realpathAlloc(allocator, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        return fullpath;
    }

    return error.FileNotFound;
}
