const std = @import("std");

pub fn pathExists(d: std.fs.Dir, p: []const u8) bool {
    d.access(p, .{}) catch {
        return false;
    };

    return true;
}

pub fn absolutePathExists(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch {
        return false;
    };

    return true;
}

pub fn enumFromStr(T: anytype, value: []const u8) !T {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, value)) {
            return @field(T, field.name);
        }
    }

    return error.NotFound;
}
