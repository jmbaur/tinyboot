const std = @import("std");

const random_bytes_count = 12;
const sub_path_len = std.fs.base64_encoder.calcSize(random_bytes_count);

pub const TmpDir = @This();

dir: std.Io.Dir,
parent_dir: std.Io.Dir,
sub_path: [sub_path_len]u8,

pub fn create(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, opts: std.Io.Dir.CreateDirPathOpenOptions) !TmpDir {
    var random_bytes: [TmpDir.random_bytes_count]u8 = undefined;
    std.Io.random(io, &random_bytes);
    var child_sub_path: [sub_path_len]u8 = undefined;
    _ = std.fs.base64_encoder.encode(&child_sub_path, &random_bytes);

    const parent_dir = try dir.createDirPathOpen(io, sub_path, .{});
    errdefer parent_dir.close(io);

    const child_dir = try parent_dir.createDirPathOpen(io, &child_sub_path, opts);

    return .{
        .dir = child_dir,
        .parent_dir = parent_dir,
        .sub_path = child_sub_path,
    };
}

pub fn cleanup(self: *TmpDir, io: std.Io) void {
    self.dir.close(io);
    self.parent_dir.deleteTree(io, &self.sub_path) catch {};
    self.parent_dir.close(io);
    self.* = undefined;
}
